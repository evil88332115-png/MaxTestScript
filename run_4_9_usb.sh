#!/usr/bin/env bash
set -euo pipefail

TEST_FILE_NAME="${TEST_FILE_NAME:-test.bin}"
BLOCK_SIZE="${BLOCK_SIZE:-1024K}"
COUNT="${COUNT:-1024}"
WRITE_RATE=""
READ_RATE=""

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
  printf 'Command:'
  printf ' %q' "$@"
  echo
  output="$("$@" 2>&1)"
  echo "${output}"
  rate="$(printf '%s\n' "${output}" | extract_rate)"
  if [[ -n "${rate}" ]]; then
    printf 'RESULT,%s,%s\n' "${label}" "${rate}"
    case "${label}" in
      Write) WRITE_RATE="${rate}" ;;
      Read) READ_RATE="${rate}" ;;
    esac
  else
    printf 'RESULT,%s,Unable to parse rate\n' "${label}"
  fi
  echo
}

unmount_usb_mount() {
  local mount_path="$1"
  local source=""

  source="$(findmnt -rn -o SOURCE --mountpoint "${mount_path}" 2>/dev/null | head -n 1 || true)"

  echo "=== Unmount USB ==="
  echo "Mount path: ${mount_path}"
  if [[ -n "${source}" ]]; then
    echo "Source: ${source}"
  fi
  echo "Command: sync"
  sync
  echo "Command: sudo umount ${mount_path}"
  sudo umount "${mount_path}"

  if findmnt -rn --mountpoint "${mount_path}" >/dev/null 2>&1; then
    echo "ERROR: USB mount is still mounted: ${mount_path}"
    printf 'RESULT,USB Unmount,%s,FAIL\n' "${mount_path}"
    return 1
  fi

  echo "USB has been unmounted: ${mount_path}"
  printf 'RESULT,USB Unmount,%s,PASS\n' "${mount_path}"
  echo
}

find_usb_mounts() {
  local target

  while IFS= read -r target; do
    target="$(printf '%b' "${target}")"
    if [[ "${target}" == /media/* ]]; then
      printf '%s\n' "${target}"
    fi
  done < <(findmnt -rn -o TARGET)
}

print_mount_detail() {
  local mount_path="$1"
  local detail

  detail="$(findmnt -rn -o SOURCE,FSTYPE,SIZE,USED,AVAIL --mountpoint "${mount_path}" 2>/dev/null | head -n 1 || true)"
  if [[ -n "${detail}" ]]; then
    printf '%s %s\n' "${mount_path}" "${detail}"
  else
    printf '%s\n' "${mount_path}"
  fi
}

print_test_summary() {
  local device="$1"
  local mount_path="$2"
  local status="$3"
  local green reset

  green="$(printf '\033[32m')"
  reset="$(printf '\033[0m')"

  printf '%s' "${green}"
  echo "======================================"
  echo "4.9 USB Storage Test Result"
  echo "Device: ${device:-N/A}"
  echo "Mount:  ${mount_path}"
  echo "Write:  ${WRITE_RATE:-N/A}"
  echo "Read:   ${READ_RATE:-N/A}"
  echo "Status: ${status}"
  echo "======================================"
  printf '%s' "${reset}"
}

select_mount() {
  local mounts count choice
  mapfile -t mounts < <(find_usb_mounts)
  count="${#mounts[@]}"

  if [[ "${count}" -eq 0 ]]; then
    echo "ERROR: No mounted USB storage found under /media." >&2
    echo "Please insert USB storage and confirm it is mounted under /media/[user]/[usb_storage]." >&2
    return 1
  fi

  echo "Detected USB mount path(s):" >&2
  local i
  for i in "${!mounts[@]}"; do
    printf '  [%d] ' "$((i + 1))" >&2
    print_mount_detail "${mounts[$i]}" >&2
  done
  echo >&2

  if [[ -n "${USB_MOUNT:-}" ]]; then
    printf '%s\n' "${USB_MOUNT}"
    return 0
  fi

  if [[ "${count}" -eq 1 ]]; then
    printf '%s\n' "${mounts[0]}"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    echo "ERROR: Multiple USB mount paths found, but this shell is non-interactive." >&2
    echo "Set USB_MOUNT=/media/[user]/[usb_storage] and run again." >&2
    return 1
  fi

  while true; do
    read -r -p "Select USB mount number: " choice
    if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
      printf '%s\n' "${mounts[$((choice - 1))]}"
      return 0
    fi
    echo "Invalid selection."
  done
}

run_usb_test_once() {
  local mount_path test_file device
  mount_path="$(select_mount)"
  test_file="${mount_path%/}/${TEST_FILE_NAME}"
  device="$(findmnt -rn -o SOURCE --mountpoint "${mount_path}" 2>/dev/null | head -n 1 || true)"
  WRITE_RATE=""
  READ_RATE=""

  echo "Selected USB mount: ${mount_path}"
  if [[ -n "${device}" ]]; then
    echo "Selected USB device: ${device}"
  fi
  echo "Test file: ${test_file}"
  echo "Block size: ${BLOCK_SIZE}"
  echo "Count: ${COUNT}"
  echo "This test overwrites ${test_file}."
  echo

  printf 'RESULT,USB Mount,%s\n' "${mount_path}"
  run_dd "Write" sudo dd if=/dev/zero "of=${test_file}" "bs=${BLOCK_SIZE}" "count=${COUNT}" conv=fsync

  echo "=== Drop caches ==="
  sudo /sbin/sysctl -w vm.drop_caches=3
  echo

  run_dd "Read" sudo dd "if=${test_file}" of=/dev/null "bs=${BLOCK_SIZE}"
  echo "Removing test file: ${test_file}"
  rm -f -- "${test_file}"
  echo

  unmount_usb_mount "${mount_path}"
  print_test_summary "${device}" "${mount_path}" "PASS"
}

echo "4.9 USB Storage dd test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Kernel: $(uname -r)"
echo

echo "Requesting sudo permission for dd and drop_caches..."
sudo -v
echo

run_usb_test_once
