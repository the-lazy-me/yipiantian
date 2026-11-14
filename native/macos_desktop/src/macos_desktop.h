#ifndef MACOS_DESKTOP_H
#define MACOS_DESKTOP_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

class MacDesktop : public RefCounted {
	GDCLASS(MacDesktop, RefCounted)

protected:
	static void _bind_methods();

public:
	Dictionary probe() const;
	bool attach(int64_t window_handle);
	bool reassert(int64_t window_handle);
	bool detach(int64_t window_handle);
	int64_t layer(int64_t window_handle) const;
	bool occlusion_visible(int64_t window_handle) const;
	void show_status_item();
	void hide_status_item();
	int take_command();
};

} // namespace godot

#endif // MACOS_DESKTOP_H
