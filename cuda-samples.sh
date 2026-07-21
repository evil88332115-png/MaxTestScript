#!/usr/bin/env bash
set -Eeuo pipefail

# One-click CUDA samples setup, build, and graphics test entry point.

REPO_URL="https://github.com/NVIDIA/cuda-samples.git"
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
TOOLS_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
RUNNER_SOURCE="$TOOLS_DIR/run_tests_v12_5.py"
JOBS="${CUDA_SAMPLES_JOBS:-2}"
SM="${CUDA_SAMPLES_SM:-87}"
MIN_EXISTING_BINARIES="${CUDA_SAMPLES_MIN_BINARIES:-150}"
REBUILD=0
STATUS_ONLY=0

usage() {
  cat <<'EOF'
Usage: cuda_samples_one_click.sh [--rebuild] [--status]

  --rebuild  Re-run the full build even when a completed build is detected.
  --status   Show detected CUDA and reusable local builds, then exit.

Environment overrides:
  CUDA_SAMPLES_JOBS=2
  CUDA_SAMPLES_SM=87
EOF
}

while (($#)); do
  case "$1" in
    --rebuild) REBUILD=1 ;;
    --status) STATUS_ONLY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

version_le() {
  local lower="$1" upper="$2" first
  first="$(printf '%s\n%s\n' "$lower" "$upper" | sort -V | head -n 1)"
  [[ "$first" == "$lower" ]]
}

detect_nvcc() {
  local candidate
  for candidate in /usr/local/cuda/bin/nvcc /usr/local/cuda-*/bin/nvcc; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  command -v nvcc 2>/dev/null || return 1
}

cuda_version_from_nvcc() {
  "$1" --version | sed -nE 's/.*release ([0-9]+\.[0-9]+).*/\1/p' | head -n 1
}

binary_dir_for_repo() {
  local repo="$1"
  if [[ -d "$repo/bin/aarch64/linux/release" ]]; then
    printf '%s\n' "$repo/bin/aarch64/linux/release"
  elif [[ -d "$repo/build/bin/aarch64/linux/release" ]]; then
    printf '%s\n' "$repo/build/bin/aarch64/linux/release"
  else
    printf '%s\n' "$repo/bin/aarch64/linux/release"
  fi
}

binary_count() {
  local bin_dir="$1"
  [[ -d "$bin_dir" ]] || { printf '0\n'; return; }
  find "$bin_dir" -maxdepth 1 -type f -executable -printf '.' | wc -c
}

local_reusable_repo() {
  local cuda_version="$1" best_version="" repo version tag bin_dir count marker
  shopt -s nullglob
  for repo in "$HOME"/cuda-samples-v*; do
    [[ -d "$repo/.git" ]] || continue
    version="${repo##*/cuda-samples-v}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+$ ]] || continue
    version_le "$version" "$cuda_version" || continue
    tag="$(git -C "$repo" describe --tags --exact-match 2>/dev/null || true)"
    [[ "$tag" == "v$version" ]] || continue
    bin_dir="$(binary_dir_for_repo "$repo")"
    count="$(binary_count "$bin_dir")"
    marker="$repo/.cuda-samples-auto-built-cuda${cuda_version}-sm${SM}"
    if [[ -f "$marker" || "$count" -ge "$MIN_EXISTING_BINARIES" ]]; then
      if [[ -z "$best_version" ]] || version_le "$best_version" "$version"; then
        best_version="$version"
      fi
    fi
  done
  shopt -u nullglob
  [[ -n "$best_version" ]] && printf '%s\n' "$HOME/cuda-samples-v$best_version"
}

install_prerequisites() {
  echo "Installing JetPack and CUDA Samples build dependencies..."
  sudo apt update
  sudo apt install -y \
    nvidia-jetpack \
    git \
    build-essential \
    cmake \
    pkg-config \
    freeglut3-dev \
    libgl1-mesa-dev \
    libglu1-mesa-dev \
    libfreeimage-dev \
    libopenmpi-dev \
    openmpi-bin \
    libvulkan-dev \
    libglfw3-dev \
    mesa-utils \
    wmctrl \
    xdotool
}

select_remote_tag() {
  local cuda_version="$1" version best=""
  while IFS= read -r version; do
    version_le "$version" "$cuda_version" || continue
    best="$version"
  done < <(
    git ls-remote --tags --refs "$REPO_URL" 'refs/tags/v*' |
      awk -F/ '$3 ~ /^v[0-9]+\.[0-9]+$/ {sub(/^v/, "", $3); print $3}' |
      sort -Vu
  )
  [[ -n "$best" ]] || return 1
  printf 'v%s\n' "$best"
}

configure_shell_cuda() {
  local path_line='export PATH=/usr/local/cuda/bin:$PATH'
  local lib_line='export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH'
  grep -qxF "$path_line" "$HOME/.bashrc" 2>/dev/null || printf '%s\n' "$path_line" >> "$HOME/.bashrc"
  grep -qxF "$lib_line" "$HOME/.bashrc" 2>/dev/null || printf '%s\n' "$lib_line" >> "$HOME/.bashrc"
  export PATH="/usr/local/cuda/bin:$PATH"
  export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
}

