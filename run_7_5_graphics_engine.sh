#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# 7-5 Graphics Engine
#
# Tests:
#   1. glmark2 -s 1920x1080
#   2. glmark2 -s 3840x2160
#   3. Install GravityMark_1.89_arm64.run from NAS mount path
#   4. GravityMark OpenGL: run_fullscreen_gl.sh
#   5. GravityMark Vulkan: run_fullscreen_vk.sh
#
# GravityMark installer is searched from the run_0 NAS mount path:
#   /mnt/nas_home
# ============================================================

NAS_MOUNT="${NAS_MOUNT:-/mnt/nas_home}"
GRAVITYMARK_INSTALLER_NAME="${GRAVITYMARK_INSTALLER_NAME:-GravityMark_1.89_arm64.run}"
WORK_DIR="${WORK_DIR:-${HOME}/GraphicsEngine_7_5}"
GRAVITYMARK_DIR="${GRAVITYMARK_DIR:-}"
LOG_DIR="${LOG_DIR:-${HOME}/7-5_graphics_engine_$(date +%Y%m%d_%H%M%S)}"
export DISPLAY="${DISPLAY:-:0}"
export XAUTHORITY="${XAUTHORITY:-${HOME}/.Xauthority}"

if [ -t 1 ]; then
  RED="\033[31m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  NC="\033[0m"
else
  RED=""
  GREEN=""
  YELLOW=""
  NC=""
fi

pass() { echo -e "${GREEN}$*${NC}"; }
fail() { echo -e "${RED}$*${NC}"; }
warn() { echo -e "${YELLOW}$*${NC}"; }

ensure_glmark2() {
  if command -v glmark2 >/dev/null 2>&1; then
    echo "glmark2 found: $(command -v glmark2)"
    return 0
  fi

  echo "glmark2 not found. Installing glmark2..."
  sudo apt-get update
  sudo apt-get install -y glmark2

  if command -v glmark2 >/dev/null 2>&1; then
    pass "RESULT,GRAPHICS_ENGINE,GLMARK2_INSTALL,PASS"
  else
    fail "RESULT,GRAPHICS_ENGINE,GLMARK2_INSTALL,FAIL"
    return 1
  fi
}

print_command() {
  echo ""
  echo "Command:"
  printf '  '
  printf '%q ' "$@"
  echo ""
  echo ""
}

extract_glmark2_score() {
  awk -F: '/glmark2 Score:/ {
    score=$2
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", score)
    latest=score
  }
  END { print latest }' "$1"
}

extract_gravitymark_score() {
  sed -nE 's/^.*Score:[[:space:]]*([0-9]+([.][0-9]+)?).*$/\1/p' "$1" | tail -n 1
}

run_glmark2_resolution() {
  local resolution="$1"
  local log_file score rc

  ensure_glmark2 || return 1
  mkdir -p "$LOG_DIR"
  log_file="${LOG_DIR}/glmark2_${resolution}.log"

  echo ""
  echo "======================================"
  echo "glmark2 -s ${resolution}"
  echo "Log: $log_file"
  echo "======================================"

  print_command glmark2 -s "$resolution"
  set +e
  glmark2 -s "$resolution" 2>&1 | tee "$log_file"
  rc=${PIPESTATUS[0]}
  set -e

  score="$(extract_glmark2_score "$log_file")"
  if [ -n "$score" ]; then
    echo "glmark2 Score: ${score} (${resolution})"
    pass "RESULT,GRAPHICS_ENGINE,GLMARK2,${resolution},PASS,score=${score}"
  else
    fail "RESULT,GRAPHICS_ENGINE,GLMARK2,${resolution},FAIL,score-not-found,rc=${rc}"
  fi

  return 0
}

find_gravitymark_installer() {
  if [ -f "${WORK_DIR}/${GRAVITYMARK_INSTALLER_NAME}" ]; then
    printf '%s\n' "${WORK_DIR}/${GRAVITYMARK_INSTALLER_NAME}"
    return 0
  fi

  if [ ! -d "$NAS_MOUNT" ]; then
    return 1
  fi

  if [ -f "${NAS_MOUNT}/TEST FILE/${GRAVITYMARK_INSTALLER_NAME}" ]; then
    printf '%s\n' "${NAS_MOUNT}/TEST FILE/${GRAVITYMARK_INSTALLER_NAME}"
    return 0
  fi

  find "$NAS_MOUNT" -maxdepth 5 -type f -name "$GRAVITYMARK_INSTALLER_NAME" 2>/dev/null | head -n 1
}

