#!/usr/bin/env bash
set -euo pipefail

LOCAL_DIR="${LOCAL_DIR:-/tmp/ftp_4_12}"
REMOTE_DIR="${REMOTE_DIR:-.}"
BLOCK_SIZE="${BLOCK_SIZE:-1M}"
TRANSFER_PAUSE_SECONDS="${TRANSFER_PAUSE_SECONDS:-5}"

if [[ -t 1 ]]; then
  COLOR_RESULT=$'\033[1;32m'
  COLOR_WARN=$'\033[1;33m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_RESULT=""
  COLOR_WARN=""
  COLOR_RESET=""
fi

declare -a SFTP_SUMMARY=()

install_local_tools() {
  local missing=()
  command -v sshpass >/dev/null 2>&1 || missing+=(sshpass)
  command -v sftp >/dev/null 2>&1 || missing+=(openssh-client)

  if [[ "${#missing[@]}" -gt 0 ]]; then
    echo "Installing local package(s): ${missing[*]}"
    sudo apt-get update
    sudo apt-get install -y "${missing[@]}"
    echo
  else
    echo "Local sshpass and sftp are already installed; skipping local install."
    echo
  fi
}

prompt_server_info() {
  if [[ -z "${SERVER_IP:-}" ]]; then
    read -r -p "SFTP server IP: " SERVER_IP
  fi
  if [[ -z "${SERVER_USER:-}" ]]; then
    read -r -p "SFTP username: " SERVER_USER
  fi
  if [[ -z "${SERVER_PASS:-}" ]]; then
    read -r -s -p "SFTP password: " SERVER_PASS
    echo
  fi

  if [[ -z "${SERVER_IP}" || -z "${SERVER_USER}" || -z "${SERVER_PASS}" ]]; then
    echo "ERROR: SFTP server IP, username, and password are required." >&2
    exit 1
  fi
}

ssh_server() {
  SSHPASS="${SERVER_PASS}" sshpass -e ssh -n \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
    -o ConnectTimeout=10 \
    "${SERVER_USER}@${SERVER_IP}" "$@"
}

sftp_server() {
  SSHPASS="${SERVER_PASS}" sshpass -e sftp \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile="${HOME}/.ssh/known_hosts" \
    -o ConnectTimeout=10 \
    "${SERVER_USER}@${SERVER_IP}"
}

size_count() {
  case "$1" in
    1GB) printf '1024' ;;
    5GB) printf '5120' ;;
    10GB) printf '10240' ;;
    *) echo "ERROR: Unsupported size: $1" >&2; return 1 ;;
  esac
}

local_file() {
  printf '%s/%s' "${LOCAL_DIR}" "$1"
}

download_file() {
  printf '%s/GET_%s' "${LOCAL_DIR}" "$1"
}

remote_file() {
  printf '%s/%s' "${REMOTE_DIR}" "$1"
}

upload_file() {
  printf '%s/PUT_%s' "${REMOTE_DIR}" "$1"
}

ensure_remote_file() {
  local size="$1"
  local count file
  count="$(size_count "${size}")"
  file="$(remote_file "${size}")"

  echo "=== Check remote ${size} file ==="
  ssh_server "mkdir -p '${REMOTE_DIR}' && if [ ! -f '${file}' ]; then echo 'Remote ${size} file not found. Creating ${file}...'; dd if=/dev/zero of='${file}' bs='${BLOCK_SIZE}' count='${count}' conv=fsync; else echo 'Remote ${size} file already exists:'; ls -lh '${file}'; fi"
  echo
}

run_sftp_transfer() {
  local label="$1"
  local mib="$2"
  local command="$3"
  local output status start_ns end_ns elapsed_s rate_mib rate_mib_value direction

  echo "=== ${label} ==="
  echo "Command: ${command}"
  start_ns="$(date +%s%N)"
  set +e
  output="$(printf '%s\n' "${command}" | sftp_server 2>&1)"
  status="$?"
  set -e
  end_ns="$(date +%s%N)"

  echo "${output}"
  if [[ "${status}" -ne 0 ]]; then
    echo "ERROR: ${label} failed." >&2
    return "${status}"
  fi
  if printf '%s\n' "${output}" | grep -Eqi \
    'No such file or directory|Permission denied|Couldn.t|Failure|not found'; then
    echo "ERROR: ${label} reported an SFTP error." >&2
    return 1
  fi

  elapsed_s="$(awk -v start="${start_ns}" -v end="${end_ns}" 'BEGIN { printf "%.3f", (end - start) / 1000000000 }')"
  rate_mib_value="$(awk -v mib="${mib}" -v sec="${elapsed_s}" 'BEGIN { if (sec > 0) printf "%.2f", mib / sec; else print "N/A" }')"
  if [[ "${rate_mib_value}" == "N/A" ]]; then
    rate_mib="N/A"
  else
    rate_mib="${rate_mib_value} MiB/s"
  fi

  case "${label}" in
    GET*) direction="Receive" ;;
    PUT*) direction="Send" ;;
    *) direction="${label}" ;;
  esac
  SFTP_SUMMARY+=("${direction}|${rate_mib}|${label}")

  printf 'Elapsed: %s s\n' "${elapsed_s}"
  printf '%sRESULT,%s,%s s,%s%s\n' "${COLOR_RESULT}" "${label}" "${elapsed_s}" "${rate_mib}" "${COLOR_RESET}"
  echo
}