build_samples() {
  local repo="$1" cuda_version="$2" tag="$3" log
  log="$repo/build-auto-cuda${cuda_version}-$(date +%Y%m%d-%H%M%S).log"
  echo "Building all samples from $tag for SM $SM with -j$JOBS..."
  cd "$repo"
  set -o pipefail
  if [[ -f "$repo/Makefile" && -d "$repo/Samples" && ! -f "$repo/CMakeLists.txt" ]]; then
    make -j"$JOBS" SMS="$SM" 2>&1 | tee "$log"
  elif [[ -f "$repo/CMakeLists.txt" ]]; then
    cmake -S "$repo" -B "$repo/build" \
      -DBUILD_TEGRA=True \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_CUDA_ARCHITECTURES="$SM"
    cmake --build "$repo/build" -j"$JOBS" 2>&1 | tee "$log"
    cmake --install "$repo/build" 2>&1 | tee -a "$log"
  else
    echo "Unsupported cuda-samples build layout in $repo" >&2
    return 1
  fi
  touch "$repo/.cuda-samples-auto-built-cuda${cuda_version}-sm${SM}"
  echo "Finished building CUDA samples"
}

run_graphics_prompt() {
  local repo="$1" bin_dir="$2" seconds output
  if [[ ! -f "$RUNNER_SOURCE" ]]; then
    echo "Missing runner: $RUNNER_SOURCE" >&2
    return 1
  fi
  cp -f "$RUNNER_SOURCE" "$repo/run_tests_v12_5.py"
  while true; do
    printf '每個圖形視窗要顯示幾秒？ '
    IFS= read -r seconds
    if [[ "$seconds" =~ ^[0-9]+$ ]]; then
      break
    fi
    echo "請輸入 0 或正整數秒數。"
  done
  if [[ "$seconds" == "0" ]]; then
    echo "已略過圖形測試。"
    return 0
  fi
  output="$repo/test-v12.5/graphics-${seconds}s-$(date +%Y%m%d-%H%M%S)"
  DISPLAY="${DISPLAY:-:0}" python3 "$repo/run_tests_v12_5.py" \
    --repo "$repo" \
    --bin "$bin_dir" \
    --group graphics \
    --include-graphics \
    --graphics-duration "$seconds" \
    --output "$output"
}

main() {
  local nvcc cuda_version repo="" tag version bin_dir count marker

  nvcc="$(detect_nvcc || true)"
  if [[ -z "$nvcc" ]]; then
    if ((STATUS_ONLY)); then
      echo "CUDA nvcc: not installed"
      exit 1
    fi
    install_prerequisites
    nvcc="$(detect_nvcc || true)"
    [[ -n "$nvcc" ]] || { echo "nvcc is still unavailable after installing nvidia-jetpack" >&2; exit 1; }
  fi

  cuda_version="$(cuda_version_from_nvcc "$nvcc")"
  [[ -n "$cuda_version" ]] || { echo "Unable to detect CUDA major.minor from $nvcc" >&2; exit 1; }
  echo "Detected CUDA Toolkit: $cuda_version ($nvcc)"

  repo="$(local_reusable_repo "$cuda_version" || true)"
  if [[ -n "$repo" && $REBUILD -eq 0 ]]; then
    tag="$(git -C "$repo" describe --tags --exact-match)"
    bin_dir="$(binary_dir_for_repo "$repo")"
    count="$(binary_count "$bin_dir")"
    marker="$repo/.cuda-samples-auto-built-cuda${cuda_version}-sm${SM}"
    echo "Reusing completed build: $repo ($tag, $count executables)"
    if ((STATUS_ONLY)); then exit 0; fi
    touch "$marker"
    configure_shell_cuda
    run_graphics_prompt "$repo" "$bin_dir"
    exit $?
  fi

  if ((STATUS_ONLY)); then
    echo "No reusable completed build found for CUDA $cuda_version"
    exit 1
  fi

  install_prerequisites
  configure_shell_cuda

  tag="$(select_remote_tag "$cuda_version" || true)"
  [[ -n "$tag" ]] || { echo "No cuda-samples vX.Y tag found at or below CUDA $cuda_version" >&2; exit 1; }
  version="${tag#v}"
  echo "Selected cuda-samples tag: $tag (newest tag not newer than CUDA $cuda_version)"
  repo="$HOME/cuda-samples-$tag"

  if [[ ! -e "$repo" ]]; then
    git clone --branch "$tag" --depth 1 "$REPO_URL" "$repo"
  elif [[ ! -d "$repo/.git" ]]; then
    echo "Refusing to overwrite existing non-git path: $repo" >&2
    exit 1
  elif [[ "$(git -C "$repo" describe --tags --exact-match 2>/dev/null || true)" != "$tag" ]]; then
    echo "Existing repository $repo is not checked out at $tag; refusing to overwrite it." >&2
    exit 1
  fi

  build_samples "$repo" "$cuda_version" "$tag"
  bin_dir="$(binary_dir_for_repo "$repo")"
  count="$(binary_count "$bin_dir")"
  echo "Compiled executable count: $count"
  [[ "$count" -gt 0 ]] || { echo "Build completed but no executables were found in $bin_dir" >&2; exit 1; }
  run_graphics_prompt "$repo" "$bin_dir"
}

main "$@"
