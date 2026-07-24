#!/usr/bin/env bash
set -Eeuo pipefail

# 10-1 LLM Benchmark
#
# First run installs/configures the optional JetPack package, Docker, the
# NVIDIA container runtime and jetson-containers.  It then switches
# the current boot to runlevel 3 without changing the default boot target or
# disabling nvargus-daemon.  Swap is turned off only for the benchmark run.
# No reboot is required.
#
# Every benchmark run records tegrastats only while MLC is running, draws
# CPU/GPU/TJ temperatures, and collects mlc.csv.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_USER="${TEST_USER:-${SUDO_USER:-$(id -un)}}"
USER_HOME="${USER_HOME:-$(getent passwd "$TEST_USER" | cut -d: -f6)}"
[[ -n "$USER_HOME" ]] || USER_HOME="$HOME"

OUTPUT_DIR="${OUTPUT_DIR:-${USER_HOME}/10-1}"
STATE_DIR="${STATE_DIR:-${USER_HOME}/.local/state/MaxTestScript/10-1-llm-benchmark}"
PREPARED_MARKER="${STATE_DIR}/system-prepared"
JETSON_INSTALL_MARKER="${STATE_DIR}/jetson-containers-installed"
JETSON_CONTAINERS_DIR="${JETSON_CONTAINERS_DIR:-${USER_HOME}/jetson-containers}"
DRAW_TEMP_SCRIPT="${DRAW_TEMP_SCRIPT:-${SCRIPT_DIR}/drawtempcurve_auto.py}"
CHART_GENERATOR="${CHART_GENERATOR:-${SCRIPT_DIR}/LLMChartGenerator.exe}"
MLC_CSV_SOURCE="${MLC_CSV_SOURCE:-}"
INSTALL_JETPACK="${INSTALL_JETPACK:-}"
MLC_CACHE_MODE="${MLC_CACHE_MODE:-}"
MLC_MODEL_COUNT="${MLC_MODEL_COUNT:-}"
NAS_MOUNT_POINT="${NAS_MOUNT_POINT:-${MOUNT_POINT:-/mnt/nas_home}}"
NAS_MLC_DIR="${NAS_MLC_DIR:-${NAS_MOUNT_POINT}/MaxTestScript/10-1-MLC-model-cache}"
MLC_CACHE_DIR="${JETSON_CONTAINERS_DIR}/data/models/mlc/cache"
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

  --prepare  Run the package and container-runtime preparation again.
  --status   Show preparation and runtime status without changing anything.

Environment overrides:
  OUTPUT_DIR, JETSON_CONTAINERS_DIR, DRAW_TEMP_SCRIPT, CHART_GENERATOR,
  MLC_CSV_SOURCE, DUT_NAME, INSTALL_JETPACK,
  MLC_CACHE_MODE, MLC_MODEL_COUNT,
  NAS_MOUNT_POINT, NAS_MLC_DIR, TEGRATS_INTERVAL_MS

  INSTALL_JETPACK=0  Skip the nvidia-jetpack meta package.
  INSTALL_JETPACK=1  Install the nvidia-jetpack meta package during preparation.
  MLC_CACHE_MODE=remove  Use the original benchmark flow and remove model cache.
  MLC_CACHE_MODE=keep    Keep downloaded weights and JIT libraries for reuse.
  MLC_CACHE_MODE=upload  Upload the retained model cache to NAS.
  MLC_CACHE_MODE=download  Restore the model cache from NAS, then run and keep it.
  MLC_MODEL_COUNT=6   Run the selected six-model benchmark set.
  MLC_MODEL_COUNT=12  Run all 12 models from the MLC benchmark script.
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

wait_for_apt_lock() {
  local waited=0 timeout_seconds="${1:-300}"
  local lock_files=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/lib/apt/lists/lock
    /var/cache/apt/archives/lock
  )

  while run_sudo fuser "${lock_files[@]}" >/dev/null 2>&1; do
    if ((waited == 0)); then
      warn "Another apt/dpkg process is active; waiting up to ${timeout_seconds}s for its lock."
    fi
    ((waited >= timeout_seconds)) && die "Timed out waiting for apt/dpkg to finish."
    sleep 2
    ((waited += 2))
  done
}

