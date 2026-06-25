#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 6-7 Maximum Storage Utilization Test
#
# Purpose:
#   Check root filesystem capacity and fill it with 1GB dd files
#   while leaving about 100MB free so the system can still shutdown/reboot.
#
# Default:
#   Target filesystem : /
#   Reserve space     : 100MB
#   Test directory    : ${HOME}/maximum_storage_utilization_test
#
# Usage:
#   ./run_6_7_maximum_storage_utilization_test.sh
#
# Optional:
#   RESERVE_MB=200 ./run_6_7_maximum_storage_utilization_test.sh
#   TARGET_DIR=/ ./run_6_7_maximum_storage_utilization_test.sh
#   TEST_DIR=${HOME}/maximum_storage_utilization_test ./run_6_7_maximum_storage_utilization_test.sh
#   AUTO_CONFIRM=true ./run_6_7_maximum_storage_utilization_test.sh
#   CLEAN_ONLY=true ./run_6_7_maximum_storage_utilization_test.sh
# ============================================================

TARGET_DIR="${TARGET_DIR:-/}"
RESERVE_MB="${RESERVE_MB:-100}"
TEST_DIR="${TEST_DIR:-${HOME}/maximum_storage_utilization_test}"
LEGACY_TEST_FILES=(
  "/maximum_storage_utilization_test.bin"
  "${HOME}/maximum_storage_utilization_test.bin"
)
AUTO_CONFIRM="${AUTO_CONFIRM:-false}"
CLEAN_ONLY="${CLEAN_ONLY:-false}"
DD_BS="${DD_BS:-1M}"
CHUNK_MB="${CHUNK_MB:-1024}"

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

confirm_or_exit() {
  local prompt="$1"
  local answer

  if [ "$AUTO_CONFIRM" = "true" ]; then
    echo "${prompt} YES"
    return 0
  fi

  if [ ! -t 0 ]; then
    echo "ERROR: non-interactive shell. Set AUTO_CONFIRM=true to continue." >&2
    exit 1
  fi

  read -r -p "${prompt} " answer
  if [ "$answer" != "YES" ]; then
    echo "Canceled."
    exit 0
  fi
}

enter_to_continue_or_cancel() {
  local prompt="$1"
  local answer

  if [ "$AUTO_CONFIRM" = "true" ]; then
    echo "${prompt}"
    return 0
  fi

  if [ ! -t 0 ]; then
    echo "ERROR: non-interactive shell. Set AUTO_CONFIRM=true to continue." >&2
    exit 1
  fi

  read -r -p "${prompt} " answer
  case "$answer" in
    n|N|no|NO)
      echo "Canceled."
      exit 0
      ;;
    *)
      return 0
      ;;
  esac
}

df_root_info() {
  df -Pm "$TARGET_DIR" | awk 'NR == 2 {
    printf "%s %s %s %s %s %s\n", $1, $2, $3, $4, $5, $6
  }'
}

print_root_info() {
  local fs total used avail usep mountp
  read -r fs total used avail usep mountp < <(df_root_info)

  echo "Root filesystem information:"
  echo "  Filesystem : ${fs}"
  echo "  Mount point: ${mountp}"
  echo "  Total      : ${total} MB"
  echo "  Used       : ${used} MB"
  echo "  Available  : ${avail} MB"
  echo "  Use        : ${usep}"
  echo

  printf 'RESULT,ROOT_FILESYSTEM,TOTAL_MB,%s\n' "$total"
  printf 'RESULT,ROOT_FILESYSTEM,USED_MB,%s\n' "$used"
  printf 'RESULT,ROOT_FILESYSTEM,AVAILABLE_MB,%s\n' "$avail"
  printf 'RESULT,ROOT_FILESYSTEM,RESERVE_MB,%s\n' "$RESERVE_MB"
}

remove_path() {
  local path="$1"
  if [ -d "$path" ]; then
    rm -rf "$path"
  else
    rm -f "$path"
  fi
}

