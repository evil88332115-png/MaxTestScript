#!/usr/bin/env bash
set -e

TEST_FILE="test.bin"

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

format_speed() {
  local bytes="$1"
  local seconds="$2"

  awk -v bytes="${bytes}" -v seconds="${seconds}" 'BEGIN {
    if (seconds <= 0) {
      print "unknown"
      exit
    }

    mbps = bytes / seconds / 1000000
    if (mbps >= 1000)
      printf "%.2f GB/s", mbps / 1000
    else
      printf "%.2f MB/s", mbps
  }'
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
WRITE_START="$(date +%s.%N)"
WRITE_OUTPUT="$(sudo dd if=/dev/zero of="${TEST_FILE}" bs=512k count=2048 conv=fsync 2>&1)"
WRITE_END="$(date +%s.%N)"
printf '%s\n' "${WRITE_OUTPUT}"
WRITE_SECONDS="$(awk -v start="${WRITE_START}" -v end="${WRITE_END}" 'BEGIN { print end - start }')"
WRITE_SPEED="$(format_speed 1073741824 "${WRITE_SECONDS}")"

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
READ_START="$(date +%s.%N)"
READ_OUTPUT="$(sudo dd if="${TEST_FILE}" of=/dev/null bs=512k count=2048 2>&1)"
READ_END="$(date +%s.%N)"
printf '%s\n' "${READ_OUTPUT}"
READ_SECONDS="$(awk -v start="${READ_START}" -v end="${READ_END}" 'BEGIN { print end - start }')"
READ_SPEED="$(format_speed 1073741824 "${READ_SECONDS}")"

echo
echo "======================================"
echo "7.3 NVMe SSD Test Result"
echo "Write: ${WRITE_SPEED}"
echo "Read:  ${READ_SPEED}"
echo "======================================"

rm -f -- "${TEST_FILE}"
trap - EXIT INT TERM
