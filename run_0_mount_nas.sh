#!/usr/bin/env bash
set -euo pipefail

NAS_SERVER="${NAS_SERVER:-192.168.23.12}"
NAS_SHARE="${NAS_SHARE:-home}"
NAS_USER="${NAS_USER:-MaxHuang}"
NAS_PASS="${NAS_PASS:-MaxHuang}"
MOUNT_POINT="${MOUNT_POINT:-/mnt/nas_home}"
SMB_VERSION="${SMB_VERSION:-3.0}"
EXTRA_OPTIONS="${EXTRA_OPTIONS:-}"
BOOKMARK_NAME="${BOOKMARK_NAME:-NAS Home}"

install_tools() {
  if command -v mount.cifs >/dev/null 2>&1; then
    echo "cifs-utils is already installed."
    return 0
  fi

  echo "Installing cifs-utils..."
  sudo apt-get update
  sudo apt-get install -y cifs-utils
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
mount_nas
verify_mount
add_file_manager_bookmark

echo
echo "RESULT,NAS Mount,${MOUNT_POINT}"
