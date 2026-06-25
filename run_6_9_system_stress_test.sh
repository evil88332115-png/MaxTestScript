#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 6-9 System Stress Test
#
# Installs requirements only when this script runs:
#   mesa-utils glmark2 memtester bonnie++
#
# Menu:
#   1. glmark2 -s 3840x2160 --run-forever
#   2. glxgears -fullscreen for 1 hour
#   3. glxgears -fullscreen forever
#   4. memtester 500M 100
#   5. bonnie++ -m <user> -u <user>, export CSV and HTML
# ============================================================

export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-${HOME}/.Xauthority}"

TEST_USER="${TEST_USER:-$(id -un)}"
LOG_DIR="${LOG_DIR:-${HOME}/6-9_system_stress_$(date +%Y%m%d_%H%M%S)}"
GLMARK_RESOLUTION="${GLMARK_RESOLUTION:-3840x2160}"
GLXGEARS_DURATION="${GLXGEARS_DURATION:-1h}"
MEMTESTER_SIZE="${MEMTESTER_SIZE:-500M}"
MEMTESTER_LOOPS="${MEMTESTER_LOOPS:-100}"
DD_STRESS_DURATION="${DD_STRESS_DURATION:-1h}"
DD_STRESS_BS="${DD_STRESS_BS:-1M}"

PACKAGES=(
  mesa-utils
  glmark2
  memtester
  bonnie++
)

