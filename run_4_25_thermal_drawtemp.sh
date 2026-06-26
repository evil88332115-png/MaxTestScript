#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 4-25 Thermal test with drawtemp
#
# Playback source:
#   1. Download/copy NAS video to local, then play local file
#   2. Direct playback from same NAS video path, without local copy
#
# Playback engine:
#   Fixed GStreamer hardware decode pipeline:
#     H.264/H.265/VP9/AV1 -> nvv4l2decoder -> nvvidconv -> nv3dsink
#
# Output:
#   ~/4-25_thermal_YYYYMMDD_HHMMSS/
#     tegrastats.log
#     gst_playback.log
#     4-25_thermal.csv
#     4-25_thermal.png   (CPU+GPU only)
#     summary.txt
# ============================================================

NAS_VIDEO="${NAS_VIDEO:-/mnt/nas_home/TestVideo.mp4}"
VIDEO_DEST="${VIDEO_DEST:-${HOME}/TestVideo.mp4}"
LOG_DIR="${LOG_DIR:-${HOME}/4-25_thermal_$(date +%Y%m%d_%H%M%S)}"
DURATION="${DURATION:-30m}"
TEGRATS_INTERVAL_MS="${TEGRATS_INTERVAL_MS:-1000}"
DISPLAY_SYNC="${DISPLAY_SYNC:-true}"
FORCE_FULLSCREEN="${FORCE_FULLSCREEN:-true}"
STOP_REQUESTED=false
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAW_TEMP_SCRIPT="${DRAW_TEMP_SCRIPT:-${SCRIPT_DIR}/drawtempcurve_auto.py}"
DRAW_TEMP_MODE="cpu_gpu"
DRAW_TEMP_AVG_MIN="${DRAW_TEMP_AVG_MIN:-0}"
export DISPLAY="${DISPLAY:-:0}"

if [[ -t 1 ]]; then
  COLOR_ERROR=$'\033[1;31m'
  COLOR_WARN=$'\033[1;33m'
  COLOR_RESULT=$'\033[1;32m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_ERROR=""
  COLOR_WARN=""
  COLOR_RESULT=""
  COLOR_RESET=""
fi

print_warn() { printf '%s%s%s\n' "${COLOR_WARN}" "$*" "${COLOR_RESET}"; }
print_error() { printf '%s%s%s\n' "${COLOR_ERROR}" "$*" "${COLOR_RESET}"; }
print_result() { printf '%s%s%s\n' "${COLOR_RESULT}" "$*" "${COLOR_RESET}"; }

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

cleanup() {
  STOP_REQUESTED=true
  if [[ -n "${GST_PID:-}" ]] && kill -0 "${GST_PID}" 2>/dev/null; then
    kill -INT "${GST_PID}" 2>/dev/null || true
    sleep 1
    kill -TERM "${GST_PID}" 2>/dev/null || true
  fi
  if [[ -n "${TEGRATS_PID:-}" ]] && kill -0 "${TEGRATS_PID}" 2>/dev/null; then
    kill -INT "${TEGRATS_PID}" 2>/dev/null || true
  fi
}
handle_interrupt() {
  echo ""
  echo "Stop requested. Stopping playback and finishing current logs..."
  cleanup
}
trap handle_interrupt INT TERM

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 1
  fi
}

file_uri() {
  local path="$1"
  printf 'file://%s' "${path}"
}

print_command() {
  echo ""
  echo "Command:"
  printf '  '
  printf '%q ' "$@"
  echo ""
  echo ""
}

set_gst_window_fullscreen() {
  local gst_pid="$1"
  local win_id=""
  local deadline

  [[ "$FORCE_FULLSCREEN" == "true" ]] || return 0

  if ! command -v wmctrl >/dev/null 2>&1 || ! command -v xdotool >/dev/null 2>&1; then
    echo "WARNING: wmctrl/xdotool not found; cannot force borderless fullscreen." >>"${PLAYER_LOG}"
    echo "Install with: sudo apt-get install -y wmctrl xdotool" >>"${PLAYER_LOG}"
    return 0
  fi

  deadline=$(($(date +%s) + 10))
  while [[ "$(date +%s)" -lt "$deadline" ]]; do
    win_id="$(xdotool search --onlyvisible --pid "$gst_pid" 2>/dev/null | head -n 1 || true)"
    if [[ -n "$win_id" ]]; then
      break
    fi
    sleep 0.5
  done

  if [[ -z "$win_id" ]]; then
    win_id="$(wmctrl -lp 2>/dev/null | awk -v pid="$gst_pid" '$3 == pid { print $1; exit }' || true)"
  fi

  if [[ -n "$win_id" ]]; then
    echo "Force fullscreen window id: $win_id" >>"${PLAYER_LOG}"
    wmctrl -ir "$win_id" -b add,fullscreen >>"${PLAYER_LOG}" 2>&1 || true
    xdotool windowactivate "$win_id" >>"${PLAYER_LOG}" 2>&1 || true
  else
    echo "WARNING: cannot find GStreamer window for fullscreen." >>"${PLAYER_LOG}"
  fi
}

