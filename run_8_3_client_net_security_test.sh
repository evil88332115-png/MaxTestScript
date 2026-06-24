#!/usr/bin/env bash
set -euo pipefail

TOTAL_DURATION="${TOTAL_DURATION:-43200}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-1}"
IPERF_TEST_DURATION="${IPERF_TEST_DURATION:-120}"
HTTP_TARGET="${HTTP_TARGET:-https://example.com}"
SERVER_LOG="${SERVER_LOG:-/tmp/iperf3_8_3_server.log}"
LOG_DIR="${LOG_DIR:-${HOME}/8-3_client_net_security_$(date +%Y%m%d_%H%M%S)}"

echo "8-3 Client Network Security Test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Log directory: ${LOG_DIR}"
echo

install_requirements() {
  local missing=()

  command -v ping >/dev/null 2>&1 || missing+=(iputils-ping)
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v iperf3 >/dev/null 2>&1 || missing+=(iperf3)
  command -v sshpass >/dev/null 2>&1 || missing+=(sshpass)
  command -v python3 >/dev/null 2>&1 || missing+=(python3)

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "Installing package(s): ${missing[*]}"
    sudo apt-get update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
    echo
  fi

  if ! python3 - <<'PY' >/dev/null 2>&1
import pandas
import matplotlib
PY
  then
    echo "Installing Python report packages..."
    sudo apt-get update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y python3-pandas python3-matplotlib
    echo
  fi
}

validate_ip() {
  python3 - "$1" <<'PY'
import ipaddress
import sys

try:
    ipaddress.ip_address(sys.argv[1])
except ValueError:
    raise SystemExit(1)
PY
}

prompt_config() {
  local input

  read -r -p "Enter total test duration in seconds [${TOTAL_DURATION}]: " input
  if [[ -n "${input}" ]]; then
    TOTAL_DURATION="${input}"
  fi

  read -r -p "Enter interval between tests in seconds [${INTERVAL_SECONDS}]: " input
  if [[ -n "${input}" ]]; then
    INTERVAL_SECONDS="${input}"
  fi

  read -r -p "Enter iperf test duration per cycle (seconds) [${IPERF_TEST_DURATION}]: " input
  if [[ -n "${input}" ]]; then
    IPERF_TEST_DURATION="${input}"
  fi

  read -r -p "HTTP target [http://192.168.xx.x or https://example.com]: " input
  if [[ -n "${input}" ]]; then
    HTTP_TARGET="${input}"
  fi

  if [[ "${HTTP_TARGET}" != http://* && "${HTTP_TARGET}" != https://* ]]; then
    HTTP_TARGET="http://${HTTP_TARGET}"
  fi

  if ! [[ "${TOTAL_DURATION}" =~ ^[0-9]+$ && "${INTERVAL_SECONDS}" =~ ^[0-9]+$ && "${IPERF_TEST_DURATION}" =~ ^[0-9]+$ ]]; then
    echo "ERROR: duration, interval, and iperf duration must be integers." >&2
    exit 1
  fi

  if [[ "${TOTAL_DURATION}" -le 0 || "${INTERVAL_SECONDS}" -lt 0 || "${IPERF_TEST_DURATION}" -le 0 ]]; then
    echo "ERROR: duration values are invalid." >&2
    exit 1
  fi

  echo
  echo "Enter IP addresses for each test type:"
  read -r -p "Ping target IP: " PING_TARGET
  read -r -p "IPv4 iperf server IP: " IPERF_IPV4
  read -r -p "iperf server username: " SERVER_USER
  read -r -s -p "iperf server password: " SERVER_PASS
  echo

  if ! validate_ip "${PING_TARGET}"; then
    echo "ERROR: invalid Ping target IP: ${PING_TARGET}" >&2
    exit 1
  fi

  if ! validate_ip "${IPERF_IPV4}"; then
    echo "ERROR: invalid IPv4 iperf server IP: ${IPERF_IPV4}" >&2
    exit 1
  fi

  if [[ -z "${SERVER_USER}" || -z "${SERVER_PASS}" ]]; then
    echo "ERROR: iperf server username and password are required." >&2
    exit 1
  fi
}

ssh_server() {
  SSHPASS="${SERVER_PASS}" sshpass -e ssh \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
    -o ConnectTimeout=10 \
    "${SERVER_USER}@${IPERF_IPV4}" "$@"
}

prepare_iperf_server() {
  echo "=== iperf3 server setup ==="
  ssh_server "if command -v iperf3 >/dev/null 2>&1; then echo 'Server iperf3 is already installed; skipping server install.'; else echo 'Installing iperf3 on server...'; echo '${SERVER_PASS}' | sudo -S apt-get update && echo '${SERVER_PASS}' | sudo -S env DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3; fi"
  ssh_server "if ! pgrep -x iperf3 >/dev/null 2>&1; then nohup iperf3 -s > '${SERVER_LOG}' 2>&1 < /dev/null & fi"
  sleep 2
  ssh_server "pgrep -x -a iperf3 || { echo 'ERROR: iperf3 server did not start' >&2; exit 1; }"
  echo "Server iperf3 is running on ${IPERF_IPV4}."
  echo "Server log: ${SERVER_USER}@${IPERF_IPV4}:${SERVER_LOG}"
  echo
}

mark_status() {
  local test_type="$1"
  local result="$2"

  case "${test_type}" in
    Ping)
      if [[ "${result}" == Error:* ]]; then
        echo "Failed"
      elif [[ "${result}" =~ ^([0-9]+([.][0-9]+)?)[[:space:]]ms$ ]]; then
        awk -v v="${BASH_REMATCH[1]}" 'BEGIN { print (v > 100 ? "Failed" : "Success") }'
      else
        echo "Success"
      fi
      ;;
    "HTTP Request")
      if [[ "${result}" == Status\ 200* ]]; then
        echo "Success"
      else
        echo "Failed"
      fi
      ;;
    *)
      if [[ "${result}" == Error:* || "${result}" == *"No bandwidth"* ]]; then
        echo "Failed"
      else
        echo "Success"
      fi
      ;;
  esac
}

