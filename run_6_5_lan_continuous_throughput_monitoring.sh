#!/usr/bin/env bash
set -euo pipefail

TEST_DURATION="${TEST_DURATION:-3600}"
INTERVAL="${INTERVAL:-1}"
PARALLEL="${PARALLEL:-1}"
THRESHOLD_RATIO="${THRESHOLD_RATIO:-0.95}"
LOW_DURATION="${LOW_DURATION:-1}"
REVERSE="${REVERSE:-0}"
SERVER_LOG="${SERVER_LOG:-/tmp/iperf3_6_5_server.log}"
LOG_DIR="${LOG_DIR:-${HOME}/6-5_lan_throughput_$(date +%Y%m%d_%H%M%S)}"

if [[ -t 1 ]]; then
  COLOR_ERROR=$'\033[1;31m'
  COLOR_RESULT=$'\033[1;32m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_ERROR=""
  COLOR_RESULT=""
  COLOR_RESET=""
fi

echo "6-5 LAN Continuous Throughput Monitoring Test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Default duration: ${TEST_DURATION}s"
echo "Interval: ${INTERVAL}s"
echo "Parallel streams: ${PARALLEL}"
echo "Log directory: ${LOG_DIR}"
echo

prompt_server_info() {
  if [[ -t 0 ]]; then
    local duration_input
    read -r -p "Test duration in seconds [${TEST_DURATION}]: " duration_input
    if [[ -n "${duration_input}" ]]; then
      if [[ "${duration_input}" =~ ^[0-9]+$ ]] && [[ "${duration_input}" -gt 0 ]]; then
        TEST_DURATION="${duration_input}"
      else
        echo "ERROR: Test duration must be a positive integer." >&2
        exit 1
      fi
    fi
  fi

  if [[ -z "${SERVER_IP:-}" ]]; then
    read -r -p "Server IP: " SERVER_IP
  fi
  if [[ -z "${SERVER_USER:-}" ]]; then
    read -r -p "Server username: " SERVER_USER
  fi
  if [[ -z "${SERVER_PASS:-}" ]]; then
    read -r -s -p "Server password: " SERVER_PASS
    echo
  fi

  if [[ -z "${SERVER_IP}" || -z "${SERVER_USER}" || -z "${SERVER_PASS}" ]]; then
    echo "ERROR: Server IP, username, and password are required." >&2
    exit 1
  fi
}

install_local_tools() {
  local missing=()

  command -v iperf3 >/dev/null 2>&1 || missing+=(iperf3)
  command -v sshpass >/dev/null 2>&1 || missing+=(sshpass)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "Installing local package(s): ${missing[*]}"
    sudo apt-get update
    sudo apt-get install -y "${missing[@]}"
    echo
  fi

  if ! python3 - <<'PY' >/dev/null 2>&1
import matplotlib
PY
  then
    echo "Installing python3-matplotlib..."
    sudo apt-get update
    sudo apt-get install -y python3-matplotlib
    echo
  fi
}

ssh_server() {
  SSHPASS="${SERVER_PASS}" sshpass -e ssh \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
    -o ConnectTimeout=10 \
    "${SERVER_USER}@${SERVER_IP}" "$@"
}

prepare_server() {
  echo "=== Server setup ==="
  ssh_server "if command -v iperf3 >/dev/null 2>&1; then echo 'Server iperf3 is already installed; skipping server install.'; else echo 'Installing iperf3 on server...'; echo '${SERVER_PASS}' | sudo -S apt-get update && echo '${SERVER_PASS}' | sudo -S apt-get install -y iperf3; fi"
  ssh_server "if ! pgrep -x iperf3 >/dev/null 2>&1; then nohup iperf3 -s > '${SERVER_LOG}' 2>&1 < /dev/null & fi"
  sleep 2
  ssh_server "pgrep -x -a iperf3 || { echo 'ERROR: iperf3 server did not start' >&2; exit 1; }"
  echo "Server iperf3 is running on ${SERVER_IP}."
  echo "Server log: ${SERVER_USER}@${SERVER_IP}:${SERVER_LOG}"
  echo
}

