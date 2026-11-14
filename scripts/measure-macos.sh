#!/usr/bin/env bash
# Single-process macOS wallpaper measurement harness.
#
# Launches the game with the internal --dev-wallpaper switch, waits for the
# WALLPAPER_ACTIVE marker on stdout, then samples the process at a fixed
# interval into .local/measurements/. No sudo and no network access.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
measure_root="$repo_root/.local/measurements"
app=""
editor=false
window_mode=false
label=""
warmup=20
duration=120
interval=1
count=0
ready_timeout=180
use_footprint=true

usage() {
	cat >&2 <<'EOF'
Usage: scripts/measure-macos.sh [--app PATH.app | --editor] [options]

Target (one of, --editor is the default):
  --app PATH       launch the given .app bundle with --dev-wallpaper
  --editor         run Game/scenes/main.tscn directly with the pinned editor
  --window         run the same scene as an ordinary window, without wallpaper mode

Timing:
  --warmup SEC     seconds to wait after WALLPAPER_ACTIVE before sampling (default 20)
  --duration SEC   measured window in seconds, after warmup (default 120)
  --interval SEC   sampling interval, integer seconds (default 1)
  --count N        stop after N samples; 0 = use --duration (default 0)
  --ready-timeout SEC  fail if WALLPAPER_ACTIVE does not appear (default 180)

Output:
  --label NAME     name embedded in the CSV/log file name
  --no-footprint   skip the per-sample `footprint` call

Writes <stamp>-<label>.csv and <stamp>-<label>.log under .local/measurements/.
The launched process is terminated when the run ends; no measurement is claimed
as an energy result by this script.
EOF
}

need() {
	[[ $# -ge 2 ]] || { echo "Missing value for $1" >&2; exit 2; }
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--app) need "$@"; app="$2"; shift 2 ;;
		--editor) editor=true; shift ;;
		--window) window_mode=true; shift ;;
		--label) need "$@"; label="$2"; shift 2 ;;
		--warmup) need "$@"; warmup="$2"; shift 2 ;;
		--duration) need "$@"; duration="$2"; shift 2 ;;
		--interval) need "$@"; interval="$2"; shift 2 ;;
		--count) need "$@"; count="$2"; shift 2 ;;
		--ready-timeout) need "$@"; ready_timeout="$2"; shift 2 ;;
		--no-footprint) use_footprint=false; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
	esac
done

fail() {
	echo "MEASURE_FAILED: $*" >&2
	exit 1
}

integer() {
	[[ "$1" =~ ^[0-9]+$ ]]
}

integer "$warmup" || fail "--warmup must be a non-negative integer"
integer "$duration" || fail "--duration must be a non-negative integer"
integer "$interval" || fail "--interval must be a positive integer"
integer "$count" || fail "--count must be a non-negative integer"
integer "$ready_timeout" || fail "--ready-timeout must be a non-negative integer"
(( interval > 0 )) || fail "--interval must be at least 1"
(( duration > 0 )) || fail "--duration must be at least 1"

if [[ -n "$app" && "$editor" == true ]]; then
	fail "choose either --app or --editor, not both"
fi
if [[ -n "$app" && "$window_mode" == true ]]; then
	fail "choose either --app or --window, not both"
fi
if [[ "$window_mode" == true ]]; then
	editor=true
fi
if [[ -z "$app" && "$editor" == false ]]; then
	editor=true
fi
if [[ "$use_footprint" == true ]] && ! command -v footprint >/dev/null 2>&1; then
	echo "MEASURE_NOTE footprint not found; phys_footprint column will be empty" >&2
	use_footprint=false
fi

pid=""
cleanup() {
	if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
		kill -TERM "$pid" 2>/dev/null || true
		for _try in 1 2 3 4 5 6 7 8 9 10; do
			kill -0 "$pid" 2>/dev/null || break
			sleep 0.2
		done
		kill -KILL "$pid" 2>/dev/null || true
	fi
	if [[ -n "$pid" ]]; then
		wait "$pid" 2>/dev/null || true
	fi
}
trap cleanup EXIT INT TERM

mkdir -p "$measure_root"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
if [[ -z "$label" && -n "$app" ]]; then
	label="$(basename "${app%/}" .app)"
elif [[ -z "$label" ]]; then
	label="editor-main"
fi
safe_label="$(printf '%s' "$label" | tr -c 'A-Za-z0-9._-' '-')"
run_base="$measure_root/$stamp-$safe_label"
csv="$run_base.csv"
log="$run_base.log"

if [[ -n "$app" ]]; then
	app="${app%/}"
	[[ -d "$app" ]] || fail "app bundle not found: $app"
	executable_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist" 2>/dev/null || true)"
	executable="$app/Contents/MacOS/${executable_name:-$(basename "$app" .app)}"
	[[ -x "$executable" ]] || fail "app executable not found: $executable"
	echo "MEASURE_TARGET app=$app executable=$executable"
	"$executable" -- --dev-wallpaper >"$log" 2>&1 &
	pid=$!
else
	[[ -x "$repo_root/scripts/godot-macos.sh" ]] || fail "missing scripts/godot-macos.sh"
	if [[ "$window_mode" == true ]]; then
		echo "MEASURE_TARGET editor=main.tscn window=normal"
		"$repo_root/scripts/godot-macos.sh" Run res://scenes/main.tscn >"$log" 2>&1 &
	else
		echo "MEASURE_TARGET editor=main.tscn"
		"$repo_root/scripts/godot-macos.sh" Run res://scenes/main.tscn -- --dev-wallpaper >"$log" 2>&1 &
	fi
	pid=$!
fi

