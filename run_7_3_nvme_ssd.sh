#!/usr/bin/env bash
set -e

TEST_FILE="test.bin"

if [[ -t 1 ]]; then
  GREEN=$'\033[1;32m'
  RED=$'\033[1;31m'
  RESET=$'\033[0m'
else
  GREEN=""
  RED=""
  RESET=""
fi

install_required_tools() {
  local packages=()

  command -v dd >/dev/null 2>&1 || packages+=("coreutils")
  command -v sync >/dev/null 2>&1 || packages+=("coreutils")
  command -v sysctl >/dev/null 2>&1 || packages+=("procps")

  if [[ "${#packages[@]}" -gt 0 ]]; then
    echo "Installing required packages: ${packages[*]}"
    sudo apt-get update
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
  fi

  for command_name in dd sync sysctl; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      echo "ERROR: Required command not found: ${command_name}" >&2
      exit 1
    fi
  done
}

extract_dd_speed() {
  awk -F, '
    /copied/ {
      speed=$NF
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", speed)
      print speed
    }
  ' | tail -n 1
}

cleanup() {
  rm -f -- "${TEST_FILE}"
}

trap cleanup EXIT INT TERM

install_required_tools

echo "======================================"
echo "7.3 NVMe SSD - Write Test"
echo "Command: sudo dd if=/dev/zero of=${TEST_FILE} bs=512k count=2048"
echo "======================================"
WRITE_OUTPUT="$(sudo dd if=/dev/zero of="${TEST_FILE}" bs=512k count=2048 conv=fsync 2>&1)"
printf '%s\n' "${WRITE_OUTPUT}"
WRITE_SPEED="$(printf '%s\n' "${WRITE_OUTPUT}" | extract_dd_speed)"

echo
echo "======================================"
echo "7.3 NVMe SSD - Clear Cache"
echo "Command: sudo /sbin/sysctl -w vm.drop_caches=3"
echo "======================================"
sync
sudo /sbin/sysctl -w vm.drop_caches=3

echo
echo "======================================"
echo "7.3 NVMe SSD - Read Test"
echo "Command: sudo dd if=${TEST_FILE} of=/dev/null bs=512k count=2048"
echo "======================================"
READ_OUTPUT="$(sudo dd if="${TEST_FILE}" of=/dev/null bs=512k count=2048 2>&1)"
printf '%s\n' "${READ_OUTPUT}"
READ_SPEED="$(printf '%s\n' "${READ_OUTPUT}" | extract_dd_speed)"

echo
printf '%s' "${GREEN}"
echo "======================================"
echo "7.3 NVMe SSD Test Result"
echo "Write: ${WRITE_SPEED}"
echo "Read:  ${READ_SPEED}"
echo "======================================"
printf '%s' "${RESET}"

rm -f -- "${TEST_FILE}"
trap - EXIT INT TERM
