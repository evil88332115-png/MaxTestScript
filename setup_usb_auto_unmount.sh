#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo bash "$0" "$@"
fi

cat > /usr/local/bin/safe_usb_umount.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

echo "Safe USB unmount"
echo

mapfile -t USB_PARTS < <(
  lsblk -P -o NAME,PATH,TYPE,PKNAME,TRAN,RM,FSTYPE,SIZE,MOUNTPOINTS |
    awk '
      {
        delete value
        line = $0
        while (match(line, /[A-Z]+="[^"]*"/)) {
          item = substr(line, RSTART, RLENGTH)
          key = item
          sub(/=.*/, "", key)
          data = item
          sub(/^[^=]+="/, "", data)
          sub(/"$/, "", data)
          value[key] = data
          line = substr(line, RSTART + RLENGTH)
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
)

if [[ "${#USB_PARTS[@]}" -eq 0 ]]; then
  echo "No mounted USB storage partition found."
  exit 0
fi

echo "Mounted USB storage partitions:"
for index in "${!USB_PARTS[@]}"; do
  IFS='|' read -r device mount size filesystem transport <<<"${USB_PARTS[$index]}"
  printf '%d) device=%s mount=%s size=%s filesystem=%s transport=%s\n' \
    "$((index + 1))" "$device" "$mount" "$size" \
    "${filesystem:-unknown}" "${transport:-usb/removable}"
done

echo
echo "Flushing filesystem buffers..."
sync

status=0
for item in "${USB_PARTS[@]}"; do
  IFS='|' read -r device mount size filesystem transport <<<"$item"
  echo "Unmounting $device from $mount ..."
  if umount "$device"; then
    echo "OK: $device unmounted"
  else
    echo "ERROR: failed to unmount $device" >&2
    status=1
  fi
done

echo
lsblk -o NAME,PATH,TYPE,TRAN,RM,FSTYPE,SIZE,MOUNTPOINTS

if [[ "$status" -eq 0 ]]; then
  echo
  echo "RESULT,USB_SAFE_UNMOUNT,PASS"
else
  echo
  echo "RESULT,USB_SAFE_UNMOUNT,FAIL"
fi

exit "$status"
EOF

cat > /usr/local/bin/usb_auto_safe_umount.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

TARGET_SCRIPT="/usr/local/bin/safe_usb_umount.sh"
LOG="/var/log/usb-auto-safe-umount.log"

find_mounted_usb_parts() {
  lsblk -P -o NAME,PATH,TYPE,PKNAME,TRAN,RM,MOUNTPOINTS |
    awk '
      {
        delete value
        line = $0
        while (match(line, /[A-Z]+="[^"]*"/)) {
          item = substr(line, RSTART, RLENGTH)
          key = item
          sub(/=.*/, "", key)
          data = item
          sub(/^[^=]+="/, "", data)
          sub(/"$/, "", data)
          value[key] = data
          line = substr(line, RSTART + RLENGTH)
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
          print value["PATH"]
        }
      }
    '
}

echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] usb-auto-safe-umount started" >> "$LOG"

while true; do
  if mapfile -t parts < <(find_mounted_usb_parts) && [[ "${#parts[@]}" -gt 0 ]]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] mounted USB detected: ${parts[*]}" >> "$LOG"
    if "$TARGET_SCRIPT" >> "$LOG" 2>&1; then
      echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] safe unmount complete" >> "$LOG"
    else
      echo "[$(date '+%Y-%m-%d %H:%M:%S %z')] safe unmount failed" >> "$LOG"
    fi
    sleep 2
  fi
  sleep 1
done
EOF

cat > /etc/systemd/system/usb-auto-safe-umount.service <<'EOF'
[Unit]
Description=Automatically safe-unmount mounted USB storage
After=local-fs.target

[Service]
Type=simple
ExecStart=/usr/local/bin/usb_auto_safe_umount.sh
Restart=always
RestartSec=2
TimeoutStopSec=5
KillMode=control-group

[Install]
WantedBy=multi-user.target graphical.target
EOF

chmod 755 /usr/local/bin/safe_usb_umount.sh /usr/local/bin/usb_auto_safe_umount.sh
systemctl daemon-reload
systemctl enable --now usb-auto-safe-umount.service

echo "Installed and started usb-auto-safe-umount.service"
systemctl --no-pager --full status usb-auto-safe-umount.service || true
