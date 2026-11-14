#!/usr/bin/env bash
# Build the macos_desktop GDExtension and install the editor/export copies.
# Sources stay in native/macos_desktop/; Game/native/macos_desktop/ is generated.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# godot-cpp has no 4.7 release tag; this master commit ships
# gdextension/extension_api-4-7.json and is what the probe was verified against.
GODOT_CPP_COMMIT="${GODOT_CPP_COMMIT:-2a4c066e1e8c121046e9d35fe91cc8e726861c48}"
GODOT_CPP_PATH="${GODOT_CPP_PATH:-$ROOT/.local/godot-cpp}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
TARGETS="${TARGETS:-debug release}"
ARCH="${ARCH:-universal}"

SCONS="${SCONS:-$ROOT/.local/tools/venv/bin/scons}"
if [[ ! -x "$SCONS" ]]; then
	SCONS="$(command -v scons || true)"
fi
if [[ -z "$SCONS" ]]; then
	echo "SCons not found. Run: python3 -m venv .local/tools/venv && .local/tools/venv/bin/pip install scons" >&2
	exit 1
fi

if [[ ! -f "$GODOT_CPP_PATH/SConstruct" ]]; then
	mkdir -p "$(dirname "$GODOT_CPP_PATH")"
	git clone https://github.com/godotengine/godot-cpp.git "$GODOT_CPP_PATH"
fi
git -C "$GODOT_CPP_PATH" checkout --quiet "$GODOT_CPP_COMMIT"
export GODOT_CPP_PATH

for kind in $TARGETS; do
	"$SCONS" -C "$ROOT/native/macos_desktop" \
		platform=macos arch="$ARCH" target="template_$kind" -j"$JOBS" "$@"
	cp "$ROOT/native/macos_desktop/build/macos_desktop.dylib" \
		"$ROOT/native/macos_desktop/build/macos_desktop.$kind.dylib"
done

install -d "$ROOT/Game/native/macos_desktop"
for kind in $TARGETS; do
	# Godot's macOS exporter moves dylibs to Contents/Frameworks, so the
	# .gdextension references them from the project root by basename.
	install -m 755 "$ROOT/native/macos_desktop/build/macos_desktop.$kind.dylib" \
		"$ROOT/Game/macos_desktop.$kind.dylib"
	lipo "$ROOT/Game/macos_desktop.$kind.dylib" -verify_arch arm64 x86_64
done
install -m 644 "$ROOT/native/macos_desktop/macos_desktop.gdextension" \
	"$ROOT/Game/native/macos_desktop/macos_desktop.gdextension"

echo "Installed Game/macos_desktop.<target>.dylib: $(echo "$TARGETS" | tr ' ' ',')"
