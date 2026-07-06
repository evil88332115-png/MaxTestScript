#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 5-5 Display Resolution Test
#
# Ensure a playback video exists, start playback, then switch
# display resolutions one by one. The operator presses Enter to
# move to the next resolution.
#
# Defaults:
#   NAS video:   /mnt/nas_home/TestVideo.mp4
#   Local video: ~/TestVideo.mp4
# ============================================================

NAS_VIDEO="${NAS_VIDEO:-/mnt/nas_home/TestVideo.mp4}"
VIDEO_DEST="${VIDEO_DEST:-${HOME}/TestVideo.mp4}"
VIDEO_URL="${VIDEO_URL:-https://download.samplelib.com/mp4/sample-30s.mp4}"
LOG_DIR="${LOG_DIR:-/tmp/display_resolution_5_5_logs}"
PLAYER="${PLAYER:-gst-launch-1.0}"
DISPLAY_SYNC="${DISPLAY_SYNC:-true}"
AUTO_ADVANCE_SECONDS="${AUTO_ADVANCE_SECONDS:-}"
VERIFY_TIMEOUT_SECONDS="${VERIFY_TIMEOUT_SECONDS:-8}"
VERIFY_INTERVAL_SECONDS="${VERIFY_INTERVAL_SECONDS:-1}"
MIN_WIDTH="${MIN_WIDTH:-720}"
MIN_HEIGHT="${MIN_HEIGHT:-576}"
MODE_SOURCE="unknown"
GNOME_INTERFACE_SCHEMA="org.gnome.desktop.interface"
GNOME_MUTTER_SCHEMA="org.gnome.mutter"
ORIGINAL_SCALING_FACTOR=""
ORIGINAL_TEXT_SCALING_FACTOR=""
ORIGINAL_EXPERIMENTAL_FEATURES=""
PLAYBACK_PID=""
PLAYBACK_STOP_REQUESTED=false
export DISPLAY="${DISPLAY:-:0}"

if [[ -t 1 ]]; then
  RED=$'\033[31m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  NC=$'\033[0m'
else
  RED=""
  GREEN=""
  YELLOW=""
  NC=""
fi

pass() { printf '%s%s%s\n' "${GREEN}" "$*" "${NC}"; }
fail() { printf '%s%s%s\n' "${RED}" "$*" "${NC}"; }
warn() { printf '%s%s%s\n' "${YELLOW}" "$*" "${NC}"; }

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
}

setup_display() {
  local uid xauth

  export DISPLAY

  if [[ -z "${XAUTHORITY:-}" ]]; then
    uid="$(id -u)"
    for xauth in \
      "${HOME}/.Xauthority" \
      "/run/user/${uid}/gdm/Xauthority" \
      "/run/user/${uid}/Xauthority"; do
      if [[ -r "${xauth}" ]]; then
        export XAUTHORITY="${xauth}"
        break
      fi
    done
  fi
}

file_uri() {
  local path="$1"
  printf 'file://%s' "${path}"
}

ensure_video_file() {
  mkdir -p "$(dirname "${VIDEO_DEST}")"

  if [[ -s "${VIDEO_DEST}" ]]; then
    echo "Local playback video exists: ${VIDEO_DEST}"
    ls -lh "${VIDEO_DEST}"
    return 0
  fi

  if [[ -s "${NAS_VIDEO}" ]]; then
    echo "Local playback video not found."
    echo "Copying NAS video to local:"
    echo "  From: ${NAS_VIDEO}"
    echo "  To:   ${VIDEO_DEST}"
    cp -f "${NAS_VIDEO}" "${VIDEO_DEST}"
    sync "${VIDEO_DEST}" || true
    ls -lh "${VIDEO_DEST}"
    return 0
  fi

  echo "Local playback video not found: ${VIDEO_DEST}"
  echo "NAS playback video not found: ${NAS_VIDEO}"
  echo "Downloading playback video:"
  echo "  URL: ${VIDEO_URL}"
  echo "  To:  ${VIDEO_DEST}"

  require_cmd wget
  wget -O "${VIDEO_DEST}.download" "${VIDEO_URL}"
  mv -f "${VIDEO_DEST}.download" "${VIDEO_DEST}"
  sync "${VIDEO_DEST}" || true
  ls -lh "${VIDEO_DEST}"
}

get_connected_output() {
  xrandr --display "$DISPLAY" | awk '/ connected/ { print $1; exit }'
}

