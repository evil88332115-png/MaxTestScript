#!/usr/bin/env bash
set -u

LOG_DIR="${LOG_DIR:-/tmp/internet_download_5_10_logs}"
WGET="${WGET:-wget}"
WPUT="${WPUT:-wput}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-0}"
RESPONSE_TIMEOUT_SECONDS="${RESPONSE_TIMEOUT_SECONDS:-5}"
DOWNLOAD_1GB_FILE="${DOWNLOAD_1GB_FILE:-/tmp/5_10_downloaded_1GB.zip}"
FTP_UPLOAD_URL="${FTP_UPLOAD_URL:-ftp://ftp:ftp@ftp.speed.hinet.net/uploads/}"

URLS=(
  "http://ipv4.download.thinkbroadband.com/100MB.zip"
  "http://tpdb.speed2.hinet.net/test_400m.zip"
  "http://ipv4.download.thinkbroadband.com/1GB.zip"
  "ftp://ftp:ftp@ftp.speed.hinet.net/test_100m.zip"
  "ftp://ftp:ftp@ftp.speed.hinet.net/test_400m.zip"
  "${FTP_UPLOAD_URL}"
)

if [[ -t 1 ]]; then
  COLOR_PASS=$'\033[1;32m'
  COLOR_FAIL=$'\033[1;31m'
  COLOR_WARN=$'\033[1;33m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_PASS=""
  COLOR_FAIL=""
  COLOR_WARN=""
  COLOR_RESET=""
fi

csv_escape() {
  local value="$1"
  value="${value//\"/\"\"}"
  printf '"%s"' "${value}"
}

default_route_info() {
  ip -4 route show default 2>/dev/null | head -n 1
}

interface_ipv4() {
  local interface="$1"
  ip -4 -o addr show dev "${interface}" scope global 2>/dev/null |
    awk '{split($4, addr, "/"); print addr[1]; exit}'
}

interface_state() {
  local interface="$1"
  cat "/sys/class/net/${interface}/operstate" 2>/dev/null || echo "unknown"
}

route_interface_for_url() {
  local url="$1"
  local host destination

  host="${url#*://}"
  host="${host#*@}"
  host="${host%%/*}"
  host="${host%%:*}"
  destination="$(getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1; exit}')"

  if [[ -n "${destination}" ]]; then
    ip -4 route get "${destination}" 2>/dev/null |
      awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}'
  fi
}

extract_speed() {
  local log="$1"
  local speed
  speed="$(grep -Eo '\([0-9.]+ [KMGT]?B/s\)' "${log}" 2>/dev/null |
    tail -n 1 | tr -d '()' || true)"

  if [[ -z "${speed}" ]]; then
    speed="$(grep -Eo 'at [0-9.]+ [KMGT]?B/s' "${log}" 2>/dev/null |
      tail -n 1 | sed 's/^at //' || true)"
  fi

  printf '%s' "${speed}"
}

ensure_download_tools() {
  local missing=()

  command -v "${WGET}" >/dev/null 2>&1 || missing+=("wget")
  command -v "${WPUT}" >/dev/null 2>&1 || missing+=("wput")

  if [[ "${#missing[@]}" -eq 0 ]]; then
    echo "Download tools: wget and wput are installed."
    return 0
  fi

  echo "Missing packages: ${missing[*]}"
  echo "Installing required download tools..."

  if ! command -v apt-get >/dev/null 2>&1; then
    echo "ERROR: apt-get not found; cannot install: ${missing[*]}" >&2
    return 1
  fi

  sudo apt-get update &&
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
}

cleanup() {
  rm -f "${DOWNLOAD_1GB_FILE}"
}

trap cleanup EXIT INT TERM

echo "5.10 Internet Download Test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo

if ! ensure_download_tools; then
  echo "ERROR: Failed to install wget/wput." >&2
  exit 1
fi

route="$(default_route_info)"
default_interface="$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<<"${route}")"
gateway="$(awk '{for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}' <<<"${route}")"

if [[ -z "${default_interface}" ]]; then
  echo "ERROR: No IPv4 default network interface found." >&2
  exit 1
fi

