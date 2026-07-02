#!/usr/bin/env bash
set -euo pipefail

TARGET_USER="${TARGET_USER:-${SUDO_USER:-${USER:-p}}}"
if [[ "$TARGET_USER" == "root" ]]; then
  TARGET_USER="p"
fi

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo TARGET_USER="$TARGET_USER" bash "$0" "$@"
fi

TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
  echo "ERROR: Cannot find home directory for user '$TARGET_USER'" >&2
  exit 1
fi

cat > /usr/local/bin/usb_monitor_service.sh <<'EOF'
#!/bin/bash
set -u

BASE_DIR="/var/log/usb-monitor"
RUN_DIR="$BASE_DIR/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
ln -sfn "$RUN_DIR" "$BASE_DIR/latest"

echo "USB monitor started at $(date '+%Y-%m-%d %H:%M:%S %z')" > "$RUN_DIR/info.log"
uname -a >> "$RUN_DIR/info.log"
lsusb >> "$RUN_DIR/info.log" 2>&1
lsusb -t >> "$RUN_DIR/info.log" 2>&1

journalctl -kf -o short-iso > "$RUN_DIR/kernel.log" 2>&1 &
KERNEL_PID=$!

udevadm monitor --kernel --udev --subsystem-match=usb --property > "$RUN_DIR/udev.log" 2>&1 &
UDEV_PID=$!

cleanup() {
  kill "$KERNEL_PID" "$UDEV_PID" 2>/dev/null || true
  wait "$KERNEL_PID" "$UDEV_PID" 2>/dev/null || true
  exit 0
}
trap cleanup INT TERM

while true; do
  {
    echo "===== $(date '+%Y-%m-%d %H:%M:%S %z') ====="
    lsusb
    echo
    lsusb -t
    echo
  } >> "$RUN_DIR/lsusb-snapshots.log" 2>&1
  sleep 1
done
EOF

cat > /etc/systemd/system/usb-monitor.service <<'EOF'
[Unit]
Description=USB enumeration monitor
After=local-fs.target systemd-journald.service

[Service]
Type=simple
ExecStart=/usr/local/bin/usb_monitor_service.sh
Restart=always
RestartSec=2
TimeoutStopSec=5
KillMode=control-group

[Install]
WantedBy=multi-user.target graphical.target
EOF

cat > "$TARGET_HOME/usb_monitor_terminal.sh" <<'EOF'
#!/bin/bash
while true; do
  clear
  lsusb -t
  echo
  echo "======================================="
  echo "Return to normal mode:"
  echo "sudo systemctl disable --now usb-auto-safe-umount.service"
  echo "mv ~/.config/autostart/usb-monitor-terminal.desktop ~/.config/autostart/usb-monitor-terminal.desktop.disabled"
  echo "sudo systemctl disable --now usb-monitor.service"
  echo "======================================="
  sleep 1
done
EOF

cat > "$TARGET_HOME/start_usb_monitor_terminal.sh" <<'EOF'
#!/bin/bash
sleep 5
exec gnome-terminal -- bash -lc "$HOME/usb_monitor_terminal.sh; exec bash"
EOF

mkdir -p "$TARGET_HOME/.config/autostart"
cat > "$TARGET_HOME/.config/autostart/usb-monitor-terminal.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=USB Monitor Terminal
Comment=Open terminal and show lsusb -t every second
Exec=$TARGET_HOME/start_usb_monitor_terminal.sh
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

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

chmod 755 \
  /usr/local/bin/usb_monitor_service.sh \
  /usr/local/bin/safe_usb_umount.sh \
  /usr/local/bin/usb_auto_safe_umount.sh
chmod 755 "$TARGET_HOME/usb_monitor_terminal.sh" "$TARGET_HOME/start_usb_monitor_terminal.sh"
chmod 644 "$TARGET_HOME/.config/autostart/usb-monitor-terminal.desktop"
chown "$TARGET_USER:$TARGET_USER" \
  "$TARGET_HOME/usb_monitor_terminal.sh" \
  "$TARGET_HOME/start_usb_monitor_terminal.sh" \
  "$TARGET_HOME/.config/autostart/usb-monitor-terminal.desktop"

systemctl daemon-reload
systemctl enable --now usb-monitor.service
systemctl enable --now usb-auto-safe-umount.service

echo "Installed USB monitor test mode for user: $TARGET_USER"
echo
echo "Services:"
systemctl --no-pager --full status usb-monitor.service || true
systemctl --no-pager --full status usb-auto-safe-umount.service || true
echo
echo "Return to normal mode:"
echo "sudo systemctl disable --now usb-auto-safe-umount.service"
echo "mv ~/.config/autostart/usb-monitor-terminal.desktop ~/.config/autostart/usb-monitor-terminal.desktop.disabled"
echo "sudo systemctl disable --now usb-monitor.service"