clean_test_file() {
  local cleaned=false
  local path

  if [ -e "$TEST_DIR" ]; then
    echo "Removing test directory: $TEST_DIR"
    remove_path "$TEST_DIR"
    cleaned=true
    pass "RESULT,STORAGE_FILL,CLEAN,PASS,$TEST_DIR"
  fi

  for path in "${LEGACY_TEST_FILES[@]}"; do
    if [ -e "$path" ]; then
      echo "Removing legacy test file: $path"
      remove_path "$path"
      cleaned=true
      pass "RESULT,STORAGE_FILL,CLEAN,PASS,$path"
    fi
  done

  if [ "$cleaned" = "true" ]; then
    sync
  else
    echo "No test file/directory found."
    pass "RESULT,STORAGE_FILL,CLEAN,SKIP,not-found"
  fi
}

handle_existing_test_file() {
  local answer
  local residual_paths=()
  local path

  [ -e "$TEST_DIR" ] && residual_paths+=("$TEST_DIR")
  for path in "${LEGACY_TEST_FILES[@]}"; do
    [ -e "$path" ] && residual_paths+=("$path")
  done

  if [ "${#residual_paths[@]}" -eq 0 ]; then
    echo "Residual test file/directory check: none"
    printf 'RESULT,STORAGE_FILL,RESIDUAL,NO\n'
    return 0
  fi

  warn "Residual test file/directory found:"
  for path in "${residual_paths[@]}"; do
    echo "  $path"
    du -sh "$path" 2>/dev/null || ls -lh "$path" 2>/dev/null || true
    if [ -d "$path" ]; then
      ls -lh "$path" 2>/dev/null | head -n 20 || true
    fi
    printf 'RESULT,STORAGE_FILL,RESIDUAL,YES,%s\n' "$path"
  done

  if [ "$AUTO_CONFIRM" = "true" ]; then
    answer="y"
  elif [ -t 0 ]; then
    read -r -p "Delete residual test file/directory before continuing? [Y/n] " answer
    answer="${answer:-y}"
  else
    echo "ERROR: residual file/directory exists in non-interactive shell. Set CLEAN_ONLY=true or AUTO_CONFIRM=true." >&2
    exit 1
  fi

  case "$answer" in
    y|Y|yes|YES)
      for path in "${residual_paths[@]}"; do
        echo "Removing residual path: $path"
        remove_path "$path"
        printf 'RESULT,STORAGE_FILL,RESIDUAL_REMOVE,PASS,%s\n' "$path"
      done
      sync
      ;;
    *)
      warn "Residual test file/directory was kept."
      echo "Cannot continue fill test safely while residual data exists."
      echo "Run clean command later:"
      echo "  rm -rf $TEST_DIR ${LEGACY_TEST_FILES[*]} && sync"
      exit 0
      ;;
  esac
}

require_integer "RESERVE_MB" "$RESERVE_MB"

echo "======================================"
echo "6-7 Maximum Storage Utilization Test"
echo "Host: $(hostname)"
echo "Date: $(date -Iseconds)"
echo "Target directory: $TARGET_DIR"
echo "Reserve space: ${RESERVE_MB} MB"
echo "Test directory: $TEST_DIR"
echo "Chunk size: ${CHUNK_MB} MB"
echo "======================================"
echo

if [ "$CLEAN_ONLY" = "true" ]; then
  clean_test_file
  print_root_info
  exit 0
fi

print_root_info
handle_existing_test_file
echo
print_root_info

read -r _fs total_mb _used_mb available_mb _usep mount_point < <(df_root_info)

if [ "$mount_point" != "/" ]; then
  warn "TARGET_DIR is on mount point: $mount_point"
  warn "This script is intended for root filesystem testing."
fi

if [ "$available_mb" -le "$RESERVE_MB" ]; then
  fail "ERROR: available space (${available_mb} MB) is already <= reserve (${RESERVE_MB} MB)."
  printf 'RESULT,STORAGE_FILL,FAIL,available_not_enough\n'
  exit 1
fi

fill_mb=$((available_mb - RESERVE_MB))

