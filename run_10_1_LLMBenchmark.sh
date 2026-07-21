#!/usr/bin/env bash
set -Eeuo pipefail

# 10-1 LLM Benchmark
#
# First run:
#   Install/configure JetPack, headless boot, swap, Docker, and the NVIDIA
#   container runtime.  Save the current boot ID and reboot once.
#
# Runs after that reboot:
#   Install/reuse jetson-containers, record tegrastats only while the MLC
#   benchmark is running, draw CPU/GPU/TJ temperatures, and collect mlc.csv.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_USER="${TEST_USER:-${SUDO_USER:-$(id -un)}}"
USER_HOME="${USER_HOME:-$(getent passwd "$TEST_USER" | cut -d: -f6)}"
[[ -n "$USER_HOME" ]] || USER_HOME="$HOME"

OUTPUT_DIR="${OUTPUT_DIR:-${USER_HOME}/10-1}"
STATE_DIR="${STATE_DIR:-${USER_HOME}/.local/state/MaxTestScript/10-1-llm-benchmark}"
PREPARED_BOOT_FILE="${STATE_DIR}/prepared_boot_id"
JETSON_INSTALL_MARKER="${STATE_DIR}/jetson-containers-installed"
JETSON_CONTAINERS_DIR="${JETSON_CONTAINERS_DIR:-${USER_HOME}/jetson-containers}"
DRAW_TEMP_SCRIPT="${DRAW_TEMP_SCRIPT:-${SCRIPT_DIR}/drawtempcurve_auto.py}"
CHART_GENERATOR="${CHART_GENERATOR:-${SCRIPT_DIR}/LLMChartGenerator.exe}"
MLC_CSV_SOURCE="${MLC_CSV_SOURCE:-}"
SWAP_FILE="${SWAP_FILE:-/mnt/16GB.swap}"
TEGRATS_INTERVAL_MS="${TEGRATS_INTERVAL_MS:-1000}"

TEGRATS_LOG="${OUTPUT_DIR}/tegrastats.log"
TEMP_PNG="${OUTPUT_DIR}/temperature_cpu_gpu_tj.png"
BENCHMARK_LOG="${OUTPUT_DIR}/benchmark.log"
MLC_CSV_DEST="${OUTPUT_DIR}/mlc.csv"
PERFORMANCE_PNG="${OUTPUT_DIR}/10-1_llm_performance_b442_vs_official.png"
TEGRATS_PID=""
MLC_SOURCE_PATH=""
MLC_START_LINES=0

if [[ -t 1 ]]; then
  GREEN=$'\033[1;32m'
  RED=$'\033[1;31m'
  YELLOW=$'\033[1;33m'
  RESET=$'\033[0m'
else
  GREEN=""
  RED=""
  YELLOW=""
  RESET=""
fi

info() { printf '%s\n' "$*"; }
pass() { printf '%s%s%s\n' "$GREEN" "$*" "$RESET"; }
warn() { printf '%sWARNING: %s%s\n' "$YELLOW" "$*" "$RESET" >&2; }
die() { printf '%sERROR: %s%s\n' "$RED" "$*" "$RESET" >&2; exit 1; }

if [[ $EUID -eq 0 ]]; then
  die "Do not run the whole script with sudo. Run it as $TEST_USER; the script requests sudo only when required."
fi

usage() {
  cat <<'EOF'
Usage: run_10_1_LLMBenchmark.sh [--prepare] [--status]

  --prepare  Run the preparation stage again and schedule one reboot.
  --status   Show preparation and runtime status without changing anything.

Environment overrides:
  OUTPUT_DIR, JETSON_CONTAINERS_DIR, DRAW_TEMP_SCRIPT, CHART_GENERATOR,
  MLC_CSV_SOURCE, DUT_NAME, SWAP_FILE, TEGRATS_INTERVAL_MS
EOF
}

FORCE_PREPARE=0
STATUS_ONLY=0
while (($#)); do
  case "$1" in
    --prepare) FORCE_PREPARE=1 ;;
    --status) STATUS_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "Unknown option: $1" ;;
  esac
  shift