detect_gravitymark_dir() {
  local candidate

  if [ -n "$GRAVITYMARK_DIR" ] && [ -x "${GRAVITYMARK_DIR}/run_fullscreen_gl.sh" ] && [ -x "${GRAVITYMARK_DIR}/run_fullscreen_vk.sh" ]; then
    printf '%s\n' "$GRAVITYMARK_DIR"
    return 0
  fi

  for candidate in \
    "${HOME}/GravityMark_1.89_linux_arm64" \
    "${WORK_DIR}/GravityMark_1.89_linux_arm64"; do
    if [ -x "${candidate}/run_fullscreen_gl.sh" ] && [ -x "${candidate}/run_fullscreen_vk.sh" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  find "$HOME" -maxdepth 3 -type f -name run_fullscreen_gl.sh 2>/dev/null \
    | while read -r gl_script; do
        candidate="$(dirname "$gl_script")"
        if [ -x "${candidate}/run_fullscreen_vk.sh" ]; then
          printf '%s\n' "$candidate"
          break
        fi
      done
}

install_gravitymark() {
  local source_installer local_installer

  mkdir -p "$WORK_DIR" "$LOG_DIR"

  GRAVITYMARK_DIR="$(detect_gravitymark_dir || true)"
  if [ -n "$GRAVITYMARK_DIR" ]; then
    echo "GravityMark already installed: $GRAVITYMARK_DIR"
    pass "RESULT,GRAPHICS_ENGINE,GRAVITYMARK_INSTALL,SKIP,already-installed"
    return 0
  fi

  echo ""
  echo "Searching GravityMark installer from NAS mount:"
  echo "  NAS mount : $NAS_MOUNT"
  echo "  Filename  : $GRAVITYMARK_INSTALLER_NAME"

  source_installer="$(find_gravitymark_installer || true)"
  if [ -z "$source_installer" ]; then
    fail "ERROR: Cannot find $GRAVITYMARK_INSTALLER_NAME under $NAS_MOUNT"
    echo "Please mount NAS with run_0_mount_nas.sh first."
    fail "RESULT,GRAPHICS_ENGINE,GRAVITYMARK_INSTALL,FAIL,installer-not-found"
    return 1
  fi

  local_installer="${WORK_DIR}/${GRAVITYMARK_INSTALLER_NAME}"
  if [ "$source_installer" != "$local_installer" ]; then
    echo "Copy installer:"
    echo "  From: $source_installer"
    echo "  To  : $local_installer"
    cp -f "$source_installer" "$local_installer"
  fi

  chmod +x "$local_installer"

  echo ""
  echo "Installing GravityMark..."
  echo "Installer: $local_installer"
  echo "Answering Y automatically."
  print_command "$local_installer"

  (
    cd "$WORK_DIR"
    printf 'Y\n' | "./${GRAVITYMARK_INSTALLER_NAME}"
  )

  GRAVITYMARK_DIR="$(detect_gravitymark_dir || true)"
  if [ -n "$GRAVITYMARK_DIR" ] && [ -d "$GRAVITYMARK_DIR" ]; then
    chmod +x "${GRAVITYMARK_DIR}/run_fullscreen_gl.sh" "${GRAVITYMARK_DIR}/run_fullscreen_vk.sh" 2>/dev/null || true
    pass "RESULT,GRAPHICS_ENGINE,GRAVITYMARK_INSTALL,PASS,$GRAVITYMARK_DIR"
    return 0
  fi

  fail "RESULT,GRAPHICS_ENGINE,GRAVITYMARK_INSTALL,FAIL,install-dir-not-found"
  return 1
}

run_gravitymark() {
  local mode="$1"
  local script_name log_file score rc

  case "$mode" in
    opengl) script_name="run_fullscreen_gl.sh" ;;
    vulkan) script_name="run_fullscreen_vk.sh" ;;
    *) echo "ERROR: unknown GravityMark mode: $mode"; return 1 ;;
  esac

  install_gravitymark || return 1
  ensure_gravitymark_server || return 1

  if [ ! -x "${GRAVITYMARK_DIR}/${script_name}" ]; then
    fail "ERROR: script not found or not executable: ${GRAVITYMARK_DIR}/${script_name}"
    fail "RESULT,GRAPHICS_ENGINE,GRAVITYMARK_${mode},FAIL,script-not-found"
    return 1
  fi

  mkdir -p "$LOG_DIR"
  log_file="${LOG_DIR}/gravitymark_${mode}.log"

  echo ""
  echo "======================================"
  echo "GravityMark - ${mode}"
  echo "Directory: $GRAVITYMARK_DIR"
  echo "Log: $log_file"
  echo "======================================"

  print_command bash "$script_name" -close 1
  set +e
  (
    cd "$GRAVITYMARK_DIR"
    bash "$script_name" -close 1
  ) 2>&1 | tee "$log_file"
  rc=${PIPESTATUS[0]}
  set -e

  score="$(extract_gravitymark_score "$log_file")"
  if [ -n "$score" ]; then
    echo "Score: ${score}"
    pass "RESULT,GRAPHICS_ENGINE,GRAVITYMARK_${mode},PASS,score=${score}"
  else
    fail "RESULT,GRAPHICS_ENGINE,GRAVITYMARK_${mode},FAIL,score-not-found,rc=${rc}"
  fi

  return 0
}