configure_maxn_super() {
  local config="/etc/nvpmodel.conf" current_mode mode_id

  [[ -r "$config" ]] || die "nvpmodel configuration is not readable: $config"
  ensure_sudo_auth
  if ! current_mode="$(run_sudo nvpmodel -q 2>&1)"; then
    die "Unable to query the current nvpmodel power mode: $current_mode"
  fi

  if grep -Eq '^NV Power Mode:[[:space:]]*MAXN_SUPER[[:space:]]*$' <<< "$current_mode"; then
    info "Power mode is already MAXN_SUPER."
    return
  fi

  mode_id="$(
    grep -E 'POWER_MODEL.*NAME=MAXN_SUPER([[:space:]>]|$)' "$config" \
      | sed -n 's/.*ID=\([0-9][0-9]*\).*/\1/p' \
      | sed -n '1p'
  )"
  [[ -n "$mode_id" ]] || die "MAXN_SUPER mode was not found in $config"

  info "Switching power mode to MAXN_SUPER (mode ID $mode_id)..."
  printf 'YES\n' | run_sudo nvpmodel -m "$mode_id"
  if ! current_mode="$(run_sudo nvpmodel -q 2>&1)"; then
    die "Unable to verify nvpmodel after switching: $current_mode"
  fi
  printf '%s\n' "$current_mode"
  grep -Eq '^NV Power Mode:[[:space:]]*MAXN_SUPER[[:space:]]*$' <<< "$current_mode" || \
    die "Power mode verification failed; expected MAXN_SUPER."
}

select_jetpack_installation() {
  local choice

  case "${INSTALL_JETPACK,,}" in
    1|yes|y|install) INSTALL_JETPACK="1"; return ;;
    0|no|n|skip) INSTALL_JETPACK="0"; return ;;
    "") ;;
    *) die "INSTALL_JETPACK must be 0 or 1." ;;
  esac

  [[ -t 0 ]] || die "No interactive terminal is available. Set INSTALL_JETPACK=0 or INSTALL_JETPACK=1."
  while true; do
    printf '\n是否安裝完整的 nvidia-jetpack？\n'
    printf '  1. 是，安裝 nvidia-jetpack（下載量與安裝空間較大）\n'
    printf '  2. 否，只安裝其餘必要工具與 Docker 環境\n'
    read -r -p "請選擇 [1/2]：" choice
    case "$choice" in
      1) INSTALL_JETPACK="1"; return ;;
      2) INSTALL_JETPACK="0"; return ;;
      *) warn "請輸入 1 或 2。" ;;
    esac
  done
}

install_docker_if_missing() {
  local installer attempt docker_installed=0
  local packages=(
    nano git curl jq python3 python3-matplotlib
    mono-runtime libmono-system-drawing4.0-cil
    libmono-system-windows-forms4.0-cil libgdiplus nvidia-container rsync
  )

  if [[ "$INSTALL_JETPACK" == "1" ]]; then
    packages+=(nvidia-jetpack)
    info "nvidia-jetpack installation was selected."
  else
    info "Skipping the nvidia-jetpack meta package as selected."
  fi

  wait_for_apt_lock 300
  run_sudo apt-get update
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get \
    -o DPkg::Lock::Timeout=300 install -y \
    "${packages[@]}"

  if ! command -v docker >/dev/null 2>&1; then
    info "Docker is not installed; installing Docker Engine..."
    installer="$(mktemp)"
    curl -fsSL https://get.docker.com -o "$installer"
    for attempt in 1 2 3; do
      wait_for_apt_lock 300
      if run_sudo sh "$installer"; then
        docker_installed=1
        break
      fi
      warn "Docker installation attempt $attempt failed; retrying after apt/dpkg settles."
      sleep 10
    done
    rm -f "$installer"
    ((docker_installed == 1)) || die "Docker installation failed after 3 attempts."
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
  info "Adding user to Docker group: $TEST_USER"
  run_sudo usermod -aG docker "$TEST_USER"
}

