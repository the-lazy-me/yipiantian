#!/usr/bin/env bash
# Build an unsigned macOS app bundle and a manifest tying it to this commit.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine_version="$(tr -d '[:space:]' < "$repo_root/.godot-version")"
app_version="$(sed -n 's/^config\/version="\(.*\)"$/\1/p' "$repo_root/Game/project.godot")"
template_dir="${GODOT_TEMPLATE_DIR:-$HOME/Library/Application Support/Godot/export_templates/${engine_version//-/.}}"
output="${1:-$repo_root/.local/builds/macos}"
mkdir -p "$output"
# Godot resolves a relative export path against the project directory, so hand
# the exporter an absolute destination regardless of how the caller spelled it.
output="$(cd "$output" && pwd)"
app="$output/我有一片田.app"
zip="$output/我有一片田.$app_version.macOS.zip"

if [[ -z "$app_version" ]]; then
	echo "Game/project.godot does not declare config/version." >&2
	exit 1
fi
if [[ "$(cat "$template_dir/version.txt" 2>/dev/null)" != "${engine_version//-/.}" ]]; then
	echo "macOS export template $engine_version is not installed in $template_dir." >&2
	exit 1
fi

rm -rf "$app"
# The wallpaper mode loads an in-process GDExtension; build it before exporting
# so the bundle always matches the current sources.
if [[ "${SKIP_NATIVE:-0}" != "1" ]]; then
	"$repo_root/native/macos_desktop/build.sh"
fi
"$repo_root/scripts/godot-macos.sh" Export "$app"

# Sign nested libraries before the bundle: hardened runtime rejects unsigned
# code, and --deep gives no control over the order or the entitlements.
sign_args=(--force)
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
	sign_args+=(--options runtime --timestamp --sign "$CODESIGN_IDENTITY")
else
	sign_args+=(--sign -)
fi
while IFS= read -r -d '' library; do
	codesign "${sign_args[@]}" "$library"
done < <(find "$app" -name '*.dylib' -print0)
codesign "${sign_args[@]}" "$app"
codesign --verify --deep --strict "$app"

rm -f "$zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip"
sha="$(shasum -a 256 "$zip" | awk '{print $1}')"
printf '%s  %s\n' "$sha" "$(basename "$zip")" > "$output/SHA256SUMS.txt"
cat > "$output/version.json" <<JSON
{
	"commit": "$(git -C "$repo_root" rev-parse HEAD)",
	"platform": "macOS",
	"architecture": "universal",
	"app_version": "$app_version",
	"engine": "$engine_version",
	"template_version": "$(cat "$template_dir/version.txt")",
	"signed": "$([[ -n "${CODESIGN_IDENTITY:-}" ]] && echo developer-id || echo ad-hoc)",
	"bundle": "$(basename "$zip")",
	"sha256": "$sha"
}
JSON
echo "MACOS_BUILD app_version=$app_version engine=$engine_version commit=$(git -C "$repo_root" rev-parse --short HEAD) sha256=$sha"
