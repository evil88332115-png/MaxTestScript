#!/usr/bin/env bash
set -euo pipefail

NAS_VIDEO="${NAS_VIDEO:-/mnt/nas_home/TestVideo.mp4}"
VIDEO_DEST="${VIDEO_DEST:-${HOME}/TestVideo.mp4}"
LOG_DIR="${LOG_DIR:-${HOME}/4-25_thermal_$(date +%Y%m%d_%H%M%S)}"
DURATION="${DURATION:-30m}"
TEGRATS_INTERVAL_MS="${TEGRATS_INTERVAL_MS:-1000}"
PLAYER="${PLAYER:-nvgstplayer-1.0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRAW_TEMP_SCRIPT="${DRAW_TEMP_SCRIPT:-${SCRIPT_DIR}/drawtempcurve_auto.py}"
DRAW_TEMP_MODE="${DRAW_TEMP_MODE:-cpu_gpu}"
DRAW_TEMP_AVG_MIN="${DRAW_TEMP_AVG_MIN:-0}"
export DISPLAY="${DISPLAY:-:0}"
SCRIPT_PID="$$"

file_uri() {
  local path="$1"
  printf 'file://%s' "${path}"
}

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

cleanup() {
  if [[ -n "${TEGRATS_PID:-}" ]] && kill -0 "${TEGRATS_PID}" 2>/dev/null; then
    kill -INT "${TEGRATS_PID}" 2>/dev/null || true
    wait "${TEGRATS_PID}" 2>/dev/null || true
  fi
  if [[ -n "${WATCHDOG_PID:-}" ]] && kill -0 "${WATCHDOG_PID}" 2>/dev/null; then
    kill "${WATCHDOG_PID}" 2>/dev/null || true
    wait "${WATCHDOG_PID}" 2>/dev/null || true
  fi
}
trap cleanup INT TERM

echo "4.25 Thermal test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "NAS video: ${NAS_VIDEO}"
echo "Local video: ${VIDEO_DEST}"
echo "Duration: ${DURATION}"
echo "Log directory: ${LOG_DIR}"
echo

if [[ ! -f "${NAS_VIDEO}" ]]; then
  echo "ERROR: NAS video not found: ${NAS_VIDEO}" >&2
  echo "Please mount NAS first, for example: ${HOME}/run_0_mount_nas.sh" >&2
  exit 1
fi

if ! command -v timeout >/dev/null 2>&1; then
  echo "ERROR: timeout not found." >&2
  exit 1
fi

if ! command -v "${PLAYER}" >/dev/null 2>&1; then
  echo "ERROR: ${PLAYER} not found." >&2
  exit 1
fi

if ! command -v tegrastats >/dev/null 2>&1; then
  echo "ERROR: tegrastats not found." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found." >&2
  exit 1
fi

mkdir -p "${LOG_DIR}"

if [[ -f "${VIDEO_DEST}" ]] && [[ "$(stat -c %s "${VIDEO_DEST}")" == "$(stat -c %s "${NAS_VIDEO}")" ]]; then
  echo "Local test video already exists; skipping copy."
else
  echo "Copying test video from NAS..."
  cp -f "${NAS_VIDEO}" "${VIDEO_DEST}"
  sync "${VIDEO_DEST}" || true
fi
ls -lh "${VIDEO_DEST}"
echo

TEGRATS_LOG="${LOG_DIR}/tegrastats.log"
PLAYER_LOG="${LOG_DIR}/nvgstplayer.log"
CSV_FILE="${LOG_DIR}/4-25_thermal.csv"
PNG_FILE="${LOG_DIR}/4-25_thermal.png"
SVG_FILE="${LOG_DIR}/4-25_thermal.svg"
SUMMARY_FILE="${LOG_DIR}/summary.txt"

echo "Starting tegrastats and video playback..."
echo "tegrastats log: ${TEGRATS_LOG}"
echo "player log: ${PLAYER_LOG}"
echo "DISPLAY: ${DISPLAY:-not set}"
echo

