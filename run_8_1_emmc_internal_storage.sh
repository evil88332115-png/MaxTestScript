#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 8-1 EMMC Internal Storage Test
#
# Original test idea:
#   Repeatedly write dmesg content into sequential text files.
#   When file count exceeds a threshold, remove old test files and continue.
#
# Safer implementation:
#   - Writes only under a dedicated test directory.
#   - Does not delete arbitrary *.txt in the current directory.
#   - If write fails, records kernel log, deletes test files, syncs, then continues.
#   - Ctrl+C stops test and records kernel log.
#   - No sudo required if TEST_DIR is under the current user's HOME.
#
# Usage:
#   ./run_8_1_emmc_internal_storage.sh
#
# Optional:
#   TEST_DIR=${HOME}/emmc_stress_test ./run_8_1_emmc_internal_storage.sh
#   CLEAN_THRESHOLD=100000 ./run_8_1_emmc_internal_storage.sh
#   SLEEP_SECONDS=1 ./run_8_1_emmc_internal_storage.sh
#   LOG_FILE=${HOME}/emmc_loop_test.log ./run_8_1_emmc_internal_storage.sh
# ============================================================

TEST_DIR="${TEST_DIR:-${HOME}/emmc_stress_test}"
FILE_PREFIX="${FILE_PREFIX:-test}"
FILE_SUFFIX="${FILE_SUFFIX:-.txt}"
CLEAN_THRESHOLD="${CLEAN_THRESHOLD:-100000}"
SLEEP_SECONDS="${SLEEP_SECONDS:-1}"
LOG_FILE="${LOG_FILE:-${HOME}/emmc_loop_test.log}"
RUNNING=true

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

require_integer() {
  local name="$1"
  local value="$2"
  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "ERROR: ${name} must be an integer: ${value}" >&2
    exit 1
  fi
}

record_kernel_log() {
  {
    echo
    echo "======================================"
    echo "8-1 EMMC Internal Storage kernel log"
    echo "Host: $(hostname)"
    echo "Date: $(date -Iseconds)"
    echo "Test directory: ${TEST_DIR}"
    echo "======================================"
    if command -v journalctl >/dev/null 2>&1; then
      journalctl -k | tail -n 200
    else
      dmesg | tail -n 200
    fi
  } >> "${LOG_FILE}" 2>/dev/null || true
}

clean_test_files() {
  echo "Removing test files under ${TEST_DIR} ..."
  find "${TEST_DIR}" -maxdepth 1 -type f -name "${FILE_PREFIX}*${FILE_SUFFIX}" -delete
  sync
}

cleanup_and_exit() {
  RUNNING=false
  echo
  echo "Stop requested. Recording kernel log..."
  record_kernel_log
  echo "Kernel log saved: ${LOG_FILE}"
  pass "RESULT,EMMC_INTERNAL_STORAGE,STOPPED"
  exit 0
}

trap cleanup_and_exit INT TERM

require_integer "CLEAN_THRESHOLD" "${CLEAN_THRESHOLD}"
require_integer "SLEEP_SECONDS" "${SLEEP_SECONDS}"

echo "======================================"
echo "8-1 EMMC Internal Storage Test"
echo "Host: $(hostname)"
echo "Date: $(date -Iseconds)"
echo "Test directory: ${TEST_DIR}"
echo "Clean threshold: ${CLEAN_THRESHOLD} files"
echo "Sleep interval: ${SLEEP_SECONDS}s"
echo "Kernel log file: ${LOG_FILE}"
echo "======================================"
echo

mkdir -p "${TEST_DIR}"

if [ -n "$(find "${TEST_DIR}" -maxdepth 1 -type f -name "${FILE_PREFIX}*${FILE_SUFFIX}" -print -quit 2>/dev/null)" ]; then
  warn "Existing test files found in ${TEST_DIR}."
  if [ -t 0 ]; then
    read -r -p "Delete existing test files before starting? [Y/n] " answer
    answer="${answer:-Y}"
    case "${answer}" in
      y|Y|yes|YES)
        find "${TEST_DIR}" -maxdepth 1 -type f -name "${FILE_PREFIX}*${FILE_SUFFIX}" -delete
        ;;
      *)
        warn "Keeping existing test files."
        ;;
    esac
  else
    warn "Non-interactive mode: keeping existing files."
  fi
fi

message="$(dmesg 2>/dev/null || true)"
if [ -z "${message}" ]; then
  message="dmesg unavailable at $(date -Iseconds)"
fi

number=0
total_written=0

echo "Starting infinite write loop. Press Ctrl+C to stop."
echo

while [ "${RUNNING}" = "true" ]; do
  sleep "${SLEEP_SECONDS}"

  if [ "${number}" -gt "${CLEAN_THRESHOLD}" ]; then
    echo "Threshold reached. Removing ${FILE_PREFIX}*${FILE_SUFFIX} under ${TEST_DIR} ..."
    record_kernel_log
    clean_test_files
    number=0
    printf 'RESULT,EMMC_INTERNAL_STORAGE,CLEAN,PASS,total_written=%s\n' "${total_written}"
  fi

  name="${TEST_DIR}/${FILE_PREFIX}${number}${FILE_SUFFIX}"
  echo "write value to ${name}"

  set +e
  printf '%s\n' "${message}" > "${name}"
  write_rc=$?
  set -e

  if [ "${write_rc}" -ne 0 ]; then
    echo "Write failed with rc=${write_rc}. Recording kernel log and cleaning test files."
    printf 'RESULT,EMMC_INTERNAL_STORAGE,WRITE_FAIL,rc=%s,total_written=%s,current_index=%s\n' "${write_rc}" "${total_written}" "${number}"
    record_kernel_log
    clean_test_files
    number=0
    continue
  fi

  number=$((number + 1))
  total_written=$((total_written + 1))

  if [ $((total_written % 100)) -eq 0 ]; then
    printf 'RESULT,EMMC_INTERNAL_STORAGE,WRITE_PROGRESS,total_written=%s,current_index=%s\n' "${total_written}" "${number}"
  fi
done

record_kernel_log
pass "RESULT,EMMC_INTERNAL_STORAGE,COMPLETE,total_written=${total_written}"