done

mkdir -p "$OUTPUT_DIR" "$STATE_DIR"

current_boot_id() {
  tr -d '\n' < /proc/sys/kernel/random/boot_id
}

run_sudo() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_sudo_auth() {
  [[ $EUID -eq 0 ]] || sudo -v
}

service_exists() {
  systemctl list-unit-files "$1" --no-legend 2>/dev/null | grep -q .
}

configure_headless() {
  info "Configuring headless boot..."
  run_sudo systemctl set-default multi-user.target
  if service_exists nvargus-daemon.service; then
    run_sudo systemctl disable nvargus-daemon.service
  fi
}

configure_swap() {
  info "Configuring 16 GB swap: $SWAP_FILE"
  if service_exists nvzramconfig.service; then
    run_sudo systemctl disable nvzramconfig.service
  fi

  if [[ ! -f "$SWAP_FILE" ]]; then
    run_sudo fallocate -l 16G "$SWAP_FILE"
    run_sudo chmod 600 "$SWAP_FILE"
    run_sudo mkswap "$SWAP_FILE"
  elif ! run_sudo file "$SWAP_FILE" | grep -qi 'swap file'; then
    die "$SWAP_FILE exists but is not a swap file; refusing to overwrite it."
  fi

  if ! swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAP_FILE"; then
    run_sudo swapon "$SWAP_FILE"
  fi

  if ! grep -Eq "^[[:space:]]*${SWAP_FILE//\//\\/}[[:space:]]+none[[:space:]]+swap[[:space:]]" /etc/fstab; then
    printf '%s\n' "$SWAP_FILE  none  swap  sw  0  0" | run_sudo tee -a /etc/fstab >/dev/null
  fi
}

install_docker_if_missing() {
  local installer

  run_sudo apt-get update
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    nano nvidia-jetpack git curl jq python3 python3-matplotlib \
    mono-runtime libmono-system-drawing4.0-cil \
    libmono-system-windows-forms4.0-cil libgdiplus nvidia-container

  if ! command -v docker >/dev/null 2>&1; then
    info "Docker is not installed; installing Docker Engine..."
    installer="$(mktemp)"
    curl -fsSL https://get.docker.com -o "$installer"
    run_sudo sh "$installer"
    rm -f "$installer"
  else
    info "Docker already installed: $(docker --version 2>/dev/null || true)"
  fi

  command -v nvidia-ctk >/dev/null 2>&1 || die "nvidia-ctk is unavailable after installing nvidia-container."
  run_sudo systemctl enable docker.service
  run_sudo nvidia-ctk runtime configure --runtime=docker

  if [[ ! -s /etc/docker/daemon.json ]]; then
    printf '%s\n' '{}' | run_sudo tee /etc/docker/daemon.json >/dev/null
  fi
  run_sudo jq '. + {"default-runtime": "nvidia"}' /etc/docker/daemon.json \
    | run_sudo tee /etc/docker/daemon.json.tmp >/dev/null
  run_sudo mv /etc/docker/daemon.json.tmp /etc/docker/daemon.json
  run_sudo systemctl daemon-reload
  run_sudo systemctl restart docker.service
  run_sudo usermod -aG docker "$TEST_USER"
}

prepare_system() {
  local boot_id

  ensure_sudo_auth
  configure_headless
  configure_swap
  install_docker_if_missing

  boot_id="$(current_boot_id)"
  printf '%s\n' "$boot_id" > "$PREPARED_BOOT_FILE"
  sync

  pass "RESULT,LLM_BENCHMARK,PREPARE,PASS"
  info "Preparation is complete. The system will reboot into headless mode."
  info "After reboot, run this same script again to start temperature logging and the benchmark."
  sleep 3
  run_sudo reboot
}

