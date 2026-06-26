#!/usr/bin/env bash
set -euo pipefail

VIDEO_DIR="${VIDEO_DIR:-/mnt/nas_home/TEST FILE/Video Decode}"
LOG_DIR="${LOG_DIR:-/tmp/video_decode_4_23_logs}"
PLAYER="${PLAYER:-nvgstplayer-1.0}"
INDEXES="${INDEXES:-01 02 03 04 05 06 07 08 09 10 11 12}"
DISPLAY="${DISPLAY:-:0}"

if [[ -t 1 ]]; then
  COLOR_ERROR=$'\033[1;31m'
  COLOR_WARN=$'\033[1;33m'
  COLOR_RESULT=$'\033[1;32m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_ERROR=""
  COLOR_WARN=""
  COLOR_RESULT=""
  COLOR_RESET=""
fi

file_uri() {
  local path="$1"
  printf 'file://%s' "${path}"
}

setup_display() {
  local uid xauth

  export DISPLAY

  if [[ -z "${XAUTHORITY:-}" ]]; then
    uid="$(id -u)"
    for xauth in \
      "${HOME}/.Xauthority" \
      "/run/user/${uid}/gdm/Xauthority" \
      "/run/user/${uid}/Xauthority"; do
      if [[ -r "${xauth}" ]]; then
        export XAUTHORITY="${xauth}"
        break
      fi
    done
  fi
}

prompt_continue() {
  local answer

  if [[ ! -t 0 ]]; then
    echo "Non-interactive shell; stopping after playback failure."
    return 1
  fi

  while true; do
    read -r -p "Continue to next file? [y/N] " answer
    case "${answer}" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO|"") return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

prompt_play_unsupported() {
  local answer

  if [[ ! -t 0 ]]; then
    echo "Non-interactive shell; skipping unsupported file."
    return 1
  fi

  while true; do
    read -r -p "This file may be unsupported. Play it anyway? [y/N] " answer
    case "${answer}" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO|"") return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

check_support_before_playback() {
  local file="$1"
  local base codec pix_fmt profile info

  base="$(basename "${file}")"

  if ! command -v ffprobe >/dev/null 2>&1; then
    echo "ffprobe not found; skipping pre-check for ${base}."
    return 0
  fi

  info="$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,pix_fmt,profile \
    -of default=noprint_wrappers=1:nokey=0 "${file}" 2>/dev/null || true)"
  codec="$(printf '%s\n' "${info}" | awk -F= '$1=="codec_name" { print $2; exit }')"
  profile="$(printf '%s\n' "${info}" | awk -F= '$1=="profile" { print $2; exit }')"
  pix_fmt="$(printf '%s\n' "${info}" | awk -F= '$1=="pix_fmt" { print $2; exit }')"

  echo "Pre-check: codec=${codec:-unknown}, profile=${profile:-unknown}, pix_fmt=${pix_fmt:-unknown}"

  if [[ "${codec}" == "mpeg2video" && "${pix_fmt}" != "yuv420p" ]]; then
    printf '%sWARNING: %s may not be supported by NVIDIA hardware decode: MPEG-2 %s (%s).%s\n' \
      "${COLOR_WARN}" "${base}" "${profile:-unknown profile}" "${pix_fmt:-unknown pix_fmt}" "${COLOR_RESET}"
    printf 'RESULT,Video Decode,%s,PRECHECK_UNSUPPORTED,%s,%s\n' "${base}" "${codec}" "${pix_fmt}"
    if prompt_play_unsupported; then
      return 0
    fi
    printf '%sSKIP: %s%s\n' "${COLOR_WARN}" "${base}" "${COLOR_RESET}"
    printf 'RESULT,Video Decode,%s,SKIP_UNSUPPORTED\n' "${base}"
    echo
    return 1
  fi

  return 0
}

play_file() {
  local file="$1"
  local index="$2"
  local base log status interrupted

  base="$(basename "${file}")"
  log="${LOG_DIR}/${index}_${base}.log"
  interrupted=0

  echo "=== Playing ${base} ==="
  if ! check_support_before_playback "${file}"; then
    return 0
  fi
  echo "If the screen is black, stuck, or not playing correctly, press Ctrl+C to skip this file and continue to the next one."
  set +e
  trap 'interrupted=1' INT
  if [[ -t 0 ]]; then
    "${PLAYER}" -i "$(file_uri "${file}")" >"${log}" 2>&1
    status="$?"
  else
    tail -f /dev/null | "${PLAYER}" -i "$(file_uri "${file}")" >"${log}" 2>&1
    status="${PIPESTATUS[1]}"
  fi
  trap - INT
  set -e

  if [[ "${interrupted}" -eq 1 || "${status}" -eq 130 ]]; then
    printf '%sSKIP: %s%s\n' "${COLOR_WARN}" "${base}" "${COLOR_RESET}"
    printf 'RESULT,Video Decode,%s,SKIP\n' "${base}"
    echo "Log: ${log}"
    echo
    return 0
  fi

  if [[ "${status}" -eq 0 ]]; then
    printf '%sRESULT,Video Decode,%s,PASS%s\n' "${COLOR_RESULT}" "${base}" "${COLOR_RESET}"
    echo "Log: ${log}"
    echo
    return 0
  fi

  printf '%sERROR: Video playback failed: %s%s\n' "${COLOR_ERROR}" "${base}" "${COLOR_RESET}" >&2
  printf '%sLOG: %s%s\n' "${COLOR_WARN}" "${log}" "${COLOR_RESET}" >&2
  echo "----- LOG START -----" >&2
  cat "${log}" >&2
  echo "----- LOG END -----" >&2
  printf 'RESULT,Video Decode,%s,FAIL\n' "${base}"
  echo

  prompt_continue
}

echo "4.23 Video Decode test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Video directory: ${VIDEO_DIR}"
echo "Log directory: ${LOG_DIR}"
setup_display
echo "DISPLAY: ${DISPLAY}"
echo "XAUTHORITY: ${XAUTHORITY:-not set}"
echo

if [[ ! -d "${VIDEO_DIR}" ]]; then
  echo "ERROR: Video directory not found: ${VIDEO_DIR}" >&2
  echo "Please mount NAS first, for example: /home/p/run_0_mount_nas.sh" >&2
  exit 1
fi

if ! command -v "${PLAYER}" >/dev/null 2>&1; then
  echo "ERROR: ${PLAYER} not found." >&2
  exit 1
fi

mkdir -p "${LOG_DIR}"
echo "Player: $(command -v "${PLAYER}")"
echo

for index in ${INDEXES}; do
  mapfile -t matches < <(find "${VIDEO_DIR}" -maxdepth 1 -type f -name "TestFile${index}_*" | sort)

  if [[ "${#matches[@]}" -eq 0 ]]; then
    printf '%sERROR: Missing video file TestFile%s_* in %s%s\n' "${COLOR_ERROR}" "${index}" "${VIDEO_DIR}" "${COLOR_RESET}" >&2
    if prompt_continue; then
      continue
    fi
    exit 1
  fi
  if [[ "${#matches[@]}" -gt 1 ]]; then
    printf '%sERROR: Multiple video files matched TestFile%s_*:%s\n' "${COLOR_ERROR}" "${index}" "${COLOR_RESET}" >&2
    printf '  %s\n' "${matches[@]}" >&2
    if prompt_continue; then
      continue
    fi
    exit 1
  fi

  if ! play_file "${matches[0]}" "${index}"; then
    exit 1
  fi
done

echo "Summary"
echo "-------"
echo "RESULT,Video Decode,${INDEXES},COMPLETE"
echo "Logs: ${LOG_DIR}"
