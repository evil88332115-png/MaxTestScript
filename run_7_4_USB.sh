#!/usr/bin/env bash
set -euo pipefail

TEST_FILE_NAME=".usb_7_4_test.bin"
BLOCK_SIZE="512k"
BLOCK_COUNT="2048"

scan_usb_mounts() {
  lsblk -P -o NAME,PATH,TYPE,TRAN,RM,SIZE,FSTYPE,MOUNTPOINTS 2>/dev/null |
    awk '
      {
        delete value
        while (match($0, /[A-Z]+="[^"]*"/)) {
          item = substr($0, RSTART, RLENGTH)
          key = item
          sub(/=.*/, "", key)
          data = item
          sub(/^[^=]+="/, "", data)
          sub(/"$/, "", data)
          value[key] = data
          $0 = substr($0, RSTART + RLENGTH)
        }

        if (value["TYPE"] == "part" &&
            value["MOUNTPOINTS"] != "" &&
            (value["TRAN"] == "usb" || value["RM"] == "1")) {
          printf "%s|%s|%s|%s|%s\n",
            value["PATH"], value["MOUNTPOINTS"], value["SIZE"],
            value["FSTYPE"], value["TRAN"]
        }
      }
    '
}

select_usb_mount() {
  local index selection

  mapfile -t USB_MOUNTS < <(scan_usb_mounts)

  if [[ "${#USB_MOUNTS[@]}" -eq 0 ]]; then
    echo "ERROR: No mounted USB storage device found." >&2
    echo "Insert the USB drive, wait for it to mount, then run this script again." >&2
    exit 1
  fi

  echo "Detected mounted USB storage:"
  for index in "${!USB_MOUNTS[@]}"; do
    IFS='|' read -r device mount size filesystem transport <<<"${USB_MOUNTS[$index]}"
    printf '%s) device=%s mount=%s size=%s filesystem=%s transport=%s\n' \
      "$((index + 1))" "${device}" "${mount}" "${size}" \
      "${filesystem:-unknown}" "${transport:-usb/removable}"
  done

  if [[ "${#USB_MOUNTS[@]}" -eq 1 ]]; then
    selection=1
    echo "Automatically selected the only mounted USB device."
  else
    while true; do
      read -r -p "Select USB device to test: " selection
      if [[ "${selection}" =~ ^[0-9]+$ ]] &&
        [[ "${selection}" -ge 1 ]] &&
        [[ "${selection}" -le "${#USB_MOUNTS[@]}" ]]; then
        break
      fi
      echo "Invalid selection."
    done
  fi

  IFS='|' read -r USB_DEVICE USB_MOUNT USB_SIZE USB_FILESYSTEM USB_TRANSPORT \
    <<<"${USB_MOUNTS[$((selection - 1))]}"
}

cleanup() {
  if [[ -n "${TEST_FILE:-}" && -f "${TEST_FILE}" ]]; then
    rm -f -- "${TEST_FILE}"
  fi
}

trap cleanup EXIT INT TERM

echo "7.4 USB Storage Test"
echo

select_usb_mount
TEST_FILE="${USB_MOUNT%/}/${TEST_FILE_NAME}"

echo
echo "Selected USB device:"
echo "Device: ${USB_DEVICE}"
echo "Mount path: ${USB_MOUNT}"
echo "Size: ${USB_SIZE}"
echo "Filesystem: ${USB_FILESYSTEM:-unknown}"
echo "Test file: ${TEST_FILE}"

if [[ ! -w "${USB_MOUNT}" ]]; then
  echo "ERROR: Mount path is not writable: ${USB_MOUNT}" >&2
  exit 1
fi

available_kb="$(df -Pk "${USB_MOUNT}" | awk 'NR==2 {print $4}')"
required_kb="$((2048 * 512))"
if [[ ! "${available_kb}" =~ ^[0-9]+$ || "${available_kb}" -lt "${required_kb}" ]]; then
  echo "ERROR: USB drive needs at least 1GB of free space." >&2
  exit 1
fi

echo
echo "======================================"
echo "7.4 USB - Write Test"
printf 'Command: dd if=/dev/zero of=%q bs=%s count=%s conv=fsync\n' \
  "${TEST_FILE}" "${BLOCK_SIZE}" "${BLOCK_COUNT}"
echo "======================================"
dd if=/dev/zero of="${TEST_FILE}" bs="${BLOCK_SIZE}" count="${BLOCK_COUNT}" conv=fsync

echo
echo "======================================"
echo "7.4 USB - Clear Cache"
echo "Command: sudo /sbin/sysctl -w vm.drop_caches=3"
echo "======================================"
sync
sudo /sbin/sysctl -w vm.drop_caches=3

echo
echo "======================================"
echo "7.4 USB - Read Test"
printf 'Command: dd if=%q of=/dev/null bs=%s count=%s\n' \
  "${TEST_FILE}" "${BLOCK_SIZE}" "${BLOCK_COUNT}"
echo "======================================"
dd if="${TEST_FILE}" of=/dev/null bs="${BLOCK_SIZE}" count="${BLOCK_COUNT}"

echo
echo "Removing test file: ${TEST_FILE}"
rm -f -- "${TEST_FILE}"
TEST_FILE=""
echo "RESULT,USB_STORAGE,PASS,device=${USB_DEVICE},mount=${USB_MOUNT}"