prepare_system() {
  ensure_sudo_auth
  install_docker_if_missing
  configure_maxn_super
  touch "$PREPARED_MARKER"
  sync

  pass "RESULT,LLM_BENCHMARK,PREPARE,PASS"
  info "Preparation is complete; no reboot is required."
}

verify_runtime() {
  [[ -e "$PREPARED_MARKER" ]] || die "Preparation state is missing. Re-run with --prepare."
  command -v docker >/dev/null 2>&1 || die "Docker is not installed. Re-run with --prepare."
  systemctl is-active --quiet docker.service || die "Docker service is not active."
  command -v tegrastats >/dev/null 2>&1 || die "tegrastats is not installed. Re-run with --prepare."
}

ensure_docker_group_access() {
  local group_members script_path

  docker info >/dev/null 2>&1 && return 0

  group_members="$(getent group docker 2>/dev/null | cut -d: -f4 || true)"
  if [[ ",$group_members," != *",$TEST_USER,"* ]]; then
    die "Current user is not a member of the docker group after preparation."
  fi

  command -v sg >/dev/null 2>&1 || \
    die "Docker group membership is not active yet and the sg command is unavailable. Reconnect SSH and run the script again."

  script_path="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
  export MAXTESTSCRIPT_REEXEC_PATH="$script_path"
  info "Activating the new docker group membership without rebooting..."
  exec sg docker -c 'exec bash "$MAXTESTSCRIPT_REEXEC_PATH"'
}

switch_to_runlevel_3() {
  local started_at elapsed

  ensure_sudo_auth
  info "Switching the current boot to runlevel 3 with: sudo init 3"
  info "This normally appears to pause for 30-60 seconds; the script will continue when it returns."
  started_at="$(date +%s)"
  run_sudo init 3
  elapsed="$(( $(date +%s) - started_at ))"
  info "Runlevel 3 switch returned after ${elapsed} seconds."

  if systemctl is-active --quiet display-manager.service; then
    die "Desktop GUI is still active after sudo init 3."
  fi
  systemctl is-active --quiet ssh.service || die "SSH service is not active after sudo init 3."
  systemctl is-active --quiet docker.service || die "Docker service is not active after sudo init 3."
  docker info >/dev/null 2>&1 || die "Docker is not usable after sudo init 3."
  pass "Runlevel 3 verified: desktop GUI stopped; SSH and Docker are active."
}

disable_swap_for_benchmark() {
  ensure_sudo_auth
  info "Turning off all swap for this benchmark run..."

  if systemctl list-unit-files nvzramconfig.service --no-legend 2>/dev/null | grep -q .; then
    run_sudo systemctl stop nvzramconfig.service
  fi
  if [[ -n "$(swapon --show=NAME --noheadings 2>/dev/null)" ]]; then
    run_sudo swapoff -a
  fi
  if [[ -n "$(swapon --show=NAME --noheadings 2>/dev/null)" ]]; then
    die "Swap is still active; refusing to start the no-swap benchmark."
  fi

  pass "No-swap mode verified: swapon reports no active swap devices."
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

select_mlc_cache_mode() {
  local choice

  case "${MLC_CACHE_MODE,,}" in
    remove|original|1) MLC_CACHE_MODE="remove"; return ;;
    keep|2) MLC_CACHE_MODE="keep"; return ;;
    upload|nas-upload|3) MLC_CACHE_MODE="upload"; return ;;
    download|restore|nas-download|4) MLC_CACHE_MODE="download"; return ;;
    "") ;;
    *) die "MLC_CACHE_MODE must be remove, keep, upload, or download." ;;
  esac

  [[ -t 0 ]] || die "No interactive terminal is available. Set MLC_CACHE_MODE=remove, keep, upload, or download."
  while true; do
    printf '\nMLC 模型與快取要如何處理？\n'
    printf '  1. 原流程（模型與 JIT 快取會移除）\n'
    printf '  2. 留下模型（下次執行可重用，會占用 SSD 空間）\n'
    printf '  3. 將已保留的模型上傳到 NAS（不執行 benchmark）\n'
    printf '  4. 從 NAS 下載模型並放回 cache，然後執行 benchmark\n'
    read -r -p "請選擇 [1/2/3/4]：" choice
    case "$choice" in
      1) MLC_CACHE_MODE="remove"; return ;;
      2) MLC_CACHE_MODE="keep"; return ;;
      3) MLC_CACHE_MODE="upload"; return ;;
      4) MLC_CACHE_MODE="download"; return ;;
      *) warn "請輸入 1、2、3 或 4。" ;;
    esac
  done
}

