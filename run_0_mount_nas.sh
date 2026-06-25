#!/usr/bin/env bash
set -euo pipefail

NAS_SERVER="${NAS_SERVER:-192.168.23.12}"
NAS_SHARE="${NAS_SHARE:-home}"
NAS_USER="${NAS_USER:-sqa}"
NAS_PASS="${NAS_PASS:-a1234567}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/nas_home}"
SMB_VERSION="${SMB_VERSION:-3.0}"
EXTRA_OPTIONS="${EXTRA_OPTIONS:-}"
BOOKMARK_NAME="${BOOKMARK_NAME:-NAS Home}"

PACKAGES=(
  cifs-utils
  coreutils
  ffmpeg
  git
  gstreamer1.0-libav
  gstreamer1.0-plugins-bad
  gstreamer1.0-plugins-base
  gstreamer1.0-plugins-good
  gstreamer1.0-plugins-ugly
  gstreamer1.0-tools
  iperf
  iperf3
  mtr-tiny
  net-tools
  network-manager
  nvme-cli
  openssh-client
  procps
  python3
  python3-matplotlib
  sshpass
  sysbench
  usbutils
  util-linux
  wget
  wput
)

REQUIRED_COMMANDS=(
  dd
  ffplay
  ffprobe
  findmnt
  git
  gst-launch-1.0
  gst-play-1.0
  hwclock
  ifconfig
  iperf
  iperf3
  lsblk
  lsusb
  mount.cifs
  mtr
  nmcli
  nvme
  python3
  sftp
  ssh
  sshpass
  sync
  sysbench
  sysctl
  timedatectl
  timeout
  wget
  wput
)

JETSON_COMMANDS=(
  nvgstplayer-1.0
  tegrastats
)

install_tools() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: apt-get not found. This installer supports Ubuntu/Debian only." >&2
    exit 1
  fi

  local package missing_packages=()
  local command_name missing_commands=()

  for package in "${PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}' "${package}" 2>/dev/null | grep -q "install ok installed"; then
      missing_packages+=("${package}")
    fi
  done

  for command_name in "${REQUIRED_COMMANDS[@]}"; do
    if ! command -v "${command_name}" >/dev/null 2>&1; then
      missing_commands+=("${command_name}")
    fi
  done

  if [[ "${#missing_packages[@]}" -eq 0 && "${#missing_commands[@]}" -eq 0 ]]; then
    echo "All shared requirements are already installed; skipping apt-get update/install."
    return 0
  fi

  echo "Missing package(s): ${missing_packages[*]:-none}"
  echo "Missing command(s): ${missing_commands[*]:-none}"

  if [[ "${#missing_packages[@]}" -eq 0 ]]; then
    echo "No missing apt package detected; skipping apt-get update/install."
    echo "If commands are still missing, check PATH or package mapping."
    return 0
  fi

  local sudo_cmd=()
  if [[ "$(id -u)" -ne 0 ]]; then
    if ! command -v sudo >/dev/null 2>&1; then
      echo "ERROR: sudo not found. Run this script as root." >&2
      exit 1
    fi
    sudo_cmd=(sudo)
  fi

  echo "Installing missing test requirements..."
  "${sudo_cmd[@]}" apt-get update
  if [[ "${#sudo_cmd[@]}" -gt 0 ]]; then
    "${sudo_cmd[@]}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"
  else
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing_packages[@]}"
  fi
}

verify_tools() {
  local command_name missing=0

  echo
  echo "=== Requirement check ==="
  for command_name in "${REQUIRED_COMMANDS[@]}"; do
    if command -v "${command_name}" >/dev/null 2>&1; then
      printf '[OK]      %-18s %s\n' "${command_name}" "$(command -v "${command_name}")"
    else
      printf '[MISSING] %s\n' "${command_name}"
      missing=1
    fi
  done

  echo
  echo "=== Jetson / JetPack component check ==="
  for command_name in "${JETSON_COMMANDS[@]}"; do
    if command -v "${command_name}" >/dev/null 2>&1; then
      printf '[OK]      %-18s %s\n' "${command_name}" "$(command -v "${command_name}")"
    else
      printf '[WARNING] %-18s not found; Jetson multimedia/thermal tests may fail.\n' "${command_name}"
    fi
  done

  if command -v gst-inspect-1.0 >/dev/null 2>&1; then
    for command_name in nvv4l2decoder nv3dsink nvvidconv; do
      if gst-inspect-1.0 "${command_name}" >/dev/null 2>&1; then
        printf '[OK]      GStreamer %-10s available\n' "${command_name}"
      else
        printf '[WARNING] GStreamer %-10s not found; NVIDIA accelerated playback tests may fail.\n' "${command_name}"
      fi
    done
  fi

  if python3 -c 'import matplotlib' >/dev/null 2>&1; then
    echo "[OK]      Python matplotlib available"
  else
    echo "[MISSING] Python matplotlib"
    missing=1
  fi

  if [[ "${missing}" -ne 0 ]]; then
    echo "ERROR: Some required commands are still missing after installation." >&2
    exit 1
  fi
}

mount_nas() {
  local source
  source="//${NAS_SERVER}/${NAS_SHARE}"

  echo "NAS source: ${source}"
  echo "Mount point: ${MOUNT_POINT}"
  echo "SMB version: ${SMB_VERSION}"
  echo

  sudo mkdir -p "${MOUNT_POINT}"

  if mountpoint -q "${MOUNT_POINT}"; then
    echo "${MOUNT_POINT} is already mounted."
    findmnt "${MOUNT_POINT}"
    return 0
  fi

  sudo mount -t cifs "${source}" "${MOUNT_POINT}" \
    -o "username=${NAS_USER},password=${NAS_PASS},vers=${SMB_VERSION},uid=$(id -u),gid=$(id -g),file_mode=0664,dir_mode=0775${EXTRA_OPTIONS:+,${EXTRA_OPTIONS}}"
}

verify_mount() {
  echo
  echo "=== Mount result ==="
  findmnt "${MOUNT_POINT}"
  echo
  echo "=== NAS files ==="
  ls -la "${MOUNT_POINT}" | head -n 30
}

add_file_manager_bookmark() {
  local desktop_user desktop_home bookmark_dir bookmark_file bookmark_uri bookmark_entry

  desktop_user="${SUDO_USER:-$(id -un)}"
  desktop_home="$(getent passwd "${desktop_user}" | cut -d: -f6)"
  if [[ -z "${desktop_home}" ]]; then
    echo "Warning: cannot determine home directory for ${desktop_user}; skipping UI bookmark."
    return 0
  fi

  bookmark_dir="${desktop_home}/.config/gtk-3.0"
  bookmark_file="${bookmark_dir}/bookmarks"
  bookmark_uri="file://${MOUNT_POINT// /%20}"
  bookmark_entry="${bookmark_uri} ${BOOKMARK_NAME}"

  mkdir -p "${bookmark_dir}"
  touch "${bookmark_file}"

  if grep -Fq "${bookmark_uri}" "${bookmark_file}"; then
    echo "File manager bookmark already exists: ${BOOKMARK_NAME}"
  else
    printf '%s\n' "${bookmark_entry}" >> "${bookmark_file}"
    echo "Added file manager bookmark: ${BOOKMARK_NAME}"
  fi

  if [[ "$(id -u)" -eq 0 && "${desktop_user}" != "root" ]]; then
    chown -R "${desktop_user}:" "${bookmark_dir}"
  fi
}

echo "0. Mount NAS"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo

install_tools
verify_tools
mount_nas
verify_mount
add_file_manager_bookmark

echo
echo "RESULT,NAS Mount,${MOUNT_POINT}"