duration_to_seconds() {
  local value="$1"
  case "$value" in
    *s) echo "${value%s}" ;;
    *m) echo "$((${value%m} * 60))" ;;
    *h) echo "$((${value%h} * 3600))" ;;
    *[!0-9]*)
      echo "ERROR: unsupported DURATION format: $value" >&2
      echo "Use integer seconds, or suffix s/m/h, for example 1800, 30m, 1h." >&2
      return 1
      ;;
    *) echo "$value" ;;
  esac
}

probe_video_codec() {
  ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1 || true
}

probe_audio_codec() {
  ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1 || true
}

probe_format() {
  ffprobe -v error -show_entries format=format_name -of default=nw=1:nk=1 "$1" 2>/dev/null | head -n 1 || true
}

get_parser() {
  case "$1" in
    h264) echo "h264parse" ;;
    hevc|h265) echo "h265parse" ;;
    vp9) gst-inspect-1.0 vp9parse >/dev/null 2>&1 && echo "vp9parse" || echo "" ;;
    av1) gst-inspect-1.0 av1parse >/dev/null 2>&1 && echo "av1parse" || echo "" ;;
    *) echo "" ;;
  esac
}

get_demux() {
  local source="$1" format="${2:-}" lower
  lower="$(echo "$source" | tr '[:upper:]' '[:lower:]')"
  if echo "$format" | grep -qiE 'mpegts'; then echo "tsdemux"; return; fi
  if echo "$format" | grep -qiE 'matroska|webm'; then echo "matroskademux"; return; fi
  if echo "$format" | grep -qiE 'mov|mp4|m4a|3gp|3g2|mj2'; then echo "qtdemux"; return; fi
  case "$lower" in
    *.mp4|*.m4v|*.mov|*.3gp) echo "qtdemux" ;;
    *.mkv|*.webm) echo "matroskademux" ;;
    *.m2ts|*.mts|*.ts) echo "tsdemux" ;;
    *) echo "" ;;
  esac
}

select_source_mode() {
  local choice input
  echo ""
  echo "Playback source mode:"
  echo "1) Download/copy NAS video to local and play local file"
  echo "2) Direct playback from same NAS video path, no local copy"
  read -r -p "Select [1/2]: " choice

  case "$choice" in
    2)
      SOURCE_MODE="nas_direct"
      echo "NAS video: $NAS_VIDEO"
      if [[ ! -f "$NAS_VIDEO" ]]; then
        echo "ERROR: NAS video not found: $NAS_VIDEO" >&2
        echo "Please mount NAS first and put TestVideo.mp4 at the expected path." >&2
        exit 1
      fi
      ls -lh "$NAS_VIDEO"
      SOURCE="$NAS_VIDEO"
      SOURCE_LABEL="$NAS_VIDEO"
      ;;
    *)
      SOURCE_MODE="local"
      echo "NAS video: $NAS_VIDEO"
      echo "Local video: $VIDEO_DEST"
      if [[ ! -f "$NAS_VIDEO" ]]; then
        echo "ERROR: NAS video not found: $NAS_VIDEO" >&2
        echo "Please mount NAS first and put TestVideo.mp4 at the expected path." >&2
        exit 1
      fi
      if [[ -f "$VIDEO_DEST" ]] && [[ "$(stat -c %s "$VIDEO_DEST")" == "$(stat -c %s "$NAS_VIDEO")" ]]; then
        echo "Local test video already exists; skipping copy."
      else
        echo "Copying test video from NAS to local..."
        cp -f "$NAS_VIDEO" "$VIDEO_DEST"
        sync "$VIDEO_DEST" || true
      fi
      ls -lh "$VIDEO_DEST"
      SOURCE="$VIDEO_DEST"
      SOURCE_LABEL="$VIDEO_DEST"
      ;;
  esac
}