select_mlc_model_count() {
  local choice

  case "${MLC_MODEL_COUNT,,}" in
    6|short) MLC_MODEL_COUNT="6"; return ;;
    12|all|full) MLC_MODEL_COUNT="12"; return ;;
    "") ;;
    *) die "MLC_MODEL_COUNT must be 6 or 12." ;;
  esac

  [[ -t 0 ]] || die "No interactive terminal is available. Set MLC_MODEL_COUNT=6 or MLC_MODEL_COUNT=12."
  while true; do
    printf '\n要執行幾個 MLC 模型？\n'
    printf '  1. 執行精簡的 6 個模型\n'
    printf '  2. 執行 benchmark.sh 完整的 12 個模型\n'
    read -r -p "請選擇 [1/2]：" choice
    case "$choice" in
      1) MLC_MODEL_COUNT="6"; return ;;
      2) MLC_MODEL_COUNT="12"; return ;;
      *) warn "請輸入 1 或 2。" ;;
    esac
  done
}

require_nas_mount() {
  command -v mountpoint >/dev/null 2>&1 || die "mountpoint is not installed. Run run_1_requirement.sh first."
  if ! mountpoint -q "$NAS_MOUNT_POINT"; then
    die "NAS is not mounted at $NAS_MOUNT_POINT. Run $SCRIPT_DIR/run_0_mount_nas.sh first."
  fi
}

directory_has_files() {
  [[ -d "$1" ]] && [[ -n "$(find "$1" -mindepth 1 -print -quit 2>/dev/null)" ]]
}

ensure_rsync() {
  command -v rsync >/dev/null 2>&1 && return 0

  info "rsync is not installed; installing it for NAS transfer progress..."
  ensure_sudo_auth
  wait_for_apt_lock 300
  run_sudo apt-get update
  run_sudo env DEBIAN_FRONTEND=noninteractive apt-get \
    -o DPkg::Lock::Timeout=300 install -y rsync
  command -v rsync >/dev/null 2>&1 || die "rsync installation failed."
}

copy_cache_with_progress() {
  local source="$1" destination="$2"
  rsync -aL --human-readable --info=progress2 --no-inc-recursive \
    "$source/" "$destination/"
}

copy_six_model_cache_with_progress() {
  local source="$1" destination="$2"
  local include_rules=(
    '/.gitkeep'
    '/model_lib/***'
    '/model_weights/'
    '/model_weights/hf/'
    '/model_weights/hf/dusty-nv/'
    '/model_weights/hf/dusty-nv/Llama-3.1-8B-Instruct-q4f16_ft-MLC/***'
    '/model_weights/hf/dusty-nv/Llama-3.2-3B-Instruct-q4f16_ft-MLC/***'
    '/model_weights/hf/dusty-nv/Qwen2.5-7B-Instruct-q4f16_ft-MLC/***'
    '/model_weights/hf/dusty-nv/Phi-3.5-mini-instruct-q4f16_ft-MLC/***'
    '/model_weights/hf/dusty-nv/SmolLM2-1.7B-Instruct-q4f16_ft-MLC/***'
    '/model_weights/hf/mlc-ai/'
    '/model_weights/hf/mlc-ai/gemma-2-2b-it-q4f16_1-MLC/***'
  )
  local rsync_args=(
    -aL --human-readable --info=progress2 --no-inc-recursive
    --prune-empty-dirs
  )
  local rule

  for rule in "${include_rules[@]}"; do
    rsync_args+=("--include=$rule")
  done
  rsync_args+=(--exclude='*')
  rsync "${rsync_args[@]}" "$source/" "$destination/"
}