get_current_resolution() {
  local output="$1"
  xrandr --display "$DISPLAY" | awk -v output="$output" '
    $1 == output && $2 == "connected" {
      for (i=1; i<=NF; i++) {
        if ($i ~ /^[0-9]+x[0-9]+\+/) {
          split($i, parts, "+")
          print parts[1]
          exit
        }
      }
    }
    in_output && /\*/ {
      print $1
      exit
    }
    $1 == output && $2 == "connected" { in_output=1; next }
    /^[A-Za-z0-9-]+ connected/ && $1 != output { in_output=0 }
  '
}

list_resolutions_desc() {
  local output="$1"
  xrandr --display "$DISPLAY" | awk -v output="$output" '
    $1 == output && $2 == "connected" { in_output=1; next }
    /^[A-Za-z0-9-]+ connected/ && $1 != output { in_output=0 }
    in_output && $1 ~ /^[0-9]+x[0-9]+$/ {
      split($1, dim, "x")
      key = dim[1] * dim[2]
      if (!seen[$1]++) {
        printf "%d %d %s\n", key, dim[1], $1
      }
    }
  ' | sort -k1,1nr -k2,2nr | awk '{ print $3 }'
}

list_resolutions_from_mutter_desc() {
  local output="$1"

  if ! command -v gdbus >/dev/null 2>&1; then
    return 1
  fi

  gdbus call --session \
    --dest org.gnome.Mutter.DisplayConfig \
    --object-path /org/gnome/Mutter/DisplayConfig \
    --method org.gnome.Mutter.DisplayConfig.GetCurrentState 2>/dev/null \
    | python3 - "$output" "$MIN_WIDTH" "$MIN_HEIGHT" <<'PY'
import re
import sys

min_width = int(sys.argv[2])
min_height = int(sys.argv[3])
text = sys.stdin.read()

pattern = re.compile(
    r"\('([^']+)',\s*([0-9]+),\s*([0-9]+),\s*([0-9.]+),\s*[0-9.]+,\s*\[[^\]]*\],\s*\{([^}]*)\}\)"
)

seen = {}
for mode_id, width, height, refresh, props in pattern.findall(text):
    if "x" not in mode_id:
        continue
    try:
        w = int(width)
        h = int(height)
        hz = float(refresh)
    except ValueError:
        continue
    if w < min_width or h < min_height:
        continue

    resolution = f"{w}x{h}"
    priority = hz
    if "is-current" in props:
        priority += 100000
    if "is-preferred" in props:
        priority += 50000
    old = seen.get(resolution)
    if old is None or priority > old[0]:
        seen[resolution] = (priority, w * h, w)

for resolution, (_priority, area, width) in sorted(
    seen.items(), key=lambda item: (-item[1][1], -item[1][2], item[0])
):
    print(resolution)
PY
}

list_resolutions_from_xrandr_filtered_desc() {
  local output="$1"
  list_resolutions_desc "$output" | awk -F'x' -v min_w="$MIN_WIDTH" -v min_h="$MIN_HEIGHT" '
    $1 >= min_w && $2 >= min_h { print $0 }
  '
}

save_gnome_scaling() {
  if ! command -v gsettings >/dev/null 2>&1; then
    return 0
  fi

  ORIGINAL_SCALING_FACTOR="$(gsettings get "$GNOME_INTERFACE_SCHEMA" scaling-factor 2>/dev/null || true)"
  ORIGINAL_TEXT_SCALING_FACTOR="$(gsettings get "$GNOME_INTERFACE_SCHEMA" text-scaling-factor 2>/dev/null || true)"
  ORIGINAL_EXPERIMENTAL_FEATURES="$(gsettings get "$GNOME_MUTTER_SCHEMA" experimental-features 2>/dev/null || true)"
}

force_100_percent_scaling() {
  if command -v gsettings >/dev/null 2>&1; then
    gsettings set "$GNOME_INTERFACE_SCHEMA" scaling-factor 1 2>/dev/null || true
    gsettings set "$GNOME_INTERFACE_SCHEMA" text-scaling-factor 1.0 2>/dev/null || true
  fi
}

restore_gnome_scaling() {
  if ! command -v gsettings >/dev/null 2>&1; then
    return 0
  fi

  echo ""
  echo "Restoring GNOME scaling settings if available..."
  if [[ -n "$ORIGINAL_SCALING_FACTOR" ]]; then
    gsettings set "$GNOME_INTERFACE_SCHEMA" scaling-factor "$ORIGINAL_SCALING_FACTOR" 2>/dev/null || true
  fi
  if [[ -n "$ORIGINAL_TEXT_SCALING_FACTOR" ]]; then
    gsettings set "$GNOME_INTERFACE_SCHEMA" text-scaling-factor "$ORIGINAL_TEXT_SCALING_FACTOR" 2>/dev/null || true
  fi
  if [[ -n "$ORIGINAL_EXPERIMENTAL_FEATURES" ]]; then
    gsettings set "$GNOME_MUTTER_SCHEMA" experimental-features "$ORIGINAL_EXPERIMENTAL_FEATURES" 2>/dev/null || true
  fi
}