if [ -t 1 ]; then
  RED="\033[31m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  NC="\033[0m"
else
  RED=""
  GREEN=""
  YELLOW=""
  NC=""
fi

pass() { echo -e "${GREEN}$*${NC}"; }
fail() { echo -e "${RED}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }

install_requirements() {
  local missing=()
  local package

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: apt-get not found. This script supports Ubuntu/Debian only." >&2
    exit 1
  fi

  for package in "${PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
      missing+=("$package")
    fi
  done

  if [ "${#missing[@]}" -eq 0 ]; then
    echo "Required packages already installed; skipping apt-get update/install."
    return 0
  fi

  echo "Installing missing package(s): ${missing[*]}"
  sudo apt-get update
  sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    return 1
  fi
}

print_command() {
  echo ""
  echo "Command:"
  printf '  '
  printf '%q ' "$@"
  echo ""
  echo ""
}

run_glmark2_forever() {
  local log_file="${LOG_DIR}/glmark2_${GLMARK_RESOLUTION}_run_forever.log"
  mkdir -p "$LOG_DIR"

  echo ""
  echo "======================================"
  echo "glmark2 ${GLMARK_RESOLUTION} run forever"
  echo "Log: $log_file"
  echo "Press Ctrl+C to stop."
  echo "======================================"

  require_cmd glmark2 || return 1
  print_command glmark2 -s "$GLMARK_RESOLUTION" --run-forever
  set +e
  glmark2 -s "$GLMARK_RESOLUTION" --run-forever 2>&1 | tee "$log_file"
  rc=${PIPESTATUS[0]}
  set -e

  if [ "$rc" -eq 130 ]; then
    pass "RESULT,SYSTEM_STRESS,GLMARK2_RUN_FOREVER,STOPPED_BY_CTRL_C"
  elif [ "$rc" -eq 0 ]; then
    pass "RESULT,SYSTEM_STRESS,GLMARK2_RUN_FOREVER,PASS"
  else
    fail "RESULT,SYSTEM_STRESS,GLMARK2_RUN_FOREVER,FAIL,rc=${rc}"
  fi
}

run_glxgears_1h() {
  local log_file="${LOG_DIR}/glxgears_fullscreen_${GLXGEARS_DURATION}.log"
  mkdir -p "$LOG_DIR"

  echo ""
  echo "======================================"
  echo "glxgears fullscreen ${GLXGEARS_DURATION}"
  echo "Log: $log_file"
  echo "======================================"

  require_cmd glxgears || return 1
  require_cmd timeout || return 1
  print_command timeout "$GLXGEARS_DURATION" glxgears -fullscreen
  set +e
  timeout "$GLXGEARS_DURATION" glxgears -fullscreen 2>&1 | tee "$log_file"
  rc=${PIPESTATUS[0]}
  set -e

  if [ "$rc" -eq 124 ]; then
    pass "RESULT,SYSTEM_STRESS,GLXGEARS_FULLSCREEN_${GLXGEARS_DURATION},PASS,time-complete"
  elif [ "$rc" -eq 0 ]; then
    pass "RESULT,SYSTEM_STRESS,GLXGEARS_FULLSCREEN_${GLXGEARS_DURATION},PASS"
  else
    fail "RESULT,SYSTEM_STRESS,GLXGEARS_FULLSCREEN_${GLXGEARS_DURATION},FAIL,rc=${rc}"
  fi
}

run_glxgears_forever() {
  local log_file="${LOG_DIR}/glxgears_fullscreen_forever.log"
  mkdir -p "$LOG_DIR"

  echo ""
  echo "======================================"
  echo "glxgears fullscreen forever"
  echo "Log: $log_file"
  echo "Press Ctrl+C to stop."
  echo "======================================"

  require_cmd glxgears || return 1
  print_command glxgears -fullscreen
  set +e
  glxgears -fullscreen 2>&1 | tee "$log_file"
  rc=${PIPESTATUS[0]}
  set -e

  if [ "$rc" -eq 130 ]; then
    pass "RESULT,SYSTEM_STRESS,GLXGEARS_FULLSCREEN_FOREVER,STOPPED_BY_CTRL_C"
  elif [ "$rc" -eq 0 ]; then
    pass "RESULT,SYSTEM_STRESS,GLXGEARS_FULLSCREEN_FOREVER,PASS"
  else
    fail "RESULT,SYSTEM_STRESS,GLXGEARS_FULLSCREEN_FOREVER,FAIL,rc=${rc}"
  fi
}

run_memtester() {
  local log_file="${LOG_DIR}/memtester_${MEMTESTER_SIZE}_${MEMTESTER_LOOPS}.log"
  mkdir -p "$LOG_DIR"

  echo ""
  echo "======================================"
  echo "memtester ${MEMTESTER_SIZE} ${MEMTESTER_LOOPS}"
  echo "Log: $log_file"
  echo "======================================"

  require_cmd memtester || return 1
  print_command memtester "$MEMTESTER_SIZE" "$MEMTESTER_LOOPS"
  set +e
  memtester "$MEMTESTER_SIZE" "$MEMTESTER_LOOPS" 2>&1 | tee "$log_file"
  rc=${PIPESTATUS[0]}
  set -e

  if [ "$rc" -eq 0 ]; then
    pass "RESULT,SYSTEM_STRESS,MEMTESTER,PASS,size=${MEMTESTER_SIZE},loops=${MEMTESTER_LOOPS}"
  else
    fail "RESULT,SYSTEM_STRESS,MEMTESTER,FAIL,rc=${rc},size=${MEMTESTER_SIZE},loops=${MEMTESTER_LOOPS}"
  fi
}

run_bonnie() {
  local bonnie_dir="${LOG_DIR}/bonnie_work"
  local raw_log="${LOG_DIR}/bonnie_raw.log"
  local csv_file="${LOG_DIR}/bonnie_result.csv"
  local html_file="${LOG_DIR}/test.html"
  local rc

  mkdir -p "$LOG_DIR" "$bonnie_dir"

  echo ""
  echo "======================================"
  echo "bonnie++"
  echo "User: $TEST_USER"
  echo "Work directory: $bonnie_dir"
  echo "Raw log: $raw_log"
  echo "CSV: $csv_file"
  echo "HTML: $html_file"
  echo "======================================"

  require_cmd bonnie++ || return 1
  require_cmd bon_csv2html || return 1

  print_command bonnie++ -d "$bonnie_dir" -m "$TEST_USER" -u "$TEST_USER"
  set +e
  bonnie++ -d "$bonnie_dir" -m "$TEST_USER" -u "$TEST_USER" 2>&1 | tee "$raw_log"
  rc=${PIPESTATUS[0]}
  set -e

  # bonnie++ prints human-readable output plus one CSV line:
  # 1.98,2.00,<name>,...
  grep -E '^[0-9]+([.][0-9]+)?,[0-9]+([.][0-9]+)?,' "$raw_log" | tail -n 1 > "$csv_file" || true

  if [ -s "$csv_file" ]; then
    bon_csv2html < "$csv_file" > "$html_file"
    echo "HTML report: $html_file"
    pass "RESULT,SYSTEM_STRESS,BONNIE_HTML,PASS,$html_file"
  else
    warn "WARNING: Could not extract bonnie++ CSV line."
    fail "RESULT,SYSTEM_STRESS,BONNIE_HTML,FAIL,csv-not-found"
  fi

  if [ "$rc" -eq 0 ]; then
    pass "RESULT,SYSTEM_STRESS,BONNIE,PASS"
  else
    fail "RESULT,SYSTEM_STRESS,BONNIE,FAIL,rc=${rc}"
  fi
}

detect_online_cpu_count() {
  if command -v nproc >/dev/null 2>&1; then
    nproc
    return 0
  fi

  if [ -r /sys/devices/system/cpu/online ]; then
    python3 - <<'PY'
from pathlib import Path

text = Path("/sys/devices/system/cpu/online").read_text().strip()
count = 0
for part in text.split(","):
    if "-" in part:
        start, end = map(int, part.split("-", 1))
        count += end - start + 1
    elif part:
        count += 1
print(count if count > 0 else 1)
PY
    return 0
  fi

  grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1
}

run_cpu_emmc_stress() {
  local cores log_file i rc
  local pids=()

  cores="$(detect_online_cpu_count)"
  mkdir -p "$LOG_DIR"
  log_file="${LOG_DIR}/cpu_emmc_dd_stress_${DD_STRESS_DURATION}.log"

  echo ""
  echo "======================================"
  echo "CPU eMMC Stress (${DD_STRESS_DURATION})"
  echo "Online CPU cores detected: ${cores}"
  echo "DD block size: ${DD_STRESS_BS}"
  echo "Log: $log_file"
  echo "======================================"
  echo "This runs one dd worker per online CPU core:"
  echo "  timeout ${DD_STRESS_DURATION} dd if=/dev/zero of=/dev/null bs=${DD_STRESS_BS} status=none"
  echo "Note: /dev/zero -> /dev/null stresses CPU/kernel path, not real eMMC writes."
  echo ""

  {
    echo "CPU eMMC Stress"
    echo "Date: $(date -Iseconds)"
    echo "Online CPU cores detected: ${cores}"
    echo "Duration: ${DD_STRESS_DURATION}"
    echo "Block size: ${DD_STRESS_BS}"
  } > "$log_file"

  for i in $(seq 1 "$cores"); do
    echo "Starting worker ${i}/${cores}" | tee -a "$log_file"
    timeout "$DD_STRESS_DURATION" dd if=/dev/zero of=/dev/null "bs=${DD_STRESS_BS}" status=none >> "$log_file" 2>&1 &
    pids+=("$!")
  done

  rc=0
  for pid in "${pids[@]}"; do
    set +e
    wait "$pid"
    worker_rc=$?
    set -e
    # timeout returns 124 when duration is reached; that is expected.
    if [ "$worker_rc" -ne 0 ] && [ "$worker_rc" -ne 124 ]; then
      rc="$worker_rc"
    fi
  done

  echo "Finished: $(date -Iseconds)" >> "$log_file"

  if [ "$rc" -eq 0 ]; then
    pass "RESULT,SYSTEM_STRESS,CPU_EMMC_DD_STRESS,PASS,cores=${cores},duration=${DD_STRESS_DURATION}"
  else
    fail "RESULT,SYSTEM_STRESS,CPU_EMMC_DD_STRESS,FAIL,rc=${rc},cores=${cores},duration=${DD_STRESS_DURATION}"
  fi
}

show_menu() {
  echo ""
  echo "======================================"
  echo "6-9 System Stress Test"
  echo "Log directory: $LOG_DIR"
  echo "======================================"
  echo "1) glmark2 -s 3840x2160 --run-forever"
  echo "2) glxgears -fullscreen (${GLXGEARS_DURATION})"
  echo "3) glxgears -fullscreen (forever)"
  echo "4) memtester ${MEMTESTER_SIZE} ${MEMTESTER_LOOPS}"
  echo "5) bonnie++ -m ${TEST_USER} -u ${TEST_USER}"
  echo "6) CPU eMMC Stress (${DD_STRESS_DURATION})"
  echo "q) Quit"
  echo "======================================"
}

echo "======================================"
echo "6-9 System Stress Test"
echo "Host: $(hostname)"
echo "Date: $(date -Iseconds)"
echo "DISPLAY: $DISPLAY"
echo "XAUTHORITY: $XAUTHORITY"
echo "Test user: $TEST_USER"
echo "Log directory: $LOG_DIR"
echo "======================================"

install_requirements
mkdir -p "$LOG_DIR"

while true; do
  show_menu
  read -r -p "Select: " choice
  case "$choice" in
    1) run_glmark2_forever ;;
    2) run_glxgears_1h ;;
    3) run_glxgears_forever ;;
    4) run_memtester ;;
    5) run_bonnie ;;
    6) run_cpu_emmc_stress ;;
    q|Q) break ;;
    *) echo "Invalid selection: $choice" ;;
  esac
done

echo ""
echo "Done."
echo "Logs saved in: $LOG_DIR"
