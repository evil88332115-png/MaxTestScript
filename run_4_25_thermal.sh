#!/usr/bin/env bash
set -euo pipefail

NAS_VIDEO="${NAS_VIDEO:-/mnt/nas_home/TestVideo.mp4}"
VIDEO_DEST="${VIDEO_DEST:-${HOME}/TestVideo.mp4}"
LOG_DIR="${LOG_DIR:-${HOME}/4-25_thermal_$(date +%Y%m%d_%H%M%S)}"
DURATION="${DURATION:-30m}"
TEGRATS_INTERVAL_MS="${TEGRATS_INTERVAL_MS:-1000}"
PLAYER="${PLAYER:-nvgstplayer-1.0}"
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
python3 - "${TEGRATS_LOG}" "${CSV_FILE}" "${PNG_FILE}" "${SVG_FILE}" "${TEGRATS_INTERVAL_MS}" <<'PY'
import csv
import math
import re
import sys
from pathlib import Path

tegrastats_log = Path(sys.argv[1])
csv_file = Path(sys.argv[2])
png_file = Path(sys.argv[3])
svg_file = Path(sys.argv[4])
interval_s = float(sys.argv[5]) / 1000.0

lines = tegrastats_log.read_text(errors="replace").splitlines()
pattern = re.compile(r"([A-Za-z0-9_./-]+)@([+-]?\d+(?:\.\d+)?)C")

rows = []
sensors = []
seen = set()

for idx, line in enumerate(lines):
    values = {}
    for name, value in pattern.findall(line):
        if name not in seen:
            seen.add(name)
            sensors.append(name)
        values[name] = float(value)
    if values:
        rows.append({"sample": len(rows), "seconds": len(rows) * interval_s, "values": values})

if not rows:
    csv_file.write_text("sample,seconds\n", encoding="utf-8")
    svg_file.write_text(
        "<svg xmlns='http://www.w3.org/2000/svg' width='1200' height='650'>"
        "<text x='40' y='80' font-family='Arial' font-size='28'>No temperature data parsed from tegrastats.log</text>"
        "</svg>\n",
        encoding="utf-8",
    )
    print("WARNING: no temperature data parsed")
    raise SystemExit(0)

with csv_file.open("w", newline="", encoding="utf-8") as fh:
    writer = csv.writer(fh)
    writer.writerow(["sample", "seconds", *sensors])
    for row in rows:
        writer.writerow([
            row["sample"],
            row["seconds"],
            *[row["values"].get(sensor, "") for sensor in sensors],
        ])

series = {sensor: [] for sensor in sensors}
seconds = [row["seconds"] for row in rows]
for row in rows:
    for sensor in sensors:
        series[sensor].append(row["values"].get(sensor))

try:
    import matplotlib.pyplot as plt

    plt.figure(figsize=(12, 6.5), dpi=140)
    for sensor in sensors:
        y = [math.nan if v is None else v for v in series[sensor]]
        plt.plot(seconds, y, linewidth=1.8, label=sensor)
    plt.title("4-25 Thermal - 30 min video playback")
    plt.xlabel("Time (s)")
    plt.ylabel("Temperature (C)")
    plt.grid(True, alpha=0.3)
    plt.legend(loc="best", fontsize=8)
    plt.tight_layout()
    plt.savefig(png_file)
    plt.close()
    print(f"PNG chart: {png_file}")
except Exception as exc:
    print(f"WARNING: matplotlib PNG chart skipped: {exc}")

width, height = 1200, 650
left, right, top, bottom = 80, 240, 55, 90
plot_w = width - left - right
plot_h = height - top - bottom
all_values = [v for values in series.values() for v in values if v is not None]
y_min = math.floor(min(all_values) / 5) * 5
y_max = math.ceil(max(all_values) / 5) * 5
if y_min == y_max:
    y_min -= 5
    y_max += 5
x_max = max(seconds) if seconds else 1
if x_max == 0:
    x_max = 1

colors = [
    "#1f77b4", "#d62728", "#2ca02c", "#9467bd", "#ff7f0e", "#17becf",
    "#8c564b", "#e377c2", "#7f7f7f", "#bcbd22", "#003f5c", "#58508d",
]

def x_pos(sec):
    return left + (sec / x_max) * plot_w

def y_pos(temp):
    return top + (y_max - temp) / (y_max - y_min) * plot_h

svg = []
svg.append(f"<svg xmlns='http://www.w3.org/2000/svg' width='{width}' height='{height}' viewBox='0 0 {width} {height}'>")
svg.append("<rect width='100%' height='100%' fill='white'/>")
svg.append("<text x='80' y='35' font-family='Arial' font-size='24' font-weight='700'>4-25 Thermal - 30 min video playback</text>")
svg.append(f"<line x1='{left}' y1='{top}' x2='{left}' y2='{top + plot_h}' stroke='#333'/>")
svg.append(f"<line x1='{left}' y1='{top + plot_h}' x2='{left + plot_w}' y2='{top + plot_h}' stroke='#333'/>")

for i in range(6):
    temp = y_min + (y_max - y_min) * i / 5
    y = y_pos(temp)
    svg.append(f"<line x1='{left}' y1='{y:.1f}' x2='{left + plot_w}' y2='{y:.1f}' stroke='#ddd'/>")
    svg.append(f"<text x='{left - 10}' y='{y + 4:.1f}' text-anchor='end' font-family='Arial' font-size='12'>{temp:.0f}</text>")

for i in range(7):
    sec = x_max * i / 6
    x = x_pos(sec)
    svg.append(f"<line x1='{x:.1f}' y1='{top + plot_h}' x2='{x:.1f}' y2='{top + plot_h + 5}' stroke='#333'/>")
    svg.append(f"<text x='{x:.1f}' y='{top + plot_h + 24}' text-anchor='middle' font-family='Arial' font-size='12'>{sec/60:.0f}</text>")

svg.append(f"<text x='{left + plot_w/2}' y='{height - 25}' text-anchor='middle' font-family='Arial' font-size='14'>Time (min)</text>")
svg.append(f"<text x='22' y='{top + plot_h/2}' transform='rotate(-90 22 {top + plot_h/2})' text-anchor='middle' font-family='Arial' font-size='14'>Temperature (C)</text>")

for idx, sensor in enumerate(sensors):
    color = colors[idx % len(colors)]
    points = []
    for sec, temp in zip(seconds, series[sensor]):
        if temp is not None:
            points.append(f"{x_pos(sec):.1f},{y_pos(temp):.1f}")
    if len(points) >= 2:
        svg.append(f"<polyline fill='none' stroke='{color}' stroke-width='2' points='{' '.join(points)}'/>")
    lx = left + plot_w + 24
    ly = top + 20 + idx * 22
    svg.append(f"<line x1='{lx}' y1='{ly - 5}' x2='{lx + 24}' y2='{ly - 5}' stroke='{color}' stroke-width='3'/>")
    svg.append(f"<text x='{lx + 32}' y='{ly}' font-family='Arial' font-size='13'>{sensor}</text>")

svg.append("</svg>")
svg_file.write_text("\n".join(svg) + "\n", encoding="utf-8")
print(f"CSV: {csv_file}")
print(f"SVG chart: {svg_file}")
print(f"Samples: {len(rows)}")
print(f"Sensors: {', '.join(sensors)}")
PY

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
