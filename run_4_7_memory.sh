#!/usr/bin/env bash
set -euo pipefail

if [[ -t 1 && "${TERM:-dumb}" != "dumb" ]]; then
  BOLD=$'\033[1m'
  CYAN=$'\033[1;36m'
  GREEN=$'\033[1;32m'
  YELLOW=$'\033[1;33m'
  RESET=$'\033[0m'
else
  BOLD=""
  CYAN=""
  GREEN=""
  YELLOW=""
  RESET=""
fi

declare -a MEMORY_RESULTS=()

convert_to_gb() {
  awk -v mib="$1" 'BEGIN { printf "%.2f", mib * 0.001048576 }'
}

run_case() {
  local label="$1"
  local oper="$2"
  local mode="$3"
  local output mib gb

  printf '%s=== %s ===%s\n' "${CYAN}" "${label}" "${RESET}"
  output="$(sysbench --test=memory \
    --memory-block-size=8K \
    --memory-total-size=1G \
    --memory-oper="${oper}" \
    --memory-access-mode="${mode}" \
    run 2>&1)"

  echo "${output}"
  mib="$(printf '%s\n' "${output}" | awk '/MiB\/sec/ { gsub(/[()]/, "", $4); print $4; exit }')"
  if [[ -z "${mib}" ]]; then
    echo "ERROR: Unable to parse MiB/sec for ${label}" >&2
    return 1
  fi

  gb="$(convert_to_gb "${mib}")"
  MEMORY_RESULTS+=("${label}|${gb}")
  printf '%sRESULT: %-18s %10s GB/s%s\n' \
    "${GREEN}" "${label}" "${gb}" "${RESET}"
  echo
}

printf '%s4.7 Memory sysbench test%s\n' "${BOLD}" "${RESET}"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Kernel: $(uname -r)"
echo

if ! command -v sysbench >/dev/null 2>&1; then
  echo "sysbench is not installed. Installing sysbench..."
  sudo apt-get update
  sudo apt-get install -y sysbench
  echo
fi

sysbench --version
free -h
echo

run_case "Random Read" read rnd
run_case "Random Write" write rnd
run_case "Sequential Read" read seq
run_case "Sequential Write" write seq

echo
printf '%s========================================%s\n' "${YELLOW}" "${RESET}"
printf '%s       MEMORY BANDWIDTH (GB/s)%s\n' "${YELLOW}" "${RESET}"
printf '%s========================================%s\n' "${YELLOW}" "${RESET}"
for result in "${MEMORY_RESULTS[@]}"; do
  IFS='|' read -r label gb <<< "${result}"
  printf '%s%-20s %10s GB/s%s\n' \
    "${GREEN}" "${label}" "${gb}" "${RESET}"
done
printf '%s========================================%s\n' "${YELLOW}" "${RESET}"
printf 'Conversion: MiB/s x 0.001048576 = GB/s\n'