verify_post_reboot() {
  local prepared_boot current_boot default_target

  [[ -s "$PREPARED_BOOT_FILE" ]] || die "Preparation state is missing. Run this script normally to prepare the system."
  prepared_boot="$(tr -d '\n' < "$PREPARED_BOOT_FILE")"
  current_boot="$(current_boot_id)"
  if [[ "$prepared_boot" == "$current_boot" ]]; then
    die "Preparation finished in this boot, but the required reboot has not happened yet. Run: sudo reboot"
  fi

  default_target="$(systemctl get-default 2>/dev/null || true)"
  [[ "$default_target" == "multi-user.target" ]] || die "Default target is $default_target, expected multi-user.target."
  command -v docker >/dev/null 2>&1 || die "Docker is not installed. Re-run with --prepare."
  systemctl is-active --quiet docker.service || die "Docker service is not active."
  docker info >/dev/null 2>&1 || die "Current user cannot use Docker. Confirm the reboot and docker group membership."
  command -v tegrastats >/dev/null 2>&1 || die "tegrastats is not installed. Re-run with --prepare."

  if ! swapon --show=NAME --noheadings 2>/dev/null | grep -Fxq "$SWAP_FILE"; then
    warn "$SWAP_FILE is not active; attempting to enable it."
    ensure_sudo_auth
    run_sudo swapon "$SWAP_FILE"
  fi
}

ensure_jetson_containers() {
  if [[ ! -e "$JETSON_CONTAINERS_DIR" ]]; then
    info "Cloning jetson-containers into $JETSON_CONTAINERS_DIR..."
    git clone https://github.com/dusty-nv/jetson-containers "$JETSON_CONTAINERS_DIR"
  elif [[ ! -d "$JETSON_CONTAINERS_DIR/.git" ]]; then
    die "$JETSON_CONTAINERS_DIR exists but is not a Git repository; refusing to overwrite it."
  else
    info "Reusing jetson-containers: $JETSON_CONTAINERS_DIR"
  fi

  if [[ ! -f "$JETSON_INSTALL_MARKER" ]]; then
    info "Installing jetson-containers..."
    bash "$JETSON_CONTAINERS_DIR/install.sh"
    touch "$JETSON_INSTALL_MARKER"
  else
    info "jetson-containers installation marker found; skipping install.sh."
  fi
}

start_tegrastats() {
  : > "$TEGRATS_LOG"
  info "Starting tegrastats: $TEGRATS_LOG"
  tegrastats --interval "$TEGRATS_INTERVAL_MS" > "$TEGRATS_LOG" 2>&1 &
  TEGRATS_PID="$!"
}

stop_tegrastats() {
  if [[ -n "$TEGRATS_PID" ]] && kill -0 "$TEGRATS_PID" >/dev/null 2>&1; then
    kill "$TEGRATS_PID" >/dev/null 2>&1 || true
    wait "$TEGRATS_PID" 2>/dev/null || true
  fi
  TEGRATS_PID=""
}

draw_temperature_curve() {
  [[ -s "$TEGRATS_LOG" ]] || { warn "Tegrastats log is empty; temperature graph was not created."; return 1; }
  [[ -f "$DRAW_TEMP_SCRIPT" ]] || { warn "Temperature drawing script not found: $DRAW_TEMP_SCRIPT"; return 1; }

  info "Drawing CPU/GPU/TJ temperature curve: $TEMP_PNG"
  env PYTHONNOUSERSITE=1 python3 "$DRAW_TEMP_SCRIPT" \
    --file "$TEGRATS_LOG" \
    --mode all \
    --avg-min 0 \
    --interval-ms "$TEGRATS_INTERVAL_MS" \
    --out "$TEMP_PNG"
  [[ -s "$TEMP_PNG" ]]
}

resolve_mlc_csv_source() {
  local candidate
  if [[ -n "$MLC_CSV_SOURCE" ]]; then
    printf '%s\n' "$MLC_CSV_SOURCE"
    return
  fi

  for candidate in \
    "$JETSON_CONTAINERS_DIR/data/benchmarks/mlc.csv" \
    /data/benchmarks/mlc.csv; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  # This is the host path used by jetson-containers when the CSV does not
  # exist yet.  /data is the corresponding path inside the container.
  printf '%s\n' "$JETSON_CONTAINERS_DIR/data/benchmarks/mlc.csv"
}

