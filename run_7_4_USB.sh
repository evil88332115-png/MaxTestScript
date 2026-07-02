#!/usr/bin/env bash
set -euo pipefail

TEST_FILE_NAME=".usb_7_4_test.bin"
BLOCK_SIZE="512k"
BLOCK_COUNT="2048"

if [[ -t 1 ]]; then
  GREEN=$'\033[1;32m'
  RED=$'\033[1;31m'
  RESET=$'\033[0m'
else
  GREEN=""
  RED=""
  RESET=""
fi

scan_usb_mounts() {
  lsblk -P -o NAME,PATH,TYPE,PKNAME,TRAN,RM,SIZE,FSTYPE,MOUNTPOINTS 2>/dev/null |
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

        if (value["TYPE"] == "disk") {
          disk_transport[value["NAME"]] = value["TRAN"]
          disk_removable[value["NAME"]] = value["RM"]
        }

        parent_transport = disk_transport[value["PKNAME"]]
        parent_removable = disk_removable[value["PKNAME"]]

        if (value["TYPE"] == "part" &&
            value["MOUNTPOINTS"] != "" &&
            (value["TRAN"] == "usb" || parent_transport == "usb" ||
             value["RM"] == "1" || parent_removable == "1")) {
          printf "%s|%s|%s|%s|%s\n",
            value["PATH"], value["MOUNTPOINTS"], value["SIZE"],
            value["FSTYPE"], (value["TRAN"] != "" ? value["TRAN"] : parent_transport)
        }
      }
    '
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

repair_filesystem() {
  local device="$1"
  local filesystem="$2"

  case "${filesystem,,}" in
    vfat|fat|fat16|fat32|msdos)
      if command -v fsck.vfat >/dev/null 2>&1; then
        echo "Repairing FAT filesystem on $device ..."
        sudo fsck.vfat -a "$device"
      else
        echo "WARN: fsck.vfat not found; skip repair for $device"
      fi
      ;;
    exfat)
      if command -v fsck.exfat >/dev/null 2>&1; then
        echo "Repairing exFAT filesystem on $device ..."
        sudo fsck.exfat -a "$device"
      else
        echo "WARN: fsck.exfat not found; skip repair for $device"
      fi
      ;;
    ext2|ext3|ext4)
      if command -v fsck >/dev/null 2>&1; then
        echo "Repairing $filesystem filesystem on $device ..."
        sudo fsck -y "$device"
      else
        echo "WARN: fsck not found; skip repair for $device"
      fi
      ;;
    "")
      echo "WARN: unknown filesystem for $device; skip repair"
      ;;
    *)
      echo "WARN: unsupported filesystem '$filesystem' on $device; skip repair"
      ;;
  esac
}

safe_usb_unmount_and_repair() {
  if [[ -z "${USB_DEVICE:-}" ]]; then
    return 0
  fi

  echo
  echo "======================================"
  echo "7.4 USB - Safe Unmount / Repair"
  echo "Command: sync"
  echo "Command: udisksctl unmount -b ${USB_DEVICE}"
  echo "Command: fsck repair for ${USB_FILESYSTEM:-unknown}"
  echo "======================================"

  sync || true

  if findmnt -rn --source "${USB_DEVICE}" >/dev/null 2>&1; then
    if udisksctl unmount -b "${USB_DEVICE}"; then
      echo "OK: ${USB_DEVICE} unmounted"
    else
      echo "WARN: failed to unmount ${USB_DEVICE}" >&2
    fi
  else
    echo "INFO: ${USB_DEVICE} is not mounted"
  fi

  if repair_filesystem "${USB_DEVICE}" "${USB_FILESYSTEM:-}"; then
    echo "OK: filesystem repair completed for ${USB_DEVICE}"
  else
    echo "WARN: filesystem repair failed for ${USB_DEVICE}" >&2
  fi
}

finish() {
  local exit_code=$?
  trap - EXIT INT TERM
  cleanup
  safe_usb_unmount_and_repair
  exit "${exit_code}"
}

trap finish EXIT INT TERM

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
WRITE_OUTPUT="$(dd if=/dev/zero of="${TEST_FILE}" bs="${BLOCK_SIZE}" count="${BLOCK_COUNT}" conv=fsync 2>&1)"
printf '%s\n' "${WRITE_OUTPUT}"
WRITE_SPEED="$(printf '%s\n' "${WRITE_OUTPUT}" | extract_dd_speed)"

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
READ_OUTPUT="$(dd if="${TEST_FILE}" of=/dev/null bs="${BLOCK_SIZE}" count="${BLOCK_COUNT}" 2>&1)"
printf '%s\n' "${READ_OUTPUT}"
READ_SPEED="$(printf '%s\n' "${READ_OUTPUT}" | extract_dd_speed)"

echo
echo "Removing test file: ${TEST_FILE}"
rm -f -- "${TEST_FILE}"
TEST_FILE=""
printf '%s' "${GREEN}"
echo "======================================"
echo "7.4 USB Storage Test Result"
echo "Device: ${USB_DEVICE}"
echo "Mount:  ${USB_MOUNT}"
echo "Write:  ${WRITE_SPEED:-unknown}"
echo "Read:   ${READ_SPEED:-unknown}"
echo "Status: PASS"
echo "======================================"
printf '%s' "${RESET}"