print_sftp_summary() {
  local result direction rate_mib label

  echo
  printf '%s========================================%s\n' "${COLOR_WARN}" "${COLOR_RESET}"
  printf '%s       SFTP TRANSFER BANDWIDTH%s\n' "${COLOR_WARN}" "${COLOR_RESET}"
  printf '%s========================================%s\n' "${COLOR_WARN}" "${COLOR_RESET}"

  if [[ "${#SFTP_SUMMARY[@]}" -eq 0 ]]; then
    echo "No completed SFTP transfer results."
  else
    for result in "${SFTP_SUMMARY[@]}"; do
      IFS='|' read -r direction rate_mib label <<< "${result}"
      printf '%sSFTP %-7s %12s  (%s)%s\n' \
        "${COLOR_RESULT}" "${direction}" "${rate_mib}" "${label}" "${COLOR_RESET}"
    done
  fi

  printf '%s========================================%s\n' "${COLOR_WARN}" "${COLOR_RESET}"
}

run_upload() {
  local size="$1"
  local mib source_file remote_dest expected_bytes remote_bytes
  mib="$(size_count "${size}")"
  source_file="$(download_file "${size}")"
  remote_dest="$(upload_file "${size}")"
  expected_bytes="$((mib * 1024 * 1024))"

  if [[ ! -f "${source_file}" ]]; then
    echo "ERROR: Downloaded file not found; refusing to create a separate upload file: ${source_file}" >&2
    return 1
  fi

  run_sftp_transfer "PUT ${size}" "${mib}" "put ${source_file} ${remote_dest}"
  remote_bytes="$(ssh_server "stat -c %s '${remote_dest}'")"
  if [[ "${remote_bytes}" != "${expected_bytes}" ]]; then
    echo "ERROR: Uploaded file size mismatch: expected ${expected_bytes}, got ${remote_bytes}" >&2
    return 1
  fi
}

run_download() {
  local size="$1"
  local mib local_dest expected_bytes actual_bytes
  mib="$(size_count "${size}")"
  local_dest="$(download_file "${size}")"
  expected_bytes="$((mib * 1024 * 1024))"

  ensure_remote_file "${size}"
  mkdir -p "${LOCAL_DIR}"
  rm -f "${local_dest}"
  run_sftp_transfer "GET ${size}" "${mib}" "get $(remote_file "${size}") ${local_dest}"

  if [[ ! -f "${local_dest}" ]]; then
    echo "ERROR: GET completed without creating ${local_dest}" >&2
    return 1
  fi
  actual_bytes="$(stat -c %s "${local_dest}")"
  if [[ "${actual_bytes}" != "${expected_bytes}" ]]; then
    echo "ERROR: Downloaded file size mismatch: expected ${expected_bytes}, got ${actual_bytes}" >&2
    return 1
  fi
}

cleanup_transfer_files() {
  local size="$1"
  local local_get remote_put
  local_get="$(download_file "${size}")"
  remote_put="$(upload_file "${size}")"

  echo
  echo "=== Cleanup ${size} test files ==="
  rm -f "${local_get}"
  ssh_server "rm -f -- '${remote_put}'"
  echo "Deleted local file: ${local_get}"
  echo "Deleted remote file: ${SERVER_USER}@${SERVER_IP}:${remote_put}"
}

run_download_upload() {
  local size="$1"
  local status=0

  if run_download "${size}"; then
    echo "Pause ${TRANSFER_PAUSE_SECONDS}s before upload..."
    sleep "${TRANSFER_PAUSE_SECONDS}"
    echo
    run_upload "${size}" || status="$?"
  else
    status="$?"
  fi

  cleanup_transfer_files "${size}"
  return "${status}"
}

test_sftp_login() {
  echo "=== SFTP login check ==="
  printf 'quit\n' | sftp_server >/dev/null 2>&1
  echo "SFTP connected: ${SERVER_USER}@${SERVER_IP}"
  echo
}

show_menu() {
  echo "4.12 FTP/SFTP test menu"
  echo "0) Exit"
  echo "1) 1GB Download and Upload"
  echo "2) 5GB Download and Upload"
  echo "3) 10GB Download and Upload"
  echo "4) All Download and Upload"
  echo
}

run_choice() {
  case "$1" in
    0) return 2 ;;
    1) run_download_upload 1GB ;;
    2) run_download_upload 5GB ;;
    3) run_download_upload 10GB ;;
    4)
      run_download_upload 1GB
      run_download_upload 5GB
      run_download_upload 10GB
      ;;
    *) echo "ERROR: Invalid option: $1" >&2; return 1 ;;
  esac
}

echo "4.12 FTP/SFTP test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Kernel: $(uname -r)"
echo

install_local_tools
prompt_server_info
test_sftp_login

if [[ -n "${MENU_CHOICE:-}" ]]; then
  show_menu
  run_choice "${MENU_CHOICE}" || status="$?"
  if [[ "${status:-0}" -eq 2 ]]; then
    echo "Exit."
  elif [[ "${status:-0}" -ne 0 ]]; then
    exit "${status}"
  fi
else
  while true; do
    show_menu
    if ! read -r -p "Select option [0-4]: " MENU_CHOICE; then
      echo
      break
    fi
    echo

    set +e
    run_choice "${MENU_CHOICE}"
    status="$?"
    set -e

    if [[ "${status}" -eq 2 ]]; then
      echo "Exit."
      break
    fi
    if [[ "${status}" -ne 0 ]]; then
      echo "Option failed. Returning to menu."
    fi
    if [[ -t 0 ]]; then
      echo "Press Enter to return to menu..."
      read -r _
      echo
    fi
  done
fi

echo "Summary"
echo "-------"
print_sftp_summary
echo "Local directory: ${LOCAL_DIR}"
echo "Remote directory: ${SERVER_USER}@${SERVER_IP}:${REMOTE_DIR}"