is_gravitymark_server_running() {
  pgrep -f 'Browser\.arm64' >/dev/null 2>&1
}

ensure_gravitymark_server() {
  local server_log

  if is_gravitymark_server_running; then
    echo "GravityMark browser/server is already running."
    pass "RESULT,GRAPHICS_ENGINE,GRAVITYMARK_SERVER,SKIP,already-running"
    return 0
  fi

  if [ ! -x "${GRAVITYMARK_DIR}/run_browser.sh" ]; then
    fail "ERROR: GravityMark browser/server script not found: ${GRAVITYMARK_DIR}/run_browser.sh"
    fail "RESULT,GRAPHICS_ENGINE,GRAVITYMARK_SERVER,FAIL,run_browser-not-found"
    return 1
  fi

  mkdir -p "$LOG_DIR"
  server_log="${LOG_DIR}/gravitymark_server.log"

  echo ""
  echo "Starting GravityMark browser/server in background..."
  echo "Command: cd ${GRAVITYMARK_DIR} && ./run_browser.sh"
  echo "Log: $server_log"

  (
    cd "$GRAVITYMARK_DIR"
    nohup ./run_browser.sh > "$server_log" 2>&1 &
    echo $! > "${LOG_DIR}/gravitymark_server.pid"
  )

  sleep 3

  if is_gravitymark_server_running; then
    pass "RESULT,GRAPHICS_ENGINE,GRAVITYMARK_SERVER,PASS,started"
    return 0
  fi

  fail "RESULT,GRAPHICS_ENGINE,GRAVITYMARK_SERVER,FAIL,not-running"
  echo "Last 40 lines of server log:"
  tail -n 40 "$server_log" 2>/dev/null || true
  return 1
}

show_menu() {
  echo ""
  echo "======================================"
  echo "7-5 Graphics Engine"
  echo "Log directory: $LOG_DIR"
  echo "======================================"
  echo "1) glmark2 -s 1920x1080"
  echo "2) glmark2 -s 3840x2160"
  echo "3) Install GravityMark_1.89_arm64.run"
  echo "4) gravitymark - OpenGL"
  echo "5) gravitymark - Vulkan"
  echo "q) Quit"
  echo "======================================"
}

echo "======================================"
echo "7-5 Graphics Engine"
echo "Host: $(hostname)"
echo "Date: $(date -Iseconds)"
echo "NAS mount: $NAS_MOUNT"
echo "Work directory: $WORK_DIR"
echo "GravityMark directory: $GRAVITYMARK_DIR"
echo "======================================"

mkdir -p "$LOG_DIR"

while true; do
  show_menu
  read -r -p "Select: " choice
  case "$choice" in
    1) run_glmark2_resolution "1920x1080" ;;
    2) run_glmark2_resolution "3840x2160" ;;
    3) install_gravitymark ;;
    4) run_gravitymark "opengl" ;;
    5) run_gravitymark "vulkan" ;;
    q|Q) break ;;
    *) echo "Invalid selection: $choice" ;;
  esac
done

echo ""
echo "Done."
echo "Logs saved in: $LOG_DIR"
