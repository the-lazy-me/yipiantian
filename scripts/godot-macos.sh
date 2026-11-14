#!/usr/bin/env bash
# macOS entry: import, run, editor and export with the pinned engine.
set -euo pipefail

action="${1:-Editor}"
shift || true
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(tr -d '[:space:]' < "$repo_root/.godot-version")"
project="$repo_root/Game"
godot="${GODOT_PATH:-$(command -v godot || true)}"

if [[ -z "$godot" || ! -x "$godot" ]]; then
	echo "Godot not found. Set GODOT_PATH to the $version macOS editor binary." >&2
	exit 1
fi
actual="$("$godot" --version)"
expected="${version//-/.}."
if [[ "$actual" != "$expected"* ]]; then
	echo "Expected Godot $version; got $actual. Update the engine and templates together." >&2
	exit 1
fi

case "$action" in
	Editor)
		exec "$godot" --path "$project" --editor "$@"
		;;
	Import)
		exec "$godot" --headless --path "$project" --import "$@"
		;;
	Run)
		exec "$godot" --path "$project" --audio-driver Dummy "$@"
		;;
	Export)
		output="${1:-$repo_root/.local/builds/macos/我有一片田.app}"
		if [[ $# -gt 0 ]]; then shift; fi
		mkdir -p "$(dirname "$output")"
		work="$(mktemp -d "${TMPDIR:-/tmp}/yipiantian-export.XXXXXX")"
		trap 'rm -rf "$work"' EXIT
		error_pattern='^[[:space:]]*(ERROR:|SCRIPT ERROR:|Parse Error:)'
		"$godot" --headless --path "$project" --import >"$work/import.log" 2>&1 || {
			tail -80 "$work/import.log" >&2
			echo "Fresh import failed; see the log above." >&2
			exit 1
		}
		if grep -Eq "$error_pattern" "$work/import.log"; then
			# The configured project font is requested before its first cold import.
			# Only this known startup miss may be retried; any other error fails.
			font_pattern="^ERROR: (Cannot open file 'res://\.godot/imported/汇文明朝体\.ttf-[0-9a-f]+\.fontdata'\.|Failed loading resource: res://(?:\.godot/imported/汇文明朝体\.ttf-[0-9a-f]+\.fontdata|art/ui/fonts/汇文明朝体\.ttf)\.|Error loading custom project font 'res://art/ui/fonts/汇文明朝体\.ttf')$"
			grep -E "$error_pattern" "$work/import.log" > "$work/errors.log"
			if grep -Evq "$font_pattern" "$work/errors.log"; then
				cat "$work/errors.log" >&2
				echo "Import reported errors other than the initial project-font cache miss." >&2
				exit 1
			fi
			"$godot" --headless --path "$project" --import >"$work/import.log" 2>&1 || true
			if grep -Eq "$error_pattern" "$work/import.log"; then
				cat "$work/import.log" >&2
				echo "Project font did not recover after cold import." >&2
				exit 1
			fi
		fi
		"$godot" --headless --path "$project" --export-release "macOS" "$output" "$@"
		;;
	*)
		echo "Usage: $0 {Editor|Import|Run|Export} [args]" >&2
		exit 2
		;;
esac
