#!/usr/bin/env bash
set -e

if ! command -v sysbench >/dev/null 2>&1; then
  echo "sysbench is not installed."
  echo "Installing sysbench..."
  sudo apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y sysbench
fi

if ! command -v sysbench >/dev/null 2>&1; then
  echo "ERROR: sysbench installation failed." >&2
  exit 1
fi

echo "sysbench: $(command -v sysbench)"
echo

echo "======================================"
echo "7.2 Memory Test - Read"
echo "Command: sysbench --test=memory --memory-block-size=1K --memory-scope=global --memory-total-size=4G --memory-oper=read run"
echo "======================================"
READ_OUTPUT="$(sysbench --test=memory \
  --memory-block-size=1K \
  --memory-scope=global \
  --memory-total-size=4G \
  --memory-oper=read \
  run 2>&1)"
printf '%s\n' "${READ_OUTPUT}"

READ_MIB_S="$(printf '%s\n' "${READ_OUTPUT}" |
  awk -F'[()]' '/transferred/ {value=$2; sub(/ MiB\/sec/, "", value); print value; exit}')"
READ_GB_S="$(awk -v value="${READ_MIB_S:-0}" 'BEGIN { printf "%.2f", value * 1048576 / 1000000000 }')"

echo
echo "======================================"
echo "7.2 Memory Test - Write"
echo "Command: sysbench --test=memory --memory-block-size=1K --memory-scope=global --memory-total-size=4G --memory-oper=write run"
echo "======================================"
WRITE_OUTPUT="$(sysbench --test=memory \
  --memory-block-size=1K \
  --memory-scope=global \
  --memory-total-size=4G \
  --memory-oper=write \
  run 2>&1)"
printf '%s\n' "${WRITE_OUTPUT}"

WRITE_MIB_S="$(printf '%s\n' "${WRITE_OUTPUT}" |
  awk -F'[()]' '/transferred/ {value=$2; sub(/ MiB\/sec/, "", value); print value; exit}')"
WRITE_GB_S="$(awk -v value="${WRITE_MIB_S:-0}" 'BEGIN { printf "%.2f", value * 1048576 / 1000000000 }')"

echo
echo "======================================"
echo "7.2 Memory Test Result"
echo "Read:  ${READ_GB_S} GB/s"
echo "Write: ${WRITE_GB_S} GB/s"
echo "======================================"