switch_resolution() {
  local output="$1"
  local resolution="$2"
  echo ""
  echo "Switching ${output} to ${resolution}"
  echo "Command: xrandr --display ${DISPLAY} --output ${output} --mode ${resolution} --scale 1x1"
  xrandr --display "$DISPLAY" --output "$output" --mode "$resolution" --scale 1x1
  force_100_percent_scaling
}

verify_resolution() {
  local output="$1"
  local expected="$2"
  local elapsed=0
  local current=""

  while [[ "$elapsed" -le "$VERIFY_TIMEOUT_SECONDS" ]]; do
    current="$(get_current_resolution "$output")"
    if [[ "$current" == "$expected" ]]; then
      pass "RESULT,DISPLAY_RESOLUTION,${output},${expected},MODE_PASS"
      return 0
    fi
    sleep "$VERIFY_INTERVAL_SECONDS"
    elapsed=$((elapsed + VERIFY_INTERVAL_SECONDS))
  done

  fail "RESULT,DISPLAY_RESOLUTION,${output},${expected},MODE_FAIL,current=${current:-unknown}"
  return 1
}

start_playback_loop() {
  local source="$1"
  local log="$2"
  local uri
  uri="$(file_uri "$source")"

  {
    echo "Playback source: ${source}"
    echo "Playback URI: ${uri}"
    echo "Player: ${PLAYER}"
    echo "Started: $(date --iso-8601=seconds)"
    echo
  } >"${log}"

  (
    child_pid=""
    stop_child() {
      if [[ -n "${child_pid}" ]] && kill -0 "${child_pid}" 2>/dev/null; then
        kill -TERM "${child_pid}" 2>/dev/null || true
        sleep 1
        kill -KILL "${child_pid}" 2>/dev/null || true
      fi
      exit 0
    }
    trap stop_child TERM INT
    while [[ "${PLAYBACK_STOP_REQUESTED}" != "true" ]]; do
      if [[ "${PLAYER}" == "gst-launch-1.0" ]]; then
        gst-launch-1.0 -e playbin uri="${uri}" video-sink="nv3dsink sync=${DISPLAY_SYNC}" >>"${log}" 2>&1 &
      else
        "${PLAYER}" -i "${uri}" >>"${log}" 2>&1 &
      fi
      child_pid=$!
      wait "${child_pid}" || true
      child_pid=""
      sleep 1
    done
  ) &
  PLAYBACK_PID=$!
  echo "Playback started in background. PID: ${PLAYBACK_PID}"
  echo "Playback log: ${log}"
}

stop_playback() {
  PLAYBACK_STOP_REQUESTED=true
  if [[ -n "${PLAYBACK_PID}" ]] && kill -0 "${PLAYBACK_PID}" 2>/dev/null; then
    kill -TERM "${PLAYBACK_PID}" 2>/dev/null || true
    sleep 1
    kill -KILL "${PLAYBACK_PID}" 2>/dev/null || true
    wait "${PLAYBACK_PID}" 2>/dev/null || true
  fi
}

cleanup() {
  stop_playback
  if [[ -n "${OUTPUT:-}" && -n "${MAX_RESOLUTION:-}" ]]; then
    echo ""
    echo "Returning to maximum resolution: ${MAX_RESOLUTION}"
    xrandr --display "$DISPLAY" --output "$OUTPUT" --mode "$MAX_RESOLUTION" --scale 1x1 2>/dev/null || true
  fi
  restore_gnome_scaling
}

handle_interrupt() {
  echo ""
  echo "Interrupted. Stopping playback and restoring display..."
  cleanup
  exit 130
}