if [ "$fill_mb" -lt 1 ]; then
  fail "ERROR: calculated fill size is too small: ${fill_mb} MB"
  printf 'RESULT,STORAGE_FILL,FAIL,fill_size_too_small\n'
  exit 1
fi

warn "This will create a large file and intentionally fill the root filesystem."
echo "  Directory      : $TEST_DIR"
echo "  Current free   : ${available_mb} MB"
echo "  Fill size      : ${fill_mb} MB"
echo "  Chunk size     : ${CHUNK_MB} MB per file"
echo "  Target reserve : about ${RESERVE_MB} MB"
echo
enter_to_continue_or_cancel "Press Enter to start dd fill test, or type n to cancel:"

echo
echo "=== Write fill files ==="
mkdir -p "$TEST_DIR"

dd_rc=0
file_index=1
written_total_mb=0

while true; do
  read -r _fs_loop _total_loop _used_loop available_loop_mb _usep_loop _mount_loop < <(df_root_info)
  remaining_fill_mb=$((available_loop_mb - RESERVE_MB))

  if [ "$remaining_fill_mb" -le 0 ]; then
    echo "Target reserve reached. Available=${available_loop_mb} MB, Reserve=${RESERVE_MB} MB"
    break
  fi

  if [ "$remaining_fill_mb" -ge "$CHUNK_MB" ]; then
    write_mb="$CHUNK_MB"
  else
    write_mb="$remaining_fill_mb"
  fi

  file_path="${TEST_DIR}/fill_$(printf '%05d' "$file_index")_${write_mb}MB.bin"
  echo
  echo "Writing file #${file_index}: ${file_path}"
  echo "Current available: ${available_loop_mb} MB"
  echo "Write size: ${write_mb} MB"
  echo "Command: dd if=/dev/zero of=${file_path} bs=${DD_BS} count=${write_mb} status=progress conv=fsync"

  set +e
  dd if=/dev/zero "of=${file_path}" "bs=${DD_BS}" "count=${write_mb}" status=progress conv=fsync
  this_rc=$?
  set -e

  if [ "$this_rc" -ne 0 ]; then
    dd_rc="$this_rc"
    fail "RESULT,STORAGE_FILL,WRITE_FILE,FAIL,${file_path},dd_rc=${this_rc}"
    break
  fi

  written_total_mb=$((written_total_mb + write_mb))
  printf 'RESULT,STORAGE_FILL,WRITE_FILE,PASS,%s,%sMB\n' "$file_path" "$write_mb"
  file_index=$((file_index + 1))
done

echo
echo "Command: sync"
sync

echo
echo "=== Filesystem after fill ==="
print_root_info

actual_size_mb="$(du -sm "$TEST_DIR" 2>/dev/null | awk '{ print $1 }' || echo 0)"
read -r _fs_after _total_after _used_after available_after_mb _usep_after _mount_after < <(df_root_info)

printf 'RESULT,STORAGE_FILL,TEST_DIR,%s\n' "$TEST_DIR"
printf 'RESULT,STORAGE_FILL,REQUESTED_FILL_MB,%s\n' "$fill_mb"
printf 'RESULT,STORAGE_FILL,WRITTEN_TOTAL_MB,%s\n' "$written_total_mb"
printf 'RESULT,STORAGE_FILL,ACTUAL_DIR_MB,%s\n' "$actual_size_mb"
printf 'RESULT,STORAGE_FILL,AVAILABLE_AFTER_MB,%s\n' "$available_after_mb"

if [ "$dd_rc" -eq 0 ]; then
  pass "RESULT,STORAGE_FILL,WRITE,PASS"
else
  fail "RESULT,STORAGE_FILL,WRITE,FAIL,dd_rc=${dd_rc}"
fi

echo
warn "Test directory is still present to keep root filesystem near full:"
echo "  $TEST_DIR"
echo
echo "To clean it later:"
echo "  rm -rf $TEST_DIR ${LEGACY_TEST_FILES[*]} && sync"
echo
echo "Or run:"
echo "  CLEAN_ONLY=true ./$(basename "$0")"

exit "$dd_rc"
