#!/usr/bin/env bash
set -euo pipefail

TEST_DURATION="${TEST_DURATION:-90}"
INTERVAL="${INTERVAL:-5}"
LOG_DIR="${LOG_DIR:-${HOME}/4-11_iperf_dual_$(date +%Y%m%d_%H%M%S)}"
CLIENT_LOG="${CLIENT_LOG:-${LOG_DIR}/iperf_dual_client.log}"

if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
  BOLD=$'\033[1m'
  GREEN=$'\033[1;32m'
  YELLOW=$'\033[1;33m'
  RESET=$'\033[0m'
else
  BOLD=""
  GREEN=""
  YELLOW=""
  RESET=""
fi

declare -a IPERF_SUMMARY=()

install_local_tools() {
  local missing=()
  command -v iperf >/dev/null 2>&1 || missing+=(iperf)
  command -v sshpass >/dev/null 2>&1 || missing+=(sshpass)

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "Installing local package(s): ${missing[*]}"
    sudo apt-get update
    sudo apt-get install -y "${missing[@]}"
    echo
  else
    echo "Local iperf and sshpass are already installed; skipping local install."
    echo
  fi
}

prompt_server_info() {
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

ssh_server() {
  SSHPASS="${SERVER_PASS}" sshpass -e ssh \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
    -o ConnectTimeout=10 \
    "${SERVER_USER}@${SERVER_IP}" "$@"
}

prepare_server() {
  echo "=== Server setup ==="
  ssh_server "if command -v iperf >/dev/null 2>&1; then echo 'Server iperf is already installed; skipping server install.'; else echo 'Installing iperf on server...'; echo '${SERVER_PASS}' | sudo -S apt-get update && echo '${SERVER_PASS}' | sudo -S apt-get install -y iperf; fi"
  ssh_server "if ! pgrep -x iperf >/dev/null 2>&1; then nohup iperf -s > /dev/null 2>&1 < /dev/null & fi"
  sleep 2
  ssh_server "pgrep -x -a iperf || { echo 'ERROR: iperf server did not start' >&2; exit 1; }"
  echo "Server iperf is running on ${SERVER_IP}."
  echo
}

run_client_test() {
  local rc

  echo "=== Client test ==="
  echo "Command: iperf -c ${SERVER_IP} -t ${TEST_DURATION} -i ${INTERVAL} -d"
  echo "Log directory: ${LOG_DIR}"
  echo "Client log: ${CLIENT_LOG}"
  echo

  mkdir -p "${LOG_DIR}"
  set +e
  iperf -c "${SERVER_IP}" -t "${TEST_DURATION}" -i "${INTERVAL}" -d 2>&1 | tee "${CLIENT_LOG}"
  rc=${PIPESTATUS[0]}
  set -e
  parse_iperf_dual_summary "${CLIENT_LOG}"
  return "${rc}"
}

parse_iperf_dual_summary() {
  local log_file="$1"
  local parsed label bandwidth line

  parsed="$(awk '
    /\[[ ]*[0-9]+\] local / && / connected with / {
      id = $2
      gsub(/\]/, "", id)
      direction[id] = ($6 == "5001") ? "Receive" : "Send"
    }
    $0 ~ "\\[ *[0-9]+\\]" && $0 ~ "0\\.0000-" && $0 ~ "Bytes" && $0 ~ "bits/sec" {
      id = $2
      gsub(/\]/, "", id)
      total[id] = $0
    }
    END {
      for (id in total) {
        label = direction[id]
        if (label == "") label = "Unknown"
        print label "|" total[id]
      }
    }
  ' "${log_file}")"

  while IFS='|' read -r label line; do
    [[ -z "${label}" || -z "${line}" ]] && continue
    bandwidth="$(awk '{ print $(NF-1) " " $NF }' <<< "${line}")"
    IPERF_SUMMARY+=("${label}|${bandwidth}|${line}")
  done <<< "${parsed}"
}

print_summary() {
  local wanted result label bandwidth line found

  echo
  printf '%s========================================%s\n' "${YELLOW}" "${RESET}"
  printf '%s       ETHERNET IPERF BANDWIDTH%s\n' "${YELLOW}" "${RESET}"
  printf '%s========================================%s\n' "${YELLOW}" "${RESET}"

  if [[ "${#IPERF_SUMMARY[@]}" -eq 0 ]]; then
    echo "ERROR: Unable to parse iperf summary. Review local log: ${CLIENT_LOG}" >&2
    return 1
  fi

  for wanted in Send Receive; do
    found=0
    for result in "${IPERF_SUMMARY[@]}"; do
      IFS='|' read -r label bandwidth line <<< "${result}"
      if [[ "${label}" == "${wanted}" ]]; then
        printf '%sIPERF %-7s %12s%s\n' "${GREEN}" "${label}" "${bandwidth}" "${RESET}"
        found=1
      fi
    done
    if [[ "${found}" -eq 0 ]]; then
      printf 'IPERF %-7s %12s\n' "${wanted}" "N/A"
    fi
  done

  printf '%s========================================%s\n' "${YELLOW}" "${RESET}"
  echo "Client log: ${CLIENT_LOG}"
}

printf '%s4.11 Ethernet iperf dual test%s\n' "${BOLD}" "${RESET}"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Kernel: $(uname -r)"
echo

install_local_tools
prompt_server_info
prepare_server
run_client_test
print_summary