capture_mlc_start_position() {
  MLC_SOURCE_PATH="$(resolve_mlc_csv_source)"
  if [[ -f "$MLC_SOURCE_PATH" ]]; then
    MLC_START_LINES="$(wc -l < "$MLC_SOURCE_PATH")"
  else
    MLC_START_LINES=0
  fi
  info "MLC CSV source: $MLC_SOURCE_PATH"
  info "Existing CSV lines before this run: $MLC_START_LINES"
}

collect_mlc_csv() {
  local current_lines temp_csv
  [[ -f "$MLC_SOURCE_PATH" ]] || { warn "Benchmark CSV not found: $MLC_SOURCE_PATH"; return 1; }

  current_lines="$(wc -l < "$MLC_SOURCE_PATH")"
  if ((MLC_START_LINES > 0 && current_lines > MLC_START_LINES)); then
    temp_csv="${MLC_CSV_DEST}.tmp"
    awk -v start="$MLC_START_LINES" 'NR == 1 || NR > start' "$MLC_SOURCE_PATH" > "$temp_csv"
    mv -f "$temp_csv" "$MLC_CSV_DEST"
  elif ((MLC_START_LINES > 0 && current_lines == MLC_START_LINES)); then
    warn "Benchmark did not append any rows to $MLC_SOURCE_PATH"
    return 1
  elif cp -f "$MLC_SOURCE_PATH" "$MLC_CSV_DEST" 2>/dev/null; then
    :
  else
    ensure_sudo_auth
    run_sudo cp -f "$MLC_SOURCE_PATH" "$MLC_CSV_DEST"
    run_sudo chown "$(id -u "$TEST_USER"):$(id -g "$TEST_USER")" "$MLC_CSV_DEST"
  fi

  [[ "$(wc -l < "$MLC_CSV_DEST")" -gt 1 ]] || { warn "No current benchmark rows were collected."; return 1; }
  info "Copied benchmark CSV: $MLC_CSV_DEST"
}

detect_official_device_name() {
  local model compatible lower name
  model="$(tr -d '\000' < /proc/device-tree/model 2>/dev/null || true)"
  compatible="$(tr '\000' '\n' < /proc/device-tree/compatible 2>/dev/null || true)"
  lower="${model,,}"

  case "$lower" in
    *"orin nano"*) name="Jetson Orin Nano" ;;
    *"orin nx"*) name="Jetson Orin NX" ;;
    *"agx orin"*) name="Jetson AGX Orin" ;;
    *) name="${model#NVIDIA }" ;;
  esac
  [[ -n "$name" ]] || name="Jetson"

  if [[ "${lower} ${compatible,,}" == *"super"* && "$name" != *" Super" ]]; then
    name+=" Super"
  fi
  printf '%s\n' "$name"
}

detect_dut_name() {
  local os_version detected
  if [[ -n "${DUT_NAME:-}" ]]; then
    printf '%s\n' "$DUT_NAME"
    return
  fi

  os_version="$(cat /etc/os_version 2>/dev/null || true)"
  detected="$(printf '%s\n' "$os_version" | grep -oE 'B[0-9]+' | head -n 1 || true)"
  if [[ -n "$detected" ]]; then
    printf '%s\n' "$detected"
  else
    hostname
  fi
}