local_ip="$(interface_ipv4 "${default_interface}")"
link_state="$(interface_state "${default_interface}")"

echo "Network interface: ${default_interface}"
echo "Interface state: ${link_state}"
echo "IPv4 address: ${local_ip:-unknown}"
echo "Default gateway: ${gateway:-direct}"
echo "Default route: ${route}"
echo "Download output: /dev/null (except 1GB temporary upload file)"
echo "1GB temporary file: ${DOWNLOAD_1GB_FILE}"
echo "No-response timeout: ${RESPONSE_TIMEOUT_SECONDS}s"
if [[ "${TIMEOUT_SECONDS}" -gt 0 ]]; then
  echo "Timeout per test: ${TIMEOUT_SECONDS}s"
else
  echo "Timeout per test: unlimited"
fi
echo

mkdir -p "${LOG_DIR}"
SUMMARY="${LOG_DIR}/summary.csv"
printf 'index,url,interface,status,exit_code,speed,log\n' >"${SUMMARY}"

pass=0
fail=0
download_1gb_ready=0
declare -a RESULT_URLS RESULT_INTERFACES RESULT_STATUSES RESULT_SPEEDS RESULT_TIMES

for i in "${!URLS[@]}"; do
  number="$((i + 1))"
  url="${URLS[$i]}"
  log="${LOG_DIR}/${number}.$([[ "${number}" -eq 6 ]] && echo wput || echo wget).log"
  route_interface="$(route_interface_for_url "${url}")"
  route_interface="${route_interface:-${default_interface}}"

  echo "======================================"
  echo "Test #${number}/${#URLS[@]}"
  echo "URL: ${url}"
  echo "Interface: ${route_interface}"
  if [[ "${number}" -eq 3 ]]; then
    printf 'Command: %q --progress=dot:giga -O %q %q\n' \
      "${WGET}" "${DOWNLOAD_1GB_FILE}" "${url}"
  elif [[ "${number}" -eq 6 ]]; then
    remote_name="5_10_$(hostname)_$(date +%Y%m%d_%H%M%S)_1GB.zip"
    upload_target="${FTP_UPLOAD_URL%/}/${remote_name}"
    printf 'Command: %q %q %q\n' "${WPUT}" "${DOWNLOAD_1GB_FILE}" "${upload_target}"
  else
    printf 'Command: %q --progress=dot:giga -O /dev/null %q\n' "${WGET}" "${url}"
  fi
  echo "======================================"

  start_time="$(date +%s)"
  if [[ "${number}" -eq 6 ]]; then
    if ! command -v "${WPUT}" >/dev/null 2>&1; then
      echo "ERROR: ${WPUT} not found. Install it with: sudo apt install wput" >"${log}"
      rc=127
    elif [[ "${download_1gb_ready}" -ne 1 || ! -s "${DOWNLOAD_1GB_FILE}" ]]; then
      echo "ERROR: Downloaded 1GB file is unavailable: ${DOWNLOAD_1GB_FILE}" >"${log}"
      rc=1
    elif [[ "${TIMEOUT_SECONDS}" -gt 0 ]]; then
      timeout "${TIMEOUT_SECONDS}" "${WPUT}" \
        -T "$((RESPONSE_TIMEOUT_SECONDS * 10))" \
        -t 1 \
        "${DOWNLOAD_1GB_FILE}" "${upload_target}" 2>&1 | tee "${log}"
      rc="${PIPESTATUS[0]}"
    else
      "${WPUT}" \
        -T "$((RESPONSE_TIMEOUT_SECONDS * 10))" \
        -t 1 \
        "${DOWNLOAD_1GB_FILE}" "${upload_target}" 2>&1 | tee "${log}"
      rc="${PIPESTATUS[0]}"
    fi
  else
    output_file="/dev/null"
    if [[ "${number}" -eq 3 ]]; then
      output_file="${DOWNLOAD_1GB_FILE}"
      rm -f "${DOWNLOAD_1GB_FILE}"
    fi

    if [[ "${TIMEOUT_SECONDS}" -gt 0 ]]; then
      timeout "${TIMEOUT_SECONDS}" "${WGET}" \
        --progress=dot:giga \
        --dns-timeout="${RESPONSE_TIMEOUT_SECONDS}" \
        --connect-timeout="${RESPONSE_TIMEOUT_SECONDS}" \
        --read-timeout="${RESPONSE_TIMEOUT_SECONDS}" \
        --tries=1 \
        -O "${output_file}" \
        "${url}" 2>&1 | tee "${log}"
      rc="${PIPESTATUS[0]}"
    else
      "${WGET}" \
        --progress=dot:giga \
        --dns-timeout="${RESPONSE_TIMEOUT_SECONDS}" \
        --connect-timeout="${RESPONSE_TIMEOUT_SECONDS}" \
        --read-timeout="${RESPONSE_TIMEOUT_SECONDS}" \
        --tries=1 \
        -O "${output_file}" \
        "${url}" 2>&1 | tee "${log}"
      rc="${PIPESTATUS[0]}"
    fi
  fi
  elapsed="$(( $(date +%s) - start_time ))"
  speed="$(extract_speed "${log}")"

  if [[ "${number}" -eq 6 && -z "${speed}" && "${rc}" -eq 0 && "${elapsed}" -gt 0 ]]; then
    upload_size="$(stat -c '%s' "${DOWNLOAD_1GB_FILE}" 2>/dev/null || echo 0)"
    if [[ "${upload_size}" =~ ^[0-9]+$ && "${upload_size}" -gt 0 ]]; then
      speed="$(awk -v bytes="${upload_size}" -v seconds="${elapsed}" \
        'BEGIN { printf "%.2f MB/s", bytes / seconds / 1000000 }')"
    fi
  fi

  if [[ "${number}" -eq 3 && "${rc}" -eq 0 ]]; then
    download_1gb_ready=1
  fi

  if [[ "${rc}" -eq 0 ]]; then
    status="PASS"
    pass="$((pass + 1))"
    printf '%sRESULT,INTERNET_DOWNLOAD,%s/%s,PASS,interface=%s,speed=%s,time=%ss%s\n' \
      "${COLOR_PASS}" "${number}" "${#URLS[@]}" "${route_interface}" \
      "${speed:-unknown}" "${elapsed}" "${COLOR_RESET}"
  else
    status="FAIL"
    fail="$((fail + 1))"
    printf '%sRESULT,INTERNET_DOWNLOAD,%s/%s,FAIL,interface=%s,rc=%s,time=%ss%s\n' \
      "${COLOR_FAIL}" "${number}" "${#URLS[@]}" "${route_interface}" \
      "${rc}" "${elapsed}" "${COLOR_RESET}" >&2
    tail -n 20 "${log}" >&2 || true
  fi

  RESULT_URLS[$i]="${url}"
  RESULT_INTERFACES[$i]="${route_interface}"
  RESULT_STATUSES[$i]="${status}"
  RESULT_SPEEDS[$i]="${speed:-unknown}"
  RESULT_TIMES[$i]="${elapsed}s"

  {
    csv_escape "${number}"; printf ','
    csv_escape "${url}"; printf ','
    csv_escape "${route_interface}"; printf ','
    csv_escape "${status}"; printf ','
    csv_escape "${rc}"; printf ','
    csv_escape "${speed:-unknown}"; printf ','
    csv_escape "${log}"
    printf '\n'
  } >>"${SUMMARY}"
  echo
done

echo "5.10 Internet Download Test summary"
echo "Interface: ${default_interface}"
echo "PASS: ${pass}"
echo "FAIL: ${fail}"
echo "CSV: ${SUMMARY}"
echo
echo "Transfer speed summary"
printf '%-4s %-8s %-14s %-12s %-8s %s\n' \
  "No." "Status" "Interface" "Speed" "Time" "URL"
for i in "${!RESULT_URLS[@]}"; do
  printf '%-4s %-8s %-14s %-12s %-8s %s\n' \
    "$((i + 1))" "${RESULT_STATUSES[$i]}" "${RESULT_INTERFACES[$i]}" \
    "${RESULT_SPEEDS[$i]}" "${RESULT_TIMES[$i]}" "${RESULT_URLS[$i]}"
done

if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
