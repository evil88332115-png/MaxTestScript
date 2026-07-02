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
  echo "Stop USB auto unmount until next reboot:"
  echo "sudo systemctl stop usb-auto-safe-umount.service"
  echo
  echo "Disable USB auto unmount after reboot:"
  echo "sudo systemctl disable --now usb-auto-safe-umount.service"
  echo
  echo "Stop opening this terminal on login:"
  echo "mv ~/.config/autostart/usb-monitor-terminal.desktop ~/.config/autostart/usb-monitor-terminal.desktop.disabled"
  echo
  echo "Stop USB background log service:"
  echo "sudo systemctl stop usb-monitor.service"
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

chmod 755 /usr/local/bin/usb_monitor_service.sh
chmod 755 "$TARGET_HOME/usb_monitor_terminal.sh" "$TARGET_HOME/start_usb_monitor_terminal.sh"
chmod 644 "$TARGET_HOME/.config/autostart/usb-monitor-terminal.desktop"
chown "$TARGET_USER:$TARGET_USER" \
  "$TARGET_HOME/usb_monitor_terminal.sh" \
  "$TARGET_HOME/start_usb_monitor_terminal.sh" \
  "$TARGET_HOME/.config/autostart/usb-monitor-terminal.desktop"

systemctl daemon-reload
systemctl enable --now usb-monitor.service

echo "Installed and started usb-monitor.service"
echo "Desktop autostart installed for user: $TARGET_USER"
systemctl --no-pager --full status usb-monitor.service || true
