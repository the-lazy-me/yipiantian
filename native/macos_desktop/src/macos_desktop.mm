#include "macos_desktop.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

#include <atomic>
#include <cstdint>

using namespace godot;

namespace {

// Commands polled from GDScript. Menu actions run on the main thread, so a
// plain atomic is enough; a newer command may replace an unread one.
std::atomic<int> g_pending_command{0};

// Levels, not edges: a lock/sleep pair that starts and ends between two polls
// must not leave the controller suspended forever. Both default to the state a
// normally launched app starts in.
std::atomic<bool> g_session_active{true};
std::atomic<bool> g_screens_awake{true};

} // namespace

@interface MacDesktopStatusMenuTarget : NSObject
- (void)returnToWindow:(id)sender;
- (void)quitGame:(id)sender;
@end

@implementation MacDesktopStatusMenuTarget

- (void)returnToWindow:(id)sender {
	g_pending_command.store(1);
}

- (void)quitGame:(id)sender {
	g_pending_command.store(2);
}

@end

namespace {

// Strong globals under ARC; nil after hide_status_item().
NSStatusItem *g_status_item = nil;
MacDesktopStatusMenuTarget *g_status_target = nil;
// Observer tokens stay retained until shutdown()/module teardown removes them.
NSMutableArray<id> *g_workspace_observers = nil;

void remove_workspace_observers() {
	if (g_workspace_observers == nil) {
		return;
	}
	NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
	for (id observer in g_workspace_observers) {
		[center removeObserver:observer];
	}
	g_workspace_observers = nil;
}

void ensure_workspace_observers() {
	if (g_workspace_observers != nil) {
		return;
	}
	g_workspace_observers = [NSMutableArray array];
	NSNotificationCenter *center = [[NSWorkspace sharedWorkspace] notificationCenter];
	// Blocks only store an atomic and never call into Godot, so a notification
	// delivered mid-frame cannot block the engine.
	void (^observe_session)(NSString *, bool) = ^(NSString *name, bool active) {
		id observer = [center addObserverForName:name
		                                  object:nil
		                                   queue:nil
		                              usingBlock:^(NSNotification *notification) {
			g_session_active.store(active);
		}];
		[g_workspace_observers addObject:observer];
	};
	void (^observe_screens)(NSString *, bool) = ^(NSString *name, bool awake) {
		id observer = [center addObserverForName:name
		                                  object:nil
		                                   queue:nil
		                              usingBlock:^(NSNotification *notification) {
			g_screens_awake.store(awake);
		}];
		[g_workspace_observers addObject:observer];
	};
	observe_session(NSWorkspaceSessionDidResignActiveNotification, false);
	observe_session(NSWorkspaceSessionDidBecomeActiveNotification, true);
	observe_screens(NSWorkspaceScreensDidSleepNotification, false);
	observe_screens(NSWorkspaceScreensDidWakeNotification, true);
	// System wake without a display wake event still means rendering may resume;
	// the polled session flag keeps a locked wake suspended.
	observe_screens(NSWorkspaceDidWakeNotification, true);
}

NSWindow *window_from_handle(int64_t handle) {
	return (__bridge NSWindow *)(void *)(uintptr_t)handle;
}

const NSWindowCollectionBehavior kAttachedBehavior =
		NSWindowCollectionBehaviorCanJoinAllSpaces |
		NSWindowCollectionBehaviorStationary |
		NSWindowCollectionBehaviorIgnoresCycle |
		NSWindowCollectionBehaviorFullScreenAuxiliary;

void apply_attached_state(NSWindow *window) {
	// One level above the desktop layer: below every normal app window, above the wallpaper.
	NSInteger level = (NSInteger)CGWindowLevelForKey(kCGDesktopWindowLevelKey) + 1;
	[window setLevel:level];
	[window setCollectionBehavior:kAttachedBehavior];
	[window setIgnoresMouseEvents:YES];
	[window setHidesOnDeactivate:NO];
	[NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
	[window orderFrontRegardless];
}

} // namespace

Dictionary MacDesktop::probe() const {
	Dictionary result;
	result["supported"] = true;
	result["desktop_level"] = (int64_t)CGWindowLevelForKey(kCGDesktopWindowLevelKey);
	result["icon_level"] = (int64_t)CGWindowLevelForKey(kCGDesktopIconWindowLevelKey);

	NSArray<NSScreen *> *screens = [NSScreen screens];
	result["screen_count"] = screens ? (int64_t)[screens count] : 0;

	NSScreen *main_screen = [NSScreen mainScreen];
	result["main_scale"] = main_screen ? (double)[main_screen backingScaleFactor] : 1.0;
	return result;
}

bool MacDesktop::attach(int64_t window_handle) {
	NSWindow *window = window_from_handle(window_handle);
	if (window == nil) {
		return false;
	}
	apply_attached_state(window);
	return true;
}

bool MacDesktop::reassert(int64_t window_handle) {
	NSWindow *window = window_from_handle(window_handle);
	if (window == nil) {
		return false;
	}
	apply_attached_state(window);
	return true;
}

bool MacDesktop::detach(int64_t window_handle) {
	NSWindow *window = window_from_handle(window_handle);
	if (window == nil) {
		return false;
	}
	// canBecomeKeyWindow/canBecomeMainWindow are read-only in AppKit; the window keeps
	// whatever Godot's NSWindow subclass reports. Restoring the normal level and focus
	// ordering is all that is available through public API.
	[window setLevel:NSNormalWindowLevel];
	[window setCollectionBehavior:NSWindowCollectionBehaviorDefault];
	[window setIgnoresMouseEvents:NO];
	[window setHidesOnDeactivate:NO];
	[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
	[window makeKeyAndOrderFront:nil];
	return true;
}

int64_t MacDesktop::layer(int64_t window_handle) const {
	NSWindow *window = window_from_handle(window_handle);
	if (window == nil) {
		return INT32_MIN;
	}
	CGWindowID window_number = (CGWindowID)[window windowNumber];
	if (window_number == 0) {
		return INT32_MIN;
	}

	CFArrayRef window_list = CGWindowListCopyWindowInfo(
			kCGWindowListOptionIncludingWindow, window_number);
	if (window_list == nullptr) {
		return INT32_MIN;
	}

	int64_t result = INT32_MIN;
	if (CFArrayGetCount(window_list) > 0) {
		CFDictionaryRef info =
				(CFDictionaryRef)CFArrayGetValueAtIndex(window_list, 0);
		CFNumberRef layer_number =
				(CFNumberRef)CFDictionaryGetValue(info, kCGWindowLayer);
		int32_t value = 0;
		if (layer_number != nullptr &&
				CFNumberGetValue(layer_number, kCFNumberSInt32Type, &value)) {
			result = value;
		}
	}

	CFRelease(window_list);
	return result;
}

bool MacDesktop::occlusion_visible(int64_t window_handle) const {
	NSWindow *window = window_from_handle(window_handle);
	if (window == nil) {
		return false;
	}
	return ([window occlusionState] & NSWindowOcclusionStateVisible) != 0;
}

void MacDesktop::show_status_item() {
	if (g_status_item != nil) {
		return;
	}

	g_status_item =
			[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
	g_status_item.button.title = @"我有一片田";

	if (g_status_target == nil) {
		g_status_target = [[MacDesktopStatusMenuTarget alloc] init];
	}

	NSMenu *menu = [[NSMenu alloc] initWithTitle:@"我有一片田"];
	NSMenuItem *return_item = [[NSMenuItem alloc]
			initWithTitle:@"返回窗口"
				   action:@selector(returnToWindow:)
			keyEquivalent:@""];
	return_item.tag = 1;
	return_item.target = g_status_target;
	[menu addItem:return_item];

	NSMenuItem *quit_item = [[NSMenuItem alloc]
			initWithTitle:@"退出游戏"
				   action:@selector(quitGame:)
			keyEquivalent:@""];
	quit_item.tag = 2;
	quit_item.target = g_status_target;
	[menu addItem:quit_item];

	g_status_item.menu = menu;
}

void MacDesktop::hide_status_item() {
	if (g_status_item == nil) {
		return;
	}
	[[NSStatusBar systemStatusBar] removeStatusItem:g_status_item];
	g_status_item = nil;
}

int MacDesktop::take_command() {
	return g_pending_command.exchange(0);
}

int MacDesktop::system_state() const {
	// Register on first poll; the flags already hold sane defaults.
	ensure_workspace_observers();
	int state = 0;
	if (g_session_active.load()) {
		state |= 1;
	}
	if (g_screens_awake.load()) {
		state |= 2;
	}
	return state;
}

void MacDesktop::shutdown() {
	remove_workspace_observers();
	hide_status_item();
	g_session_active.store(true);
	g_screens_awake.store(true);
}

void MacDesktop::_bind_methods() {
	ClassDB::bind_method(D_METHOD("probe"), &MacDesktop::probe);
	ClassDB::bind_method(D_METHOD("attach", "window_handle"), &MacDesktop::attach);
	ClassDB::bind_method(D_METHOD("reassert", "window_handle"), &MacDesktop::reassert);
	ClassDB::bind_method(D_METHOD("detach", "window_handle"), &MacDesktop::detach);
	ClassDB::bind_method(D_METHOD("layer", "window_handle"), &MacDesktop::layer);
	ClassDB::bind_method(D_METHOD("occlusion_visible", "window_handle"),
			&MacDesktop::occlusion_visible);
	ClassDB::bind_method(D_METHOD("show_status_item"), &MacDesktop::show_status_item);
	ClassDB::bind_method(D_METHOD("hide_status_item"), &MacDesktop::hide_status_item);
	ClassDB::bind_method(D_METHOD("take_command"), &MacDesktop::take_command);
	ClassDB::bind_method(D_METHOD("system_state"), &MacDesktop::system_state);
	ClassDB::bind_method(D_METHOD("shutdown"), &MacDesktop::shutdown);
}

namespace {

void initialize_macos_desktop_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	GDREGISTER_CLASS(MacDesktop);
}

void uninitialize_macos_desktop_module(ModuleInitializationLevel p_level) {
	if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
		return;
	}
	// Drop workspace callbacks even if GDScript never called shutdown().
	remove_workspace_observers();
}

} // namespace

extern "C" {
GDExtensionBool GDE_EXPORT macos_desktop_library_init(
		GDExtensionInterfaceGetProcAddress p_get_proc_address,
		GDExtensionClassLibraryPtr p_library,
		GDExtensionInitialization *r_initialization) {
	::godot::GDExtensionBinding::InitObject init_obj(
			p_get_proc_address, p_library, r_initialization);
	init_obj.register_initializer(initialize_macos_desktop_module);
	init_obj.register_terminator(uninitialize_macos_desktop_module);
	init_obj.set_minimum_library_initialization_level(
			MODULE_INITIALIZATION_LEVEL_SCENE);
	return init_obj.init();
}
}
