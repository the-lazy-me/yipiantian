#!/usr/bin/env bash
# Submit a built macOS .app or .zip to Apple's notary service, staple the
# resulting ticket, and verify the result locally.
#
# Usage: scripts/notarize-macos.sh <path.app|path.zip>
#
# Credentials come from the environment only; this script stores nothing.
# Use either:
#   NOTARY_PROFILE
#       A keychain profile already created with
#       `xcrun notarytool store-credentials <name> ...`.
#   APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
#       An Apple ID, Developer Team ID, and app-specific password.
#       Prefer NOTARY_PROFILE: an environment password is still passed to
#       notarytool as a command-line argument.
#
# The input must already be Developer ID signed with the hardened runtime and
# a secure timestamp. A .app is stapled in place. A .zip is left untouched:
# its app is extracted, stapled, and written to <name>.notarized.zip.
set -euo pipefail

die() {
	printf 'notarize-macos: %s\n' "$*" >&2
	exit 1
}

if [[ $# -ne 1 ]]; then
	printf 'Usage: %s <path.app|path.zip>\n' "$0" >&2
	exit 2
fi

input=${1%/}
[[ -e "$input" ]] || die "input not found: $input"
case "$input" in
	*.app | *.zip) ;;
	*) die "expected a .app bundle or .zip archive: $input" ;;
esac

command -v xcrun >/dev/null 2>&1 || die "xcrun not found; install Xcode command line tools"
command -v codesign >/dev/null 2>&1 || die "codesign not found"
command -v spctl >/dev/null 2>&1 || die "spctl not found"

auth=()
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
	auth=(--keychain-profile "$NOTARY_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" ]]; then
	auth=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
else
	die "missing notary credentials: set NOTARY_PROFILE, or all of APPLE_ID, APPLE_TEAM_ID and APPLE_APP_PASSWORD"
fi

workdir=$(mktemp -d "${TMPDIR:-/tmp}/yipiantian-notarize.XXXXXX")
trap 'rm -rf "$workdir"' EXIT

mode=${input##*.}
if [[ "$mode" == "app" ]]; then
	app=$input
	submit_file="$workdir/$(basename "$app" .app).zip"
	ditto -c -k --keepParent "$app" "$submit_file"
else
	extract_dir="$workdir/extract"
	mkdir -p "$extract_dir"
	ditto -x -k "$input" "$extract_dir"
	apps=()
	while IFS= read -r -d '' candidate; do
		apps+=("$candidate")
	done < <(find "$extract_dir" -mindepth 1 -maxdepth 1 -type d -name '*.app' -print0)
	[[ ${#apps[@]} -eq 1 ]] || die "expected exactly one top-level .app in $input, found ${#apps[@]}"
	app=${apps[0]}
	submit_file=$input
fi
[[ -d "$app" ]] || die "not an app bundle: $app"

printf 'Submitting %s to the Apple notary service...\n' "$submit_file" >&2
submit_log="$workdir/submit.json"
if ! xcrun notarytool submit "$submit_file" "${auth[@]}" --wait --output-format json >"$submit_log"; then
	cat "$submit_log" >&2 || true
	die "notarytool submit failed"
fi
status=$(/usr/bin/plutil -extract status raw -o - -- "$submit_log" 2>/dev/null || true)
if [[ "$status" != "Accepted" ]]; then
	cat "$submit_log" >&2
	die "notarization not accepted (status: ${status:-unknown})"
fi

xcrun stapler staple "$app"
xcrun stapler validate "$app"

if [[ "$mode" == "zip" ]]; then
	stapled_zip="${input%.zip}.notarized.zip"
	rm -f "$stapled_zip"
	ditto -c -k --sequesterRsrc --keepParent "$app" "$stapled_zip"
	printf 'Stapled archive: %s\n' "$stapled_zip" >&2
fi

codesign --verify --deep --strict --verbose=2 "$app"
spctl -a -vv -t exec "$app"

gatekeeper_status=$(spctl --status 2>/dev/null || true)
case "$gatekeeper_status" in
	*disabled*)
		printf 'notarize-macos: warning: Gatekeeper assessments are disabled on this host; the spctl result above is not a real policy check.\n' >&2
		;;
esac

printf 'Notarization accepted and ticket stapled: %s\n' "$app"
