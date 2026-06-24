#!/usr/bin/env bash
set -euo pipefail

TEST_FILE="${TEST_FILE:-/test.bin}"
BLOCK_SIZE="${BLOCK_SIZE:-1024K}"
COUNT="${COUNT:-1024}"

extract_rate() {
  awk -F, '/copied/ {
    rate=$NF
    sub(/^[[:space:]]+/, "", rate)
    print rate
  }'
}

run_dd() {
  local label="$1"
  shift
  local output rate

  echo "=== ${label} ==="
  output="$("$@" 2>&1)"
  echo "${output}"
  rate="$(printf '%s\n' "${output}" | extract_rate)"
  if [[ -n "${rate}" ]]; then
    printf 'RESULT,%s,%s\n' "${label}" "${rate}"
  else
    printf 'RESULT,%s,Unable to parse rate\n' "${label}"
  fi
  echo
}

echo "4.8 NVMe SSD dd test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Kernel: $(uname -r)"
echo "Test file: ${TEST_FILE}"
echo "Block size: ${BLOCK_SIZE}"
echo "Count: ${COUNT}"
echo

echo "=== NVMe detection ==="
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,MODEL
echo
if command -v nvme >/dev/null 2>&1; then
  nvme list || true
else
  echo "nvme command not found; skipping nvme list"
fi
echo

echo "=== Filesystem usage ==="
df -hT /
mount | grep ' on / ' || true
echo

echo "This test writes ${TEST_FILE}. Existing file at that path will be overwritten."
echo

run_dd "Write" sudo dd if=/dev/zero "of=${TEST_FILE}" "bs=${BLOCK_SIZE}" "count=${COUNT}" conv=fsync

echo "=== Drop caches ==="
sudo /sbin/sysctl -w vm.drop_caches=3
echo

run_dd "Read" sudo dd "if=${TEST_FILE}" of=/dev/null "bs=${BLOCK_SIZE}"

echo "Summary"
echo "-------"
echo "Review the RESULT lines for write/read throughput."