build_gst_command() {
  local source="$1" mode="$2" codec="$3" format="$4"
  local parser demux source_element source_prop

  parser="$(get_parser "$codec")"
  demux="$(get_demux "$source" "$format")"

  [[ -n "$parser" ]] || { echo "ERROR: unsupported codec for fixed HW pipeline: $codec" >&2; return 1; }
  [[ -n "$demux" ]] || { echo "ERROR: unsupported container/demuxer: $format" >&2; return 1; }

  source_element="filesrc"
  source_prop="location=$source"

  GST_CMD=(
    gst-launch-1.0 -e
    "$source_element" "$source_prop" !
    "$demux" name=demux
    demux.video_0 ! queue ! "$parser" ! nvv4l2decoder ! nvvidconv ! nv3dsink sync="$DISPLAY_SYNC"
  )
}

parse_tegrastats_csv() {
  python3 - "${TEGRATS_LOG}" "${CSV_FILE}" "${TEGRATS_INTERVAL_MS}" <<'PYCSV'
import csv
import re
import sys
from pathlib import Path

tegrastats_log = Path(sys.argv[1])
csv_file = Path(sys.argv[2])
interval_s = float(sys.argv[3]) / 1000.0

lines = tegrastats_log.read_text(errors="replace").splitlines()
pattern = re.compile(r"([A-Za-z0-9_./-]+)@([+-]?\d+(?:\.\d+)?)C")
rows = []
sensors = []
seen = set()

for line in lines:
    values = {}
    for name, value in pattern.findall(line):
        key = name.lower()
        if key not in seen:
            seen.add(key)
            sensors.append(key)
        values[key] = float(value)
    if values:
        rows.append({"sample": len(rows), "seconds": len(rows) * interval_s, "values": values})

with csv_file.open("w", newline="", encoding="utf-8") as fh:
    writer = csv.writer(fh)
    writer.writerow(["sample", "seconds", *sensors])
    for row in rows:
        writer.writerow([
            row["sample"],
            row["seconds"],
            *[row["values"].get(sensor, "") for sensor in sensors],
        ])

print(f"CSV: {csv_file}")
print(f"Samples: {len(rows)}")
print(f"Sensors: {', '.join(sensors) if sensors else 'none'}")
PYCSV
}

echo "4.25 Thermal test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Duration: ${DURATION}"
echo "Log directory: ${LOG_DIR}"
echo "Display sync: ${DISPLAY_SYNC}"
echo "Force fullscreen: ${FORCE_FULLSCREEN}"
echo

require_cmd timeout
require_cmd gst-launch-1.0
require_cmd gst-inspect-1.0
require_cmd ffprobe
require_cmd tegrastats
require_cmd python3
setup_display

select_source_mode

VIDEO_CODEC="$(probe_video_codec "$SOURCE")"
AUDIO_CODEC="$(probe_audio_codec "$SOURCE")"
FORMAT_NAME="$(probe_format "$SOURCE")"
VIDEO_CODEC="${VIDEO_CODEC:-}"
AUDIO_CODEC="${AUDIO_CODEC:-none}"
FORMAT_NAME="${FORMAT_NAME:-unknown}"

echo ""
echo "Source mode: $SOURCE_MODE"
echo "Source: $SOURCE_LABEL"
echo "Format: $FORMAT_NAME"
echo "Video codec: $VIDEO_CODEC"
echo "Audio codec: $AUDIO_CODEC"

mkdir -p "$LOG_DIR"

TEGRATS_LOG="${LOG_DIR}/tegrastats.log"
PLAYER_LOG="${LOG_DIR}/gst_playback.log"
CSV_FILE="${LOG_DIR}/4-25_thermal.csv"
PNG_FILE="${LOG_DIR}/4-25_thermal.png"
SUMMARY_FILE="${LOG_DIR}/summary.txt"

build_gst_command "$SOURCE" "$SOURCE_MODE" "$VIDEO_CODEC" "$FORMAT_NAME"

echo ""
echo "Starting tegrastats and hardware decode playback..."
echo "tegrastats log: ${TEGRATS_LOG}"
echo "playback log: ${PLAYER_LOG}"
echo "DISPLAY: ${DISPLAY:-not set}"
echo "XAUTHORITY: ${XAUTHORITY:-not set}"
print_command "${GST_CMD[@]}"

set +e
timeout "${DURATION}" tegrastats --interval "${TEGRATS_INTERVAL_MS}" >"${TEGRATS_LOG}" 2>&1 &
TEGRATS_PID=$!

DURATION_SECONDS="$(duration_to_seconds "$DURATION")"
END_TS=$(($(date +%s) + DURATION_SECONDS))
PLAYER_RC=0
PLAY_LOOP_COUNT=0

{
  echo "Date: $(date --iso-8601=seconds)"
  echo "Duration: ${DURATION} (${DURATION_SECONDS} seconds)"
  echo "Command: ${GST_CMD[*]}"
  echo "Note: gst-launch plays one file once; this script loops it until duration is reached."
  echo
} >"${PLAYER_LOG}"