show_cache_size() {
  local path="$1" label="$2"
  info "  $label: $path"
  info "  Size:  $(du -sh "$path" 2>/dev/null | awk '{print $1}')"
  info "  Files: $(find "$path" -type f 2>/dev/null | wc -l)"
}

upload_mlc_cache_to_nas() {
  require_nas_mount
  directory_has_files "$MLC_CACHE_DIR" || \
    die "No retained MLC model cache was found at $MLC_CACHE_DIR. Run option 2 first."

  ensure_rsync
  mkdir -p "$NAS_MLC_DIR"
  info "Uploading retained MLC model cache to NAS..."
  show_cache_size "$MLC_CACHE_DIR" "Local cache"
  # Dereference any cache symlinks because CIFS shares commonly do not support them.
  copy_cache_with_progress "$MLC_CACHE_DIR" "$NAS_MLC_DIR"
  printf 'source=%s\nhost=%s\nupdated=%s\n' \
    "$MLC_CACHE_DIR" "$(hostname)" "$(date --iso-8601=seconds)" \
    > "$NAS_MLC_DIR/.MaxTestScript-backup-info"
  sync
  show_cache_size "$NAS_MLC_DIR" "NAS backup"
  pass "RESULT,MLC_CACHE,NAS_UPLOAD,PASS,path=$NAS_MLC_DIR"
}

download_mlc_cache_from_nas() {
  require_nas_mount
  directory_has_files "$NAS_MLC_DIR" || \
    die "No MLC model backup was found at $NAS_MLC_DIR. Upload one with option 3 first."

  ensure_rsync
  mkdir -p "$MLC_CACHE_DIR"
  info "Restoring the $MLC_MODEL_COUNT-model MLC cache set from NAS..."
  show_cache_size "$NAS_MLC_DIR" "NAS backup"
  if [[ "$MLC_MODEL_COUNT" == "6" ]]; then
    copy_six_model_cache_with_progress "$NAS_MLC_DIR" "$MLC_CACHE_DIR"
  else
    copy_cache_with_progress "$NAS_MLC_DIR" "$MLC_CACHE_DIR"
  fi
  rm -f "$MLC_CACHE_DIR/.MaxTestScript-backup-info"
  sync
  show_cache_size "$MLC_CACHE_DIR" "Restored local cache"
  pass "RESULT,MLC_CACHE,NAS_DOWNLOAD,PASS,path=$MLC_CACHE_DIR"
}