set +e
timeout "${DURATION}" tegrastats --interval "${TEGRATS_INTERVAL_MS}" >"${TEGRATS_LOG}" 2>&1 &
TEGRATS_PID=$!

cd "${HOME}" || exit 1
{
  echo "Date: $(date --iso-8601=seconds)"
  echo "Command: ${PLAYER} -i $(file_uri "${VIDEO_DEST}") --loop-forever"
  echo "DISPLAY: ${DISPLAY:-not set}"
  echo "Note: --loop-forever keeps the video playing; background timer stops it after ${DURATION}."
} >"${PLAYER_LOG}"

(
  sleep "${DURATION}"
  pkill -INT -u "$(id -u)" -x "${PLAYER}" 2>/dev/null || true
) &
WATCHDOG_PID=$!

"${PLAYER}" -i "$(file_uri "${VIDEO_DEST}")" --loop-forever
PLAYER_RC=$?

if kill -0 "${WATCHDOG_PID}" 2>/dev/null; then
  kill "${WATCHDOG_PID}" 2>/dev/null || true
  wait "${WATCHDOG_PID}" 2>/dev/null || true
fi

{
  echo
  echo "Player exit code: ${PLAYER_RC}"
  echo "End date: $(date --iso-8601=seconds)"
} >>"${PLAYER_LOG}"

if [[ "${PLAYER_RC}" -ne 124 ]] && kill -0 "${TEGRATS_PID}" 2>/dev/null; then
  kill -INT "${TEGRATS_PID}" 2>/dev/null || true
fi
if kill -0 "${TEGRATS_PID}" 2>/dev/null; then
  wait "${TEGRATS_PID}"
else
  wait "${TEGRATS_PID}" 2>/dev/null
fi
TEGRATS_RC=$?
set -e

trap - INT TERM

echo "Parsing tegrastats temperature data..."
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

if [[ ! -f "${DRAW_TEMP_SCRIPT}" ]]; then
  echo "ERROR: drawtemp script not found: ${DRAW_TEMP_SCRIPT}" >&2
  echo "Please put drawtempcurve_auto.py in the same folder, or set DRAW_TEMP_SCRIPT=/path/to/drawtempcurve_auto.py" >&2
  exit 1
fi

echo "Drawing temperature curve with drawtemp..."
echo "Draw mode: ${DRAW_TEMP_MODE}"
echo "Average interval: ${DRAW_TEMP_AVG_MIN} min"
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
  echo "NAS video: ${NAS_VIDEO}"
  echo "Local video: ${VIDEO_DEST}"
  echo "Player command: ${PLAYER} -i $(file_uri "${VIDEO_DEST}") --loop-forever"
  echo "Player watchdog: sleep ${DURATION}; pkill -INT -x ${PLAYER}"
  echo "Tegrastats command: timeout ${DURATION} tegrastats --interval ${TEGRATS_INTERVAL_MS}"
  echo "Player exit code: ${PLAYER_RC}"
  echo "Tegrastats exit code: ${TEGRATS_RC}"
  echo "Tegrastats log: ${TEGRATS_LOG}"
  echo "Player log: ${PLAYER_LOG}"
  echo "CSV: ${CSV_FILE}"
  echo "PNG: ${PNG_FILE}"
  echo "SVG: ${SVG_FILE}"
} >"${SUMMARY_FILE}"

echo
cat "${SUMMARY_FILE}"
echo

if [[ "${TEGRATS_RC}" -eq 124 ]]; then
  printf '%sRESULT,Thermal,4-25,PASS%s\n' "${COLOR_RESULT}" "${COLOR_RESET}"
else
  printf '%sRESULT,Thermal,4-25,FAIL,player_rc=%s,tegrastats_rc=%s%s\n' "${COLOR_ERROR}" "${PLAYER_RC}" "${TEGRATS_RC}" "${COLOR_RESET}"
  exit 1
fi

echo "Artifacts: ${LOG_DIR}"