while true; do
  if [[ "$STOP_REQUESTED" == "true" ]]; then
    break
  fi

  NOW_TS="$(date +%s)"
  REMAINING_SECONDS=$((END_TS - NOW_TS))
  if [[ "${REMAINING_SECONDS}" -le 0 ]]; then
    break
  fi

  PLAY_LOOP_COUNT=$((PLAY_LOOP_COUNT + 1))
  {
    echo
    echo "===== Playback loop ${PLAY_LOOP_COUNT} start: $(date --iso-8601=seconds), remaining=${REMAINING_SECONDS}s ====="
  } >>"${PLAYER_LOG}"

  timeout "${REMAINING_SECONDS}s" "${GST_CMD[@]}" >>"${PLAYER_LOG}" 2>&1 &
  GST_PID=$!
  set_gst_window_fullscreen "$GST_PID"
  wait "$GST_PID"
  LOOP_RC=$?

  if [[ "$STOP_REQUESTED" == "true" ]]; then
    PLAYER_RC=130
    break
  fi

  {
    echo "===== Playback loop ${PLAY_LOOP_COUNT} end: $(date --iso-8601=seconds), rc=${LOOP_RC} ====="
  } >>"${PLAYER_LOG}"

  if [[ "${LOOP_RC}" -eq 124 || "${LOOP_RC}" -eq 130 ]]; then
    PLAYER_RC=0
    break
  fi

  if [[ "${LOOP_RC}" -ne 0 ]]; then
    PLAYER_RC="${LOOP_RC}"
    break
  fi
done

if kill -0 "${TEGRATS_PID}" 2>/dev/null; then
  kill -INT "${TEGRATS_PID}" 2>/dev/null || true
fi
wait "${TEGRATS_PID}" 2>/dev/null
TEGRATS_RC=$?
set -e

trap - INT TERM

echo ""
echo "Parsing tegrastats temperature data..."
parse_tegrastats_csv

if [[ ! -f "${DRAW_TEMP_SCRIPT}" ]]; then
  echo "ERROR: drawtemp script not found: ${DRAW_TEMP_SCRIPT}" >&2
  echo "Please put drawtempcurve_auto.py in the same folder, or set DRAW_TEMP_SCRIPT=/path/to/drawtempcurve_auto.py" >&2
  exit 1
fi

echo "Drawing CPU+GPU temperature curve with drawtemp..."
python3 "${DRAW_TEMP_SCRIPT}" \
  --file "${TEGRATS_LOG}" \
  --mode "${DRAW_TEMP_MODE}" \
  --avg-min "${DRAW_TEMP_AVG_MIN}" \
  --interval-ms "${TEGRATS_INTERVAL_MS}" \
  --out "${PNG_FILE}"

{
  echo "4.25 Thermal test summary"
  echo "Host: $(hostname)"
  echo "Date: $(date --iso-8601=seconds)"
  echo "Duration: ${DURATION}"
  echo "Source mode: ${SOURCE_MODE}"
  echo "Source: ${SOURCE_LABEL}"
  echo "Format: ${FORMAT_NAME}"
  echo "Video codec: ${VIDEO_CODEC}"
  echo "Audio codec: ${AUDIO_CODEC}"
  echo "GStreamer command: ${GST_CMD[*]}"
  echo "Playback loops: ${PLAY_LOOP_COUNT}"
  echo "Stop requested: ${STOP_REQUESTED}"
  echo "Tegrastats command: timeout ${DURATION} tegrastats --interval ${TEGRATS_INTERVAL_MS}"
  echo "Playback exit code: ${PLAYER_RC}"
  echo "Tegrastats exit code: ${TEGRATS_RC}"
  echo "Tegrastats log: ${TEGRATS_LOG}"
  echo "Playback log: ${PLAYER_LOG}"
  echo "CSV: ${CSV_FILE}"
  echo "PNG: ${PNG_FILE}"
} >"${SUMMARY_FILE}"

echo
cat "${SUMMARY_FILE}"
echo

if [[ "${PLAYER_RC}" -eq 0 || "${PLAYER_RC}" -eq 130 || "${PLAYER_RC}" -eq 124 ]]; then
  print_result "RESULT,Thermal,4-25,PASS"
else
  print_error "RESULT,Thermal,4-25,FAIL,player_rc=${PLAYER_RC},tegrastats_rc=${TEGRATS_RC}"
  echo "Last 40 playback log lines:"
  tail -n 40 "$PLAYER_LOG" || true
  exit 1
fi

echo "Artifacts: ${LOG_DIR}"
