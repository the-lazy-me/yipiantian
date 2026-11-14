#!/usr/bin/env bash
# Build an unsigned macOS app bundle and a manifest tying it to this commit.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine_version="$(tr -d '[:space:]' < "$repo_root/.godot-version")"
app_version="$(sed -n 's/^config\/version="\(.*\)"$/\1/p' "$repo_root/Game/project.godot")"
template_dir="${GODOT_TEMPLATE_DIR:-$HOME/Library/Application Support/Godot/export_templates/${engine_version//-/.}}"
output="${1:-$repo_root/.local/builds/macos}"
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

mkdir -p "$output"
rm -rf "$app"
"$repo_root/scripts/godot-macos.sh" Export "$app"

# Ad-hoc signing keeps the arm64 bundle launchable when no developer identity is
# configured. Release packages must use a Developer ID identity and notarization.
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
	codesign --force --deep --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$app"
else
	codesign --force --deep --sign - "$app"
fi

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