draw_llm_performance_chart() {
  local device_name dut_name title official_label dut_label

  [[ -s "$MLC_CSV_DEST" ]] || { warn "MLC CSV is unavailable; performance chart was not created."; return 1; }
  [[ -f "$CHART_GENERATOR" ]] || { warn "LLM chart generator not found: $CHART_GENERATOR"; return 1; }
  command -v mono >/dev/null 2>&1 || { warn "mono is not installed; performance chart was not created."; return 1; }

  device_name="$(detect_official_device_name)"
  dut_name="$(detect_dut_name)"
  title="LLM Performance (Power Mode: MAXN_SUPER)"
  official_label="$device_name (Official)"
  dut_label="$device_name ($dut_name)"

  info "Drawing LLM performance chart: $PERFORMANCE_PNG"
  info "  Official label: $official_label"
  info "  DUT label:      $dut_label"
  mono "$CHART_GENERATOR" \
    --csv "$MLC_CSV_DEST" \
    --output "$PERFORMANCE_PNG" \
    --title "$title" \
    --official-label "$official_label" \
    --dut-label "$dut_label"
  [[ -s "$PERFORMANCE_PNG" ]]
}

run_benchmark() {
  local benchmark_script benchmark_rc graph_rc=0 csv_rc=0 performance_rc=0

  benchmark_script="$JETSON_CONTAINERS_DIR/packages/llm/mlc/benchmark.sh"
  [[ -f "$benchmark_script" ]] || die "MLC benchmark script not found: $benchmark_script"

  rm -f "$TEMP_PNG" "$MLC_CSV_DEST" "$PERFORMANCE_PNG"
  : > "$BENCHMARK_LOG"
  capture_mlc_start_position
  start_tegrastats
  trap 'stop_tegrastats' EXIT
  trap 'exit 130' INT TERM HUP

  info "Running MLC benchmark..."
  set +e
  bash "$benchmark_script" 2>&1 | tee "$BENCHMARK_LOG"
  benchmark_rc="${PIPESTATUS[0]}"
  set -e

  stop_tegrastats
  trap - EXIT INT TERM HUP
  info "Benchmark ended; tegrastats has stopped."

  draw_temperature_curve || graph_rc=$?
  collect_mlc_csv || csv_rc=$?
  if ((csv_rc == 0)); then
    draw_llm_performance_chart || performance_rc=$?
  else
    performance_rc=1
  fi

  info ""
  info "10-1 output directory: $OUTPUT_DIR"
  info "  Benchmark log:  $BENCHMARK_LOG"
  info "  Tegrastats log: $TEGRATS_LOG"
  info "  Temperature:    $TEMP_PNG"
  info "  MLC CSV:        $MLC_CSV_DEST"
  info "  Performance:    $PERFORMANCE_PNG"

  if ((benchmark_rc == 0 && graph_rc == 0 && csv_rc == 0 && performance_rc == 0)); then
    pass "RESULT,LLM_BENCHMARK,10-1,PASS"
    return 0
  fi

  printf '%sRESULT,LLM_BENCHMARK,10-1,FAIL,benchmark_rc=%s,graph_rc=%s,csv_rc=%s,performance_rc=%s%s\n' \
    "$RED" "$benchmark_rc" "$graph_rc" "$csv_rc" "$performance_rc" "$RESET" >&2
  return 1
}

show_status() {
  local prepared_boot="not-prepared"
  [[ -s "$PREPARED_BOOT_FILE" ]] && prepared_boot="$(tr -d '\n' < "$PREPARED_BOOT_FILE")"
  info "User:              $TEST_USER"
  info "Home:              $USER_HOME"
  info "Output:            $OUTPUT_DIR"
  info "Prepared boot ID:  $prepared_boot"
  info "Current boot ID:   $(current_boot_id)"
  info "Default target:    $(systemctl get-default 2>/dev/null || echo unknown)"
  info "Docker command:    $(command -v docker 2>/dev/null || echo missing)"
  info "Docker service:    $(systemctl is-active docker.service 2>/dev/null || true)"
  info "Swap file active:  $(swapon --show=NAME --noheadings 2>/dev/null | grep -Fx "$SWAP_FILE" || echo no)"
}

main() {
  if ((STATUS_ONLY)); then
    show_status
    exit 0
  fi

  if ((FORCE_PREPARE)) || [[ ! -s "$PREPARED_BOOT_FILE" ]]; then
    prepare_system
    exit 0
  fi

  verify_post_reboot
  ensure_jetson_containers
  run_benchmark
}

main "$@"