prompt_next_resolution() {
  local output="$1"
  local resolution="$2"
  local answer

  if [[ ! -t 0 ]]; then
    if [[ -n "${AUTO_ADVANCE_SECONDS}" ]]; then
      warn "Non-interactive shell; continuing automatically after ${AUTO_ADVANCE_SECONDS}s for resolution ${resolution}."
      sleep "${AUTO_ADVANCE_SECONDS}"
      return 0
    fi
    echo "ERROR: interactive stdin is required so the operator can press Enter after checking the display." >&2
    echo "Run this script from the Jetson terminal, or use SSH with a TTY." >&2
    echo "For automated dry runs only, set AUTO_ADVANCE_SECONDS=3." >&2
    return 2
  fi

  echo ""
  echo "Video should be playing at ${resolution} on ${output}."
  read -r -p "Press Enter to switch to next resolution. Type n to mark FAIL and continue: " answer
  case "$answer" in
    n|N|no|NO)
      fail "RESULT,DISPLAY_RESOLUTION_PLAYBACK,${output},${resolution},VISIBLE_FAIL"
      return 1
      ;;
    *)
      pass "RESULT,DISPLAY_RESOLUTION_PLAYBACK,${output},${resolution},VISIBLE_PASS"
      return 0
      ;;
  esac
}

echo "======================================"
echo "5-5 Display Resolution Test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "DISPLAY: ${DISPLAY}"
echo "Minimum resolution: ${MIN_WIDTH}x${MIN_HEIGHT}"
echo "NAS video: ${NAS_VIDEO}"
echo "Local video: ${VIDEO_DEST}"
echo "Download URL: ${VIDEO_URL}"
echo "Auto advance: ${AUTO_ADVANCE_SECONDS:-disabled}"
echo "======================================"

require_cmd xrandr
require_cmd python3
require_cmd "${PLAYER}"
setup_display
save_gnome_scaling
trap handle_interrupt INT TERM

ensure_video_file

OUTPUT="${OUTPUT:-$(get_connected_output)}"
if [[ -z "$OUTPUT" ]]; then
  echo "ERROR: no connected display output found by xrandr." >&2
  exit 1
fi

mapfile -t RESOLUTIONS < <(list_resolutions_from_mutter_desc "$OUTPUT")
if [[ "${#RESOLUTIONS[@]}" -gt 0 ]]; then
  MODE_SOURCE="gnome-mutter-displayconfig"
else
  warn "Could not read resolutions from GNOME Mutter DisplayConfig; fallback to xrandr."
  mapfile -t RESOLUTIONS < <(list_resolutions_from_xrandr_filtered_desc "$OUTPUT")
  MODE_SOURCE="xrandr"
fi

if [[ "${#RESOLUTIONS[@]}" -eq 0 ]]; then
  echo "ERROR: no resolutions found for output: $OUTPUT" >&2
  xrandr --display "$DISPLAY"
  exit 1
fi

ORIGINAL_RESOLUTION="$(get_current_resolution "$OUTPUT")"
MAX_RESOLUTION="${RESOLUTIONS[0]}"

echo ""
echo "Output: ${OUTPUT}"
echo "Resolution source: ${MODE_SOURCE}"
echo "Original resolution: ${ORIGINAL_RESOLUTION:-unknown}"
echo "Detected resolutions from largest to smallest:"
for resolution in "${RESOLUTIONS[@]}"; do
  echo "  ${resolution}"
done
echo ""
echo "The video will start first. Press Enter after checking each resolution."

if [[ -t 0 ]]; then
  read -r -p "Press Enter to start, or type n to cancel: " answer
  case "$answer" in
    n|N|no|NO)
      echo "Canceled."
      exit 0
      ;;
  esac
elif [[ -z "${AUTO_ADVANCE_SECONDS}" ]]; then
  echo "ERROR: interactive stdin is required for this test." >&2
  echo "Run this script from the Jetson terminal, or use SSH with a TTY." >&2
  echo "For automated dry runs only, set AUTO_ADVANCE_SECONDS=3." >&2
  exit 2
fi

mkdir -p "${LOG_DIR}"
PLAYBACK_LOG="${LOG_DIR}/playback.log"
start_playback_loop "${VIDEO_DEST}" "${PLAYBACK_LOG}"
sleep 3

overall_rc=0
for resolution in "${RESOLUTIONS[@]}"; do
  if switch_resolution "$OUTPUT" "$resolution" && verify_resolution "$OUTPUT" "$resolution"; then
    if ! prompt_next_resolution "$OUTPUT" "$resolution"; then
      overall_rc=1
    fi
  else
    overall_rc=1
  fi
done

cleanup
trap - INT TERM

echo ""
echo "Playback log: ${PLAYBACK_LOG}"
if [[ "$overall_rc" -eq 0 ]]; then
  pass "TEST COMPLETE: 5-5 Display Resolution = PASS"
else
  fail "TEST COMPLETE: 5-5 Display Resolution = FAIL"
fi

exit "$overall_rc"
