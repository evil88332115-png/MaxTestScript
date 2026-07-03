#!/usr/bin/env bash
set -euo pipefail

LOCAL_DIR="${LOCAL_DIR:-/tmp/ftp_4_12}"
REMOTE_DIR="${REMOTE_DIR:-.}"
BLOCK_SIZE="${BLOCK_SIZE:-1M}"
TRANSFER_PAUSE_SECONDS="${TRANSFER_PAUSE_SECONDS:-5}"
LOG_DIR="${LOG_DIR:-${HOME}/4-12_sftp_$(date +%Y%m%d_%H%M%S)}"

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
LAST_TRANSFER_SIZE=""

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

format_eta() {
  local seconds="$1"
  awk -v total="${seconds}" 'BEGIN {
    if (total < 0 || total == "inf") {
      print "--:--"
      exit
    }
    total = int(total + 0.5)
    h = int(total / 3600)
    m = int((total % 3600) / 60)
    s = total % 60
    if (h > 0) {
      printf "%d:%02d:%02d", h, m, s
    } else {
      printf "%02d:%02d", m, s
    }
  }'
}

print_transfer_progress() {
  local label="$1"
  local kind="$2"
  local target="$3"
  local expected_bytes="$4"
  local start_ns="$5"
  local now_ns elapsed_s current_bytes percent mib_done rate_mib eta_s eta_text

  now_ns="$(date +%s%N)"
  elapsed_s="$(awk -v start="${start_ns}" -v now="${now_ns}" 'BEGIN { printf "%.3f", (now - start) / 1000000000 }')"

  case "${kind}" in
    GET)
      current_bytes="$(stat -c %s "${target}" 2>/dev/null || echo 0)"
      ;;
    PUT)
      current_bytes="$(ssh_server "stat -c %s '${target}' 2>/dev/null || echo 0" 2>/dev/null || echo 0)"
      ;;
    *)
      current_bytes=0
      ;;
  esac

  [[ "${current_bytes}" =~ ^[0-9]+$ ]] || current_bytes=0
  percent="$(awk -v cur="${current_bytes}" -v total="${expected_bytes}" 'BEGIN { if (total > 0) printf "%3.0f", (cur / total) * 100; else print "  0" }')"
  mib_done="$(awk -v cur="${current_bytes}" 'BEGIN { printf "%.1f", cur / 1024 / 1024 }')"
  rate_mib="$(awk -v cur="${current_bytes}" -v sec="${elapsed_s}" 'BEGIN { if (sec > 0) printf "%.2f", cur / 1024 / 1024 / sec; else print "0.00" }')"
  eta_s="$(awk -v cur="${current_bytes}" -v total="${expected_bytes}" -v sec="${elapsed_s}" 'BEGIN {
    if (cur > 0 && sec > 0 && total > cur) printf "%.0f", (total - cur) / (cur / sec);
    else if (total <= cur && total > 0) print 0;
    else print "inf";
  }')"
  eta_text="$(format_eta "${eta_s}")"

  printf 'Progress: %-8s %s%% %8s MiB %8s MiB/s ETA %s\n' \
    "${label}" "${percent}" "${mib_done}" "${rate_mib}" "${eta_text}"
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
  local status start_ns end_ns elapsed_s rate_mib rate_mib_value direction
  local expected_bytes progress_target progress_kind progress_pid

  echo "=== ${label} ==="
  echo "Command: ${command}"
  mkdir -p "${LOG_DIR}"
  expected_bytes="$((mib * 1024 * 1024))"
  progress_kind="${label%% *}"
  progress_target="$(awk '{ print $NF }' <<< "${command}")"
  start_ns="$(date +%s%N)"

  (
    while true; do
      sleep 1
      print_transfer_progress "${label}" "${progress_kind}" "${progress_target}" "${expected_bytes}" "${start_ns}"
    done
  ) &
  progress_pid=$!

  set +e
  printf '%s\nquit\n' "${command}" | sftp_server
  status="${PIPESTATUS[1]}"
  set -e
  kill "${progress_pid}" >/dev/null 2>&1 || true
  wait "${progress_pid}" 2>/dev/null || true
  end_ns="$(date +%s%N)"
  print_transfer_progress "${label}" "${progress_kind}" "${progress_target}" "${expected_bytes}" "${start_ns}"

  if [[ "${status}" -ne 0 ]]; then
    echo "ERROR: ${label} failed." >&2
    return "${status}"
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
  LAST_TRANSFER_SIZE="$(awk '{ print $2 }' <<< "${label}")"
  SFTP_SUMMARY+=("${direction}|${rate_mib}|${label}")

  printf 'Elapsed: %s s\n' "${elapsed_s}"
  printf '%sRESULT,%s,%s s,%s%s\n' "${COLOR_RESULT}" "${label}" "${elapsed_s}" "${rate_mib}" "${COLOR_RESET}"
  echo
}

print_sftp_summary() {
  local size_filter="${1:-}"
  local result direction rate_mib label wanted found
  local title

  echo
  printf '%s========================================%s\n' "${COLOR_WARN}" "${COLOR_RESET}"
  if [[ -n "${size_filter}" ]]; then
    title="${size_filter} FTP BANDWIDTH"
  else
    title="FTP BANDWIDTH"
  fi
  printf '%s       %s%s\n' "${COLOR_WARN}" "${title}" "${COLOR_RESET}"
  printf '%s========================================%s\n' "${COLOR_WARN}" "${COLOR_RESET}"

  if [[ "${#SFTP_SUMMARY[@]}" -eq 0 ]]; then
    echo "No completed SFTP transfer results."
  else
    for wanted in GET PUT; do
      found=0
      for result in "${SFTP_SUMMARY[@]}"; do
        IFS='|' read -r direction rate_mib label <<< "${result}"
        if [[ -n "${size_filter}" && "${label}" != *" ${size_filter}" ]]; then
          continue
        fi
        if [[ "${label}" == "${wanted} "* ]]; then
          printf '%s%-7s %12s%s\n' \
            "${COLOR_RESULT}" "${wanted}" "${rate_mib}" "${COLOR_RESET}"
          found=1
        fi
      done
      if [[ "${found}" -eq 0 ]]; then
        printf '%-7s %12s\n' "${wanted}" "N/A"
      fi
    done
  fi

  printf '%s========================================%s\n' "${COLOR_WARN}" "${COLOR_RESET}"
}

print_all_sftp_summaries() {
  local size

  echo
  echo "All FTP bandwidth results:"
  for size in 1GB 5GB 10GB; do
    print_sftp_summary "${size}"
  done
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
  LAST_TRANSFER_SIZE="${size}"

  if run_download "${size}"; then
    echo "Pause ${TRANSFER_PAUSE_SECONDS}s before upload..."
    sleep "${TRANSFER_PAUSE_SECONDS}"
    echo
    run_upload "${size}" || status="$?"
  else
    status="$?"
  fi

  cleanup_transfer_files "${size}"
  print_sftp_summary "${size}"
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
      print_all_sftp_summaries
      ;;
    *) echo "ERROR: Invalid option: $1" >&2; return 1 ;;
  esac
}

echo "4.12 FTP/SFTP test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Kernel: $(uname -r)"
echo "Log directory: ${LOG_DIR}"
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
echo "Local directory: ${LOCAL_DIR}"
echo "Remote directory: ${SERVER_USER}@${SERVER_IP}:${REMOTE_DIR}"