csv_escape() {
  local value="${1//\"/\"\"}"
  printf '"%s"' "${value}"
}

append_result() {
  local file="$1"
  local cycle="$2"
  local test_name="$3"
  local target="$4"
  local result="$5"
  local status="$6"

  {
    printf '%s,' "${cycle}"
    csv_escape "${test_name}"
    printf ','
    csv_escape "${target}"
    printf ','
    csv_escape "${result}"
    printf ','
    csv_escape "${status}"
    printf '\n'
  } >>"${file}"
}

ping_test() {
  local host="$1"
  local output result status

  if output="$(LANG=C ping -c 4 "${host}" 2>&1)"; then
    result="$(python3 - "${output}" <<'PY'
import re
import sys

text = sys.argv[1]
match = re.search(r"rtt min/avg/max/(?:mdev|stddev) = [\d.]+/([\d.]+)/", text)
if match:
    print(f"{float(match.group(1)):.2f} ms")
else:
    print("Error: avg latency not found")
PY
)"
  else
    result="Error: ${output##*$'\n'}"
  fi

  status="$(mark_status "Ping" "${result}")"
  append_result "${CYCLE_CSV}" "${CYCLE}" "Ping" "${host}" "${result}" "${status}"
}

http_test() {
  local url="$1"
  local code result status

  if code="$(curl -L -s -o /dev/null -w '%{http_code}' --max-time 5 "${url}" 2>/dev/null)"; then
    result="Status ${code}"
  else
    result="Error: curl request failed"
  fi

  status="$(mark_status "HTTP Request" "${result}")"
  append_result "${CYCLE_CSV}" "${CYCLE}" "HTTP Request" "${url}" "${result}" "${status}"
}

iperf_test() {
  local protocol="$1"
  local server="$2"
  local output result status
  local cmd=(iperf3 -c "${server}" -t "${IPERF_TEST_DURATION}" -4)

  if [[ "${protocol}" == "UDP" ]]; then
    cmd+=(-u -b 10M)
  fi

  if output="$("${cmd[@]}" 2>&1)"; then
    result="$(python3 - "${output}" <<'PY'
import sys

text = sys.argv[1]
result = "No bandwidth result found"
for line in text.splitlines():
    if "sender" in line and "bits/sec" in line:
        result = " ".join(line.split()[-4:])
        break
print(result)
PY
)"
  else
    result="Error: ${output##*$'\n'}"
  fi

  status="$(mark_status "${protocol} iperf" "${result}")"
  append_result "${CYCLE_CSV}" "${CYCLE}" "${protocol} over IPv4" "${server}" "${result}" "${status}"
}