make_keep_models_benchmark_copy() {
  local source_script="$1" destination_script="$2"

  sed \
    -e 's|python3 benchmark.py|MLC_LLM_HOME=/data/models/mlc/cache python3 benchmark.py|' \
    -e '/rm -rf \/data\/models\/mlc\/cache\/\* || true/d' \
    "$source_script" > "$destination_script"

  grep -q 'MLC_LLM_HOME=/data/models/mlc/cache python3 benchmark.py' "$destination_script" || \
    die "Unable to enable the persistent MLC model cache in the benchmark copy."
  if grep -q 'rm -rf /data/models/mlc/cache' "$destination_script"; then
    die "The keep-models benchmark copy still contains a cache removal command."
  fi
  chmod +x "$destination_script"
  info "Keeping MLC weights and JIT libraries under: $JETSON_CONTAINERS_DIR/data/models/mlc/cache"
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

run_selected_mlc_models() {
  local benchmark_script="$1"

  if [[ "$MLC_MODEL_COUNT" == "12" ]]; then
    # With no model arguments, NVIDIA's benchmark.sh runs its default 12 models.
    bash "$benchmark_script"
    return
  fi

  bash "$benchmark_script" meta-llama/Llama-3.1-8B-Instruct
  bash "$benchmark_script" meta-llama/Llama-3.2-3B-Instruct
  MAX_CONTEXT_LEN=2048 PREFILL_CHUNK_SIZE=1024 \
    bash "$benchmark_script" Qwen/Qwen2.5-7B-Instruct
  QUANTIZATION=q4f16_1 \
    bash "$benchmark_script" google/gemma-2-2b-it
  bash "$benchmark_script" microsoft/Phi-3.5-mini-instruct
  bash "$benchmark_script" HuggingFaceTB/SmolLM2-1.7B-Instruct
}

run_benchmark() {
  local benchmark_script original_benchmark_script benchmark_rc graph_rc=0 csv_rc=0 performance_rc=0

  original_benchmark_script="$JETSON_CONTAINERS_DIR/packages/llm/mlc/benchmark.sh"
  [[ -f "$original_benchmark_script" ]] || die "MLC benchmark script not found: $original_benchmark_script"
  while true; do
    select_mlc_cache_mode
    if [[ "$MLC_CACHE_MODE" == "upload" ]]; then
      upload_mlc_cache_to_nas
      if [[ ! -t 0 ]]; then
        return 0
      fi
      MLC_CACHE_MODE=""
      info "NAS upload completed; returning to the MLC cache menu."
      continue
    fi
    break
  done
  select_mlc_model_count
  if [[ "$MLC_CACHE_MODE" == "download" ]]; then
    download_mlc_cache_from_nas
    MLC_CACHE_MODE="keep"
    info "NAS restore completed; continuing in keep-models mode."
  fi
  if [[ "$MLC_CACHE_MODE" == "keep" ]]; then
    benchmark_script="$STATE_DIR/benchmark-keep-models.sh"
    make_keep_models_benchmark_copy "$original_benchmark_script" "$benchmark_script"
  else
    benchmark_script="$original_benchmark_script"
    info "Using the original MLC flow; each model cache will be removed after its benchmark."
  fi

  switch_to_runlevel_3
  disable_swap_for_benchmark
  rm -f "$TEMP_PNG" "$MLC_CSV_DEST" "$PERFORMANCE_PNG"
  : > "$BENCHMARK_LOG"
  configure_maxn_super
  capture_mlc_start_position
  start_tegrastats
  trap 'stop_tegrastats' EXIT
  trap 'exit 130' INT TERM HUP

  info "Running selected MLC benchmarks ($MLC_MODEL_COUNT models)..."
  set +e
  run_selected_mlc_models "$benchmark_script" 2>&1 | tee "$BENCHMARK_LOG"
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
  info "User:              $TEST_USER"
  info "Home:              $USER_HOME"
  info "Output:            $OUTPUT_DIR"
  if [[ -e "$PREPARED_MARKER" ]]; then
    info "System prepared:   yes"
  else
    info "System prepared:   no"
  fi
  info "Default target:    $(systemctl get-default 2>/dev/null || echo unknown)"
  info "Display manager:   $(systemctl is-active display-manager.service 2>/dev/null || true)"
  info "nvargus daemon:    $(systemctl is-active nvargus-daemon.service 2>/dev/null || true)"
  info "Docker command:    $(command -v docker 2>/dev/null || echo missing)"
  info "Docker service:    $(systemctl is-active docker.service 2>/dev/null || true)"
  info "Active swap:       $(swapon --show=NAME --noheadings 2>/dev/null | paste -sd, - || echo none)"
}

main() {
  if ((STATUS_ONLY)); then
    show_status
    exit 0
  fi

  if ((FORCE_PREPARE)) || [[ ! -e "$PREPARED_MARKER" ]]; then
    select_jetpack_installation
    prepare_system
  fi

  verify_runtime
  ensure_docker_group_access
  ensure_jetson_containers
  run_benchmark
}

main "$@"
