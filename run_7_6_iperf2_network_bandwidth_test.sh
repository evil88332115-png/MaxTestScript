#!/usr/bin/env bash
set -euo pipefail

WINDOW_SIZE="${WINDOW_SIZE:-100M}"
TEST_DURATION="${TEST_DURATION:-120}"
INTERVAL="${INTERVAL:-1}"
SERVER_LOG="${SERVER_LOG:-/tmp/iperf2_7_6_server.log}"
LOG_DIR="${LOG_DIR:-${HOME}/7-6_iperf2_bandwidth_$(date +%Y%m%d_%H%M%S)}"
REPORT_TIMESTAMP="${REPORT_TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}"

if [[ -t 1 ]]; then
  COLOR_ERROR=$'\033[1;31m'
  COLOR_RESULT=$'\033[1;32m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_ERROR=""
  COLOR_RESULT=""
  COLOR_RESET=""
fi

echo "7-6 iperf2 Network Bandwidth Test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Window size: ${WINDOW_SIZE}"
echo "Duration: ${TEST_DURATION}s"
echo "Interval: ${INTERVAL}s"
echo "Log directory: ${LOG_DIR}"
echo

prompt_server_info() {
  if [[ -z "${SERVER_IP:-}" ]]; then
    read -r -p "Server IP for iperf test: " SERVER_IP
  fi
  if [[ -z "${SERVER_USER:-}" ]]; then
    read -r -p "Server username: " SERVER_USER
  fi
  if [[ -z "${SERVER_PASS:-}" ]]; then
    read -r -s -p "Server password: " SERVER_PASS
    echo
  fi

  if [[ -z "${SERVER_IP}" || -z "${SERVER_USER}" || -z "${SERVER_PASS}" ]]; then
    echo "ERROR: server IP, username, and password are required." >&2
    exit 1
  fi

  python3 - "${SERVER_IP}" <<'PY'
import ipaddress
import sys

try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit("ERROR: invalid IP address format")
PY
}

install_local_tools() {
  local missing=()

  command -v iperf >/dev/null 2>&1 || missing+=(iperf)
  command -v sshpass >/dev/null 2>&1 || missing+=(sshpass)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "Installing local package(s): ${missing[*]}"
    sudo apt-get update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    echo
  fi

  if ! python3 - <<'PY' >/dev/null 2>&1
import matplotlib
PY
  then
    echo "Installing python3-matplotlib..."
    sudo apt-get update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y python3-matplotlib
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
  ssh_server "if command -v iperf >/dev/null 2>&1; then echo 'Server iperf is already installed; skipping server install.'; else echo 'Installing iperf on server...'; echo '${SERVER_PASS}' | sudo -S apt-get update && echo '${SERVER_PASS}' | sudo -S env DEBIAN_FRONTEND=noninteractive apt-get install -y iperf; fi"
  ssh_server "if ! pgrep -x iperf >/dev/null 2>&1; then nohup iperf -s > '${SERVER_LOG}' 2>&1 < /dev/null & fi"
  sleep 2
  ssh_server "pgrep -x -a iperf || { echo 'ERROR: iperf server did not start' >&2; exit 1; }"
  echo "Server iperf is running on ${SERVER_IP}."
  echo "Server log: ${SERVER_USER}@${SERVER_IP}:${SERVER_LOG}"
  echo
}

run_iperf_test() {
  local raw_log="$1"
  local err_file="${LOG_DIR}/iperf2_stderr.txt"
  local cmd=(iperf -c "${SERVER_IP}" -w "${WINDOW_SIZE}" -t "${TEST_DURATION}" -i "${INTERVAL}")
  local line status rc

  echo "=== Client test ==="
  echo "Command: ${cmd[*]}"
  echo "Live status: one short line only. Full log: ${raw_log}"
  echo

  : >"${raw_log}"
  : >"${err_file}"

  set +e
  "${cmd[@]}" 2>"${err_file}" | while IFS= read -r line; do
    printf '%s\n' "${line}" >>"${raw_log}"
    if [[ "${line}" =~ sec[[:space:]]+.+bits/sec ]]; then
      status="${line}"
      if [[ "${line}" =~ ([0-9]+(\.[0-9]+)?)-([0-9]+(\.[0-9]+)?)[[:space:]]+sec[[:space:]]+.+[[:space:]]([0-9]+(\.[0-9]+)?)[[:space:]]+([KMGTP]?bits/sec) ]]; then
        status="${BASH_REMATCH[3]}s ${BASH_REMATCH[5]} ${BASH_REMATCH[7]}"
      fi
      if [[ -t 1 ]]; then
        printf '\r%-80s' "Latest: ${status}"
      else
        printf 'Latest: %s\n' "${status}"
      fi
    fi
  done
  rc=$?
  set -e

  if [[ -t 1 ]]; then
    printf '\r%-80s\n' "iperf2 test finished."
  else
    echo
  fi

  if [[ "${rc}" -ne 0 ]]; then
    echo "ERROR: iperf client failed with exit code ${rc}" >&2
    cat "${err_file}" >&2
    return "${rc}"
  fi
}