run_client_test() {
  local raw_log="$1"
  local raw_text="$2"
  local err_file="${LOG_DIR}/iperf3_stderr.txt"
  local cmd=(iperf3 -c "${SERVER_IP}" -t "${TEST_DURATION}" -i "${INTERVAL}" -P "${PARALLEL}" --forceflush)

  if [[ "${REVERSE}" == "1" || "${REVERSE}" == "true" || "${REVERSE}" == "TRUE" ]]; then
    cmd+=(-R)
  fi

  echo "=== Client test ==="
  echo "Command: ${cmd[*]}"
  echo "Live status: refreshing one line only. Full log: ${raw_log}"
  echo

  set +e
  : >"${raw_log}"
  : >"${err_file}"
  "${cmd[@]}" 2>"${err_file}" | while IFS= read -r line; do
    printf '%s\n' "${line}" >>"${raw_log}"
    if [[ "${line}" =~ sec[[:space:]]+.+bits/sec ]]; then
      printf '\r%-120s' "Latest: ${line:0:112}"
    fi
  done
  local rc=$?
  printf '\n'
  set -e

  {
    echo "Command: ${cmd[*]}"
    echo "Exit code: ${rc}"
    echo
    echo "----- stderr -----"
    cat "${err_file}" 2>/dev/null || true
    echo
    echo "----- iperf3 log -----"
    cat "${raw_log}" 2>/dev/null || true
  } >"${raw_text}"

  if [[ "${rc}" -ne 0 ]]; then
    echo "ERROR: iperf3 client failed with exit code ${rc}" >&2
    cat "${err_file}" >&2
    return "${rc}"
  fi
}