plot_cycle_report() {
  local csv_file="$1"
  local png_file="$2"
  local cycle="$3"
  local timestamp="$4"

  python3 - "${csv_file}" "${png_file}" "${cycle}" "${timestamp}" <<'PY'
import sys
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

csv_file, png_file, cycle, timestamp = sys.argv[1:5]
df = pd.read_csv(csv_file)

status_counts = df.groupby(["Test", "Status"]).size().unstack(fill_value=0)
status_order = ["Success", "Failed"]
color_map = {"Success": "skyblue", "Failed": "salmon"}
for status in status_order:
    if status not in status_counts.columns:
        status_counts[status] = 0
status_counts = status_counts[status_order]
color_list = [color_map[status] for status in status_counts.columns]

status_counts.plot(kind="bar", stacked=True, color=color_list, figsize=(10, 6))
plt.title(f"Cycle {cycle} Summary ({timestamp}) - {len(df)} tests", fontsize=14)
plt.xlabel("Test Type", fontsize=12)
plt.ylabel("Number of Results", fontsize=12)
plt.xticks(rotation=45, ha="right")
plt.legend(title="Status")
plt.grid(axis="y", linestyle="--", alpha=0.7)
plt.tight_layout()
plt.savefig(png_file)
plt.close()
PY
}

plot_final_report() {
  python3 - <<'PY'
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

final_df = pd.read_csv("final_summary_report.csv")
status_counts_final = final_df.groupby(["Test", "Status"]).size().unstack(fill_value=0)

status_order = ["Success", "Failed"]
color_map = {"Success": "orange", "Failed": "red"}
for status in status_order:
    if status not in status_counts_final.columns:
        status_counts_final[status] = 0
status_counts_final = status_counts_final[status_order]
color_list_final = [color_map[status] for status in status_counts_final.columns]

status_counts_final.plot(kind="bar", stacked=True, color=color_list_final, figsize=(10, 6))
total_tests = len(final_df)
plt.title(f"Final Summary - {total_tests} total tests", fontsize=14)
plt.xlabel("Test Type", fontsize=12)
plt.ylabel("Total Results", fontsize=12)
plt.xticks(rotation=45, ha="right")
plt.legend(title="Status")
plt.grid(axis="y", linestyle="--", alpha=0.7)
plt.tight_layout()
plt.savefig("final_summary_report.png")
plt.close()
PY
}

run_cycle() {
  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"
  CYCLE_CSV="test_cycle_${CYCLE}_${timestamp}.csv"
  local cycle_png="test_cycle_${CYCLE}_${timestamp}.png"

  printf 'Cycle,Test,Target,Result,Status\n' >"${CYCLE_CSV}"

  ping_test "${PING_TARGET}"
  http_test "${HTTP_TARGET}"
  iperf_test "TCP" "${IPERF_IPV4}"
  iperf_test "UDP" "${IPERF_IPV4}"

  plot_cycle_report "${CYCLE_CSV}" "${cycle_png}" "${CYCLE}" "${timestamp}"

  if [[ ! -f final_summary_report.csv ]]; then
    cp "${CYCLE_CSV}" final_summary_report.csv
  else
    tail -n +2 "${CYCLE_CSV}" >> final_summary_report.csv
  fi

  echo "Cycle ${CYCLE} completed. Reports saved:"
  echo "- ${CYCLE_CSV}"
  echo "- ${cycle_png}"
}

install_requirements
prompt_config
mkdir -p "${LOG_DIR}"
prepare_iperf_server
cd "${LOG_DIR}"

START_TIME="$(date +%s)"
CYCLE=1
rm -f final_summary_report.csv final_summary_report.png

echo
echo "Starting network reliability tests for ${TOTAL_DURATION} seconds..."
echo

while true; do
  NOW="$(date +%s)"
  if [[ $((NOW - START_TIME)) -ge "${TOTAL_DURATION}" ]]; then
    break
  fi

  run_cycle

  NOW="$(date +%s)"
  if [[ $((NOW - START_TIME + INTERVAL_SECONDS)) -ge "${TOTAL_DURATION}" ]]; then
    break
  fi

  echo
  echo "--- Waiting for ${INTERVAL_SECONDS} seconds before next cycle ---"
  echo
  sleep "${INTERVAL_SECONDS}"
  CYCLE=$((CYCLE + 1))
done

if [[ ! -f final_summary_report.csv ]]; then
  echo "No tests were run. Exiting."
  exit 1
fi

plot_final_report

echo
echo "All tests completed."
echo "Final reports generated:"
echo "- final_summary_report.csv"
echo "- final_summary_report.png"
