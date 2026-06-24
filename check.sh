#!/usr/bin/env bash
# check_jetson_stack.sh (v2)
# 顯示 OS / JetPack / CUDA / cuDNN / TensorRT / OpenGL / GLES / Vulkan 版本
# 失敗時不會中止，而是顯示 N/A + 原因

set -u  # 不用 set -e，避免中途退出
set -o pipefail

have_cmd() { command -v "$1" >/dev/null 2>&1; }

echo "==== System / Jetson Stack Info ===="

# --- OS ---
OS_NAME="$(lsb_release -ds 2>/dev/null || grep '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '"')"
echo "Operating System: ${OS_NAME:-Unknown}"

# --- JetPack (nvidia-jetpack meta package) ---
if dpkg-query -W nvidia-jetpack >/dev/null 2>&1; then
    JP_VER=$(dpkg-query -W -f='${Version}\n' nvidia-jetpack)
    echo "JetPack SDK version: ${JP_VER}"
else
    if [[ -f /etc/nv_tegra_release ]]; then
        L4T_INFO=$(sed 's/^# //;s/, */ , /g' /etc/nv_tegra_release)
        echo "JetPack SDK version: (nvidia-jetpack pkg not found)"
        echo "  L4T info: ${L4T_INFO}"
    else
        echo "JetPack SDK version: N/A (nvidia-jetpack pkg not found)"
    fi
fi

# --- CUDA ---
if have_cmd nvcc; then
    CUDA_VER=$(nvcc --version 2>/dev/null | awk '/release/{print $6}' | tr -d ',')
    echo "CUDA Toolkit version: ${CUDA_VER:-Unknown}"
elif [[ -f /usr/local/cuda/version.json ]]; then
    CUDA_VER=$(grep '"version"' /usr/local/cuda/version.json | head -n1 | sed 's/.*: *"//;s/".*//')
    echo "CUDA Toolkit version: ${CUDA_VER}"
else
    echo "CUDA Toolkit version: N/A (nvcc not found)"
fi

# --- cuDNN ---
if [[ -f /usr/include/cudnn_version.h ]]; then
    CUDNN_MAJOR=$(grep -E '^#define CUDNN_MAJOR' /usr/include/cudnn_version.h | awk '{print $3}')
    CUDNN_MINOR=$(grep -E '^#define CUDNN_MINOR' /usr/include/cudnn_version.h | awk '{print $3}')
    CUDNN_PATCH=$(grep -E '^#define CUDNN_PATCHLEVEL' /usr/include/cudnn_version.h | awk '{print $3}')
    echo "cuDNN version: ${CUDNN_MAJOR}.${CUDNN_MINOR}.${CUDNN_PATCH}"
else
    CUDNN_LINE=$(dpkg -l | awk '/libcudnn[0-9]+/{print $2" " $3; exit}')
    if [[ -n "${CUDNN_LINE:-}" ]]; then
        echo "cuDNN version (from dpkg): ${CUDNN_LINE}"
    else
        echo "cuDNN version: N/A (header or package not found)"
    fi
fi

# --- TensorRT ---
TRT_VER=""
if dpkg-query -W tensorrt >/dev/null 2>&1; then
    TRT_VER=$(dpkg-query -W -f='${Version}\n' tensorrt)
else
    TRT_VER=$(dpkg -l | awk '/libnvinfer[0-9]+/{print $2" " $3; exit}')
fi

if [[ -n "${TRT_VER:-}" ]]; then
    echo "TensorRT version: ${TRT_VER}"
else
    echo "TensorRT version: N/A (tensorrt / libnvinfer pkg not found)"
fi

# --- OpenGL ---
if have_cmd glxinfo; then
    # 嘗試用現在的 DISPLAY，失敗也不要讓腳本退出
    if GLX_OUT=$(glxinfo 2>/dev/null); then
        GL_VER=$(printf '%s\n' "$GLX_OUT" | awk -F': ' '/OpenGL version string/{print $2; exit}')
        GLES_VER=$(printf '%s\n' "$GLX_OUT" | awk -F': ' '/OpenGL ES profile version string/{print $2; exit}')
        echo "OpenGL version: ${GL_VER:-N/A (no version string found)}"
        echo "OpenGL ES version: ${GLES_VER:-N/A (no ES profile version string found)}"
    else
        echo "OpenGL version: N/A (glxinfo failed，可能沒有圖形環境或 DISPLAY 未設定)"
        echo "OpenGL ES version: N/A (glxinfo failed，可能沒有圖形環境或 DISPLAY 未設定)"
    fi
else
    echo "OpenGL version: N/A (glxinfo not installed: sudo apt install -y mesa-utils)"
    echo "OpenGL ES version: N/A (glxinfo not installed: sudo apt install -y mesa-utils)"
fi

# --- Vulkan ---
if have_cmd vulkaninfo; then
    if VK_OUT=$(vulkaninfo 2>/dev/null); then
        VK_VER=$(printf '%s\n' "$VK_OUT" | awk -F'= ' '/apiVersion/{print $2; exit}')
        echo "Vulkan version: ${VK_VER:-N/A (no apiVersion found)}"
    else
        echo "Vulkan version: N/A (vulkaninfo failed，可能沒有驅動或 DISPLAY 未設定)"
    fi
else
    echo "Vulkan version: N/A (vulkaninfo not installed: sudo apt install -y vulkan-tools)"
fi

echo "====================================="