analyze_results() {
  local raw_log="$1"
  local csv_file="$2"
  local png_file="$3"
  local summary_file="$4"

  python3 - "${raw_log}" "${csv_file}" "${png_file}" "${summary_file}" \
    "${THRESHOLD_RATIO}" "${LOW_DURATION}" "${SERVER_IP}" "${TEST_DURATION}" \
    "${INTERVAL}" "${PARALLEL}" "${REVERSE}" <<'PY'
import csv
import os
import re
import statistics
import sys
from pathlib import Path

import matplotlib
if not os.environ.get("DISPLAY"):
    matplotlib.use("Agg")
import matplotlib.pyplot as plt

raw_log = Path(sys.argv[1])
csv_file = Path(sys.argv[2])
png_file = Path(sys.argv[3])
summary_file = Path(sys.argv[4])
threshold_ratio = float(sys.argv[5])
low_duration = max(1, int(float(sys.argv[6])))
server_ip = sys.argv[7]
duration = int(float(sys.argv[8]))
interval = int(float(sys.argv[9]))
parallel = int(float(sys.argv[10]))
reverse = sys.argv[11]

def to_mbps(value, unit):
    value = float(value)
    unit = unit.lower()
    if unit.startswith("k"):
        return value / 1000.0
    if unit.startswith("m"):
        return value
    if unit.startswith("g"):
        return value * 1000.0
    if unit.startswith("t"):
        return value * 1000.0 * 1000.0
    return value

throughputs = []
interval_line = re.compile(
    r"\]\s+\d+(?:\.\d+)?-\d+(?:\.\d+)?\s+sec\s+"
    r"[\d.]+\s+\S+Bytes\s+([\d.]+)\s+([KMGTP]?bits/sec)"
)
sum_interval_line = re.compile(
    r"\[SUM\]\s+\d+(?:\.\d+)?-\d+(?:\.\d+)?\s+sec\s+"
    r"[\d.]+\s+\S+Bytes\s+([\d.]+)\s+([KMGTP]?bits/sec)"
)

lines = raw_log.read_text(encoding="utf-8", errors="replace").splitlines()
for line in lines:
    if "sender" in line or "receiver" in line:
        continue
    match = sum_interval_line.search(line)
    if match:
        throughputs.append(to_mbps(match.group(1), match.group(2)))
        continue
    if parallel == 1:
        match = interval_line.search(line)
        if match:
            throughputs.append(to_mbps(match.group(1), match.group(2)))

if not throughputs:
    raise SystemExit("ERROR: no interval throughput data found in iperf3 log")

avg = statistics.mean(throughputs)
threshold = avg * threshold_ratio

segments = []
start = None
for idx, value in enumerate(throughputs):
    if value < threshold:
        if start is None:
            start = idx
    else:
        if start is not None and idx - start >= low_duration:
            segments.append((start, idx - 1))
        start = None
if start is not None and len(throughputs) - start >= low_duration:
    segments.append((start, len(throughputs) - 1))

with csv_file.open("w", newline="", encoding="utf-8") as fh:
    writer = csv.writer(fh)
    writer.writerow(["second", "throughput_mbps", f"alert_below_{threshold:.2f}_mbps"])
    for idx, value in enumerate(throughputs):
        alert = "consecutive_low_bandwidth" if any(start <= idx <= end for start, end in segments) else ""
        writer.writerow([idx, f"{value:.2f}", alert])

seconds = list(range(len(throughputs)))
plt.figure(figsize=(12, 6))
plt.plot(seconds, throughputs, label="Throughput (Mbps)", color="blue")
plt.axhline(threshold, color="gray", linestyle="--", label=f"Threshold: {threshold:.2f} Mbps")
label_used = False
for start, end in segments:
    plt.axvspan(start - 0.95, end + 0.95, color="purple", alpha=0.95, label="Consecutive Low Bandwidth" if not label_used else None)
    label_used = True
plt.title("LAN Throughput Over Time (Auto Threshold)")
plt.xlabel("Time (s)")
plt.ylabel("Throughput (Mbps)")
plt.grid(True)
plt.legend()
plt.tight_layout()
plt.savefig(png_file)
plt.close()

summary = {
    "server": server_ip,
    "duration_sec": duration,
    "interval_sec": interval,
    "parallel": parallel,
    "reverse": reverse,
    "samples": len(throughputs),
    "average_mbps": avg,
    "minimum_mbps": min(throughputs),
    "maximum_mbps": max(throughputs),
    "threshold_ratio": threshold_ratio,
    "threshold_mbps": threshold,
    "low_segments": [{"start_sec": start, "end_sec": end} for start, end in segments],
}
summary_file.write_text(json.dumps(summary, indent=2), encoding="utf-8")

print(f"Average throughput: {avg:.2f} Mbps")
print(f"Minimum throughput: {min(throughputs):.2f} Mbps")
print(f"Maximum throughput: {max(throughputs):.2f} Mbps")
print(f"Threshold: {threshold:.2f} Mbps")
print(f"Low segments: {segments if segments else 'none'}")
print(f"CSV: {csv_file}")
print(f"PNG: {png_file}")
print(f"Summary: {summary_file}")
PY
}

prompt_server_info
install_local_tools
mkdir -p "${LOG_DIR}"
prepare_server

RAW_LOG="${LOG_DIR}/6-5_lan_throughput_raw.log"
RAW_TEXT="${LOG_DIR}/6-5_lan_throughput_iperf3.txt"
CSV_FILE="${LOG_DIR}/6-5_lan_throughput.csv"
PNG_FILE="${LOG_DIR}/6-5_lan_throughput.png"
SUMMARY_FILE="${LOG_DIR}/6-5_lan_throughput_summary.json"

if run_client_test "${RAW_LOG}" "${RAW_TEXT}"; then
  analyze_results "${RAW_LOG}" "${CSV_FILE}" "${PNG_FILE}" "${SUMMARY_FILE}" | tee "${LOG_DIR}/analysis.log"
  echo
  printf '%sRESULT,LAN Continuous Throughput,6-5,PASS%s\n' "${COLOR_RESULT}" "${COLOR_RESET}"
  echo "Artifacts: ${LOG_DIR}"
else
  echo
  printf '%sRESULT,LAN Continuous Throughput,6-5,FAIL%s\n' "${COLOR_ERROR}" "${COLOR_RESET}"
  echo "Artifacts: ${LOG_DIR}"
  exit 1
fi
