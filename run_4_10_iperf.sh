#!/usr/bin/env bash
set -euo pipefail

TEST_DURATION="${TEST_DURATION:-90}"
INTERVAL="${INTERVAL:-5}"
SERVER_LOG="${SERVER_LOG:-/tmp/iperf_4_10_server.log}"

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
  ssh_server "if ! pgrep -x iperf >/dev/null 2>&1; then nohup iperf -s > '${SERVER_LOG}' 2>&1 < /dev/null & fi"
  sleep 2
  ssh_server "pgrep -x -a iperf || { echo 'ERROR: iperf server did not start' >&2; exit 1; }"
  echo "Server iperf is running on ${SERVER_IP}."
  echo
}

run_client_test() {
  echo "=== Client test ==="
  echo "Command: iperf -c ${SERVER_IP} -t ${TEST_DURATION} -i ${INTERVAL} -r"
  echo
  iperf -c "${SERVER_IP}" -t "${TEST_DURATION}" -i "${INTERVAL}" -r
}

echo "4.10 Ethernet iperf test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Kernel: $(uname -r)"
echo

install_local_tools
prompt_server_info
prepare_server
run_client_test

echo
echo "Summary"
echo "-------"
echo "Review the iperf client output above for bandwidth results."
echo "Server log: ${SERVER_USER}@${SERVER_IP}:${SERVER_LOG}"