analyze_results() {
  local raw_log="$1"
  local csv_file="$2"
  local png_file="$3"
  local pdf_file="$4"
  local summary_file="$5"

  python3 - "${raw_log}" "${csv_file}" "${png_file}" "${pdf_file}" "${summary_file}" \
    "${SERVER_IP}" "${WINDOW_SIZE}" "${TEST_DURATION}" "${INTERVAL}" <<'PY'
import csv
import json
import os
import re
import statistics
import sys
from pathlib import Path

import matplotlib
if not os.environ.get("DISPLAY"):
    matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.backends.backend_pdf import PdfPages

raw_log = Path(sys.argv[1])
csv_file = Path(sys.argv[2])
png_file = Path(sys.argv[3])
pdf_file = Path(sys.argv[4])
summary_file = Path(sys.argv[5])
target_ip = sys.argv[6]
window_size = sys.argv[7]
duration = int(float(sys.argv[8]))
interval = int(float(sys.argv[9]))

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

line_re = re.compile(
    r"\]\s+(?P<start>\d+(?:\.\d+)?)-(?P<end>\d+(?:\.\d+)?)\s+sec\s+"
    r"(?P<transfer>[\d.]+)\s+(?P<transfer_unit>\S+Bytes)\s+"
    r"(?P<bw>[\d.]+)\s+(?P<bw_unit>[KMGTP]?bits/sec)"
)

samples = []
for line in raw_log.read_text(encoding="utf-8", errors="replace").splitlines():
    if "sender" in line or "receiver" in line:
        continue
    match = line_re.search(line)
    if not match:
        continue
    start = float(match.group("start"))
    end = float(match.group("end"))
    # Skip iperf final summary line when intervals are enabled.
    if end - start > interval * 1.5 and samples:
        continue
    samples.append({
        "sample": len(samples) + 1,
        "start_sec": start,
        "end_sec": end,
        "bandwidth_mbps": to_mbps(match.group("bw"), match.group("bw_unit")),
    })

if not samples:
    raise SystemExit("ERROR: no iperf interval data parsed")

bandwidths = [item["bandwidth_mbps"] for item in samples]
avg_bandwidth = statistics.mean(bandwidths)
estimated_data_mb = avg_bandwidth * duration / 8.0

with csv_file.open("w", newline="", encoding="utf-8") as fh:
    writer = csv.writer(fh)
    writer.writerow([
        "Timestamp",
        "Target_IP",
        "Window_Size",
        "Duration_sec",
        "Interval_sec",
        "Samples",
        "AverageBandwidth_Mbps",
        "EstimatedData_MB",
    ])
    writer.writerow([
        Path(csv_file).stem.replace("iperf_summary_", ""),
        target_ip,
        window_size,
        duration,
        interval,
        len(samples),
        round(avg_bandwidth, 2),
        round(estimated_data_mb, 2),
    ])

plt.figure(figsize=(10, 6))
plt.plot([item["sample"] for item in samples], bandwidths, marker="o", color="blue")
plt.title(
    f"Iperf Bandwidth Test to {target_ip}\n"
    f"Avg: {avg_bandwidth:.2f} Mbps, Est. Data: {estimated_data_mb:.2f} MB"
)
plt.xlabel("Sample Index")
plt.ylabel("Bandwidth (Mbits/sec)")
plt.grid(True)
plt.tight_layout()
plt.savefig(png_file)

with PdfPages(pdf_file) as pdf:
    pdf.savefig()
plt.close()

summary = {
    "target_ip": target_ip,
    "window_size": window_size,
    "duration_sec": duration,
    "interval_sec": interval,
    "samples": len(samples),
    "average_bandwidth_mbps": avg_bandwidth,
    "minimum_bandwidth_mbps": min(bandwidths),
    "maximum_bandwidth_mbps": max(bandwidths),
    "estimated_data_mb": estimated_data_mb,
}
summary_file.write_text(json.dumps(summary, indent=2), encoding="utf-8")

print(f"Samples: {len(samples)}")
print(f"Average bandwidth: {avg_bandwidth:.2f} Mbps")
print(f"Minimum bandwidth: {min(bandwidths):.2f} Mbps")
print(f"Maximum bandwidth: {max(bandwidths):.2f} Mbps")
print(f"Estimated data: {estimated_data_mb:.2f} MB")
print(f"CSV: {csv_file}")
print(f"PNG: {png_file}")
print(f"PDF: {pdf_file}")
print(f"Summary: {summary_file}")
PY
}

install_local_tools
prompt_server_info
mkdir -p "${LOG_DIR}"
prepare_server

RAW_LOG="${LOG_DIR}/7-6_iperf2_raw.log"
CSV_FILE="${LOG_DIR}/iperf_summary_${REPORT_TIMESTAMP}.csv"
PNG_FILE="${LOG_DIR}/iperf_summary_${REPORT_TIMESTAMP}.png"
PDF_FILE="${LOG_DIR}/iperf_summary_${REPORT_TIMESTAMP}.pdf"
SUMMARY_FILE="${LOG_DIR}/iperf_summary_${REPORT_TIMESTAMP}.json"

if run_iperf_test "${RAW_LOG}"; then
  analyze_results "${RAW_LOG}" "${CSV_FILE}" "${PNG_FILE}" "${PDF_FILE}" "${SUMMARY_FILE}" | tee "${LOG_DIR}/analysis.log"
  echo
  printf '%sRESULT,iperf2 Network Bandwidth,7-6,PASS%s\n' "${COLOR_RESULT}" "${COLOR_RESET}"
  echo "Artifacts: ${LOG_DIR}"
else
  echo
  printf '%sRESULT,iperf2 Network Bandwidth,7-6,FAIL%s\n' "${COLOR_ERROR}" "${COLOR_RESET}"
  echo "Artifacts: ${LOG_DIR}"
  exit 1
fi