ready_pattern='^WALLPAPER_ACTIVE'
ready_name='WALLPAPER_ACTIVE'
if [[ "$window_mode" == true ]]; then
	# FARM_LOAD is printed once the authoritative save has been admitted and the
	# ordinary window is presenting it; it does not depend on wallpaper layers.
	ready_pattern='^FARM_LOAD stage='
	ready_name='FARM_LOAD'
fi

echo "MEASURE_PID $pid"
echo "MEASURE_LOG $log"

start_seconds=$SECONDS
deadline=$((SECONDS + ready_timeout))
while ! grep -q "$ready_pattern" "$log" 2>/dev/null; do
	if ! kill -0 "$pid" 2>/dev/null; then
		status=0
		wait "$pid" 2>/dev/null || status=$?
		pid=""
		echo "--- last log lines ---" >&2
		tail -20 "$log" >&2 || true
		fail "process exited before ${ready_name} (status $status)"
	fi
	if grep -q '^STARTUP_CHOICE_READY' "$log" 2>/dev/null; then
		echo "--- last log lines ---" >&2
		tail -20 "$log" >&2 || true
		fail "startup quality dialog blocked unattended entry; run the app once with saved settings or use --editor, which loads main.tscn directly"
	fi
	if (( SECONDS >= deadline )); then
		echo "--- last log lines ---" >&2
		tail -20 "$log" >&2 || true
		fail "${ready_name} did not appear within ${ready_timeout}s"
	fi
	sleep 0.2
done
echo "MEASURE_READY elapsed=$((SECONDS - start_seconds))s"

for ((waited = 0; waited < warmup; waited++)); do
	kill -0 "$pid" 2>/dev/null || fail "process exited during warmup"
	sleep 1
done

cpu_time_to_seconds() {
	awk -F'[:.]' '{
		if (NF == 4) printf "%.2f", $1 * 3600 + $2 * 60 + $3 + $4 / 100
		else if (NF == 3) printf "%.2f", $1 * 60 + $2 + $3 / 100
		else if (NF == 2) printf "%.2f", $1 * 60 + $2
		else printf "0"
	}' <<<"$1"
}

footprint_kib() {
	# `footprint` is available without sudo for the current user's processes.
	footprint "$1" 2>/dev/null | awk '
		/phys_footprint:/ {
			value = $(NF - 1) + 0
			unit = $NF
			if (unit == "MB") value *= 1024
			else if (unit == "GB") value *= 1024 * 1024
			else if (unit == "B") value /= 1024
			printf "%.0f", value
			exit
		}' || true
}

printf '%s\n' 'timestamp_utc,elapsed_s,phase,sample,pid,cpu_time,cpu_time_s,cpu_percent,cpu_delta_percent,rss_kib,phys_footprint_kib' >"$csv"
sample=0
previous_cpu=""
previous_elapsed=0
measure_start=$SECONDS
while :; do
	if ! kill -0 "$pid" 2>/dev/null; then
		fail "process exited during measurement"
	fi
	line="$(ps -o pid=,time=,%cpu=,rss= -p "$pid" 2>/dev/null || true)"
	[[ -n "$line" ]] || fail "ps returned no data for pid $pid"
	read -r pid_out ps_time ps_cpu ps_rss <<<"$line"
	now_cpu="$(cpu_time_to_seconds "$ps_time")"
	elapsed=$((SECONDS - measure_start))
	if [[ -n "$previous_cpu" ]]; then
		elapsed_delta=$((elapsed - previous_elapsed))
		(( elapsed_delta > 0 )) || elapsed_delta=$interval
		cpu_delta="$(awk -v now="$now_cpu" -v prev="$previous_cpu" -v step="$elapsed_delta" 'BEGIN { printf "%.1f", (now - prev) / step * 100 }')"
	else
		cpu_delta=""
	fi
	previous_cpu="$now_cpu"
	previous_elapsed=$elapsed
	sample=$((sample + 1))
	now_stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
	footprint_value=""
	if [[ "$use_footprint" == true ]]; then
		footprint_value="$(footprint_kib "$pid")"
	fi
	printf '%s,%d,measure,%d,%s,%s,%s,%s,%s,%s,%s\n' \
		"$now_stamp" "$elapsed" "$sample" "$pid_out" "$ps_time" "$now_cpu" \
		"$ps_cpu" "$cpu_delta" "$ps_rss" "$footprint_value" >>"$csv"

	if (( count > 0 && sample >= count )); then
		break
	fi
	if (( SECONDS - measure_start >= duration )); then
		break
	fi
	sleep "$interval"
done

csv_seconds=$((SECONDS - measure_start))
echo "MEASURE_CSV $csv"
echo "MEASURE_SAMPLES $sample"
echo "MEASURE_DURATION ${csv_seconds}s"
awk -F, -v samples="$sample" '
	NR == 1 { next }
	$9 != "" { cpu_sum += $9; cpu_n++ }
	$10 != "" { rss_sum += $10; if ($10 > rss_max) rss_max = $10 }
	$11 != "" { fp_sum += $11; if ($11 > fp_max) fp_max = $11; fp_n++ }
	END {
		if (cpu_n) printf "MEASURE_SUMMARY cpu_delta_mean=%.1f%% ", cpu_sum / cpu_n
		else printf "MEASURE_SUMMARY cpu_delta_mean=na "
		if (samples) printf "rss_mean=%.0fKiB rss_max=%.0fKiB ", rss_sum / samples, rss_max
		if (fp_n) printf "phys_footprint_mean=%.0fKiB phys_footprint_max=%.0fKiB", fp_sum / fp_n, fp_max
		printf "\n"
	}' "$csv"
echo "MEASURE_DONE"
