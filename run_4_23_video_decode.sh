#!/usr/bin/env bash
set -euo pipefail

VIDEO_DIR="${VIDEO_DIR:-/mnt/nas_home/TEST FILE/Video Decode}"
LOCAL_VIDEO_DIR="${LOCAL_VIDEO_DIR:-${HOME}/4_23_video_decode_media}"
LOG_DIR="${LOG_DIR:-/tmp/video_decode_4_23_logs}"
PLAYER="${PLAYER:-nvgstplayer-1.0}"
INDEXES="${INDEXES:-01 02 03 04 05 06 07 08 09 10 11 12}"
SOURCE_MODE="${SOURCE_MODE:-}"
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

quote_cmd_arg() {
  printf "%q" "$1"
}

format_seconds() {
  local seconds="$1"

  if [[ -z "${seconds}" || "${seconds}" == "N/A" ]]; then
    echo "N/A"
    return
  fi

  awk -v total="${seconds}" 'BEGIN {
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

get_duration_seconds() {
  local file="$1"

  if ! command -v ffprobe >/dev/null 2>&1; then
    echo "N/A"
    return
  fi

  ffprobe -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "${file}" 2>/dev/null | awk 'NF && $1 > 0 { print $1; found=1; exit } END { if (!found) print "N/A" }'
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

select_source_mode() {
  local choice

  if [[ -n "${SOURCE_MODE}" ]]; then
    case "${SOURCE_MODE}" in
      local|nas|streaming) return 0 ;;
      *)
        echo "ERROR: unsupported SOURCE_MODE=${SOURCE_MODE}. Use local or streaming." >&2
        exit 1
        ;;
    esac
  fi

  if [[ ! -t 0 ]]; then
    SOURCE_MODE="local"
    echo "Non-interactive shell; defaulting source mode to local copy."
    return 0
  fi

  echo "Playback source mode:"
  echo "1) Copy selected NAS videos to local and play local files (recommended)"
  echo "2) Direct NAS streaming from ${VIDEO_DIR}"
  read -r -p "Select [1/2, default 1]: " choice

  case "${choice}" in
    2) SOURCE_MODE="streaming" ;;
    *) SOURCE_MODE="local" ;;
  esac
}

prepare_playback_files() {
  local i src dest src_size dest_size
  local -a prepared=()

  if [[ "${SOURCE_MODE}" == "nas" ]]; then
    SOURCE_MODE="streaming"
  fi

  if [[ "${SOURCE_MODE}" == "streaming" ]]; then
    PLAYLIST_FILES=("${NAS_PLAYLIST_FILES[@]}")
    return 0
  fi

  mkdir -p "${LOCAL_VIDEO_DIR}"
  echo "Copying selected videos to local directory: ${LOCAL_VIDEO_DIR}"

  for i in "${!NAS_PLAYLIST_FILES[@]}"; do
    src="${NAS_PLAYLIST_FILES[$i]}"
    dest="${LOCAL_VIDEO_DIR}/$(basename "${src}")"
    src_size="$(stat -c '%s' "${src}" 2>/dev/null || echo "")"
    dest_size="$(stat -c '%s' "${dest}" 2>/dev/null || echo "")"

    if [[ -s "${dest}" && -n "${src_size}" && "${src_size}" == "${dest_size}" ]]; then
      echo "Local file exists; skipping copy: ${dest}"
    else
      echo "Copying: ${src}"
      echo "     To: ${dest}"
      cp -f "${src}" "${dest}"
      sync "${dest}" || true
    fi
    prepared+=("${dest}")
  done

  PLAYLIST_FILES=("${prepared[@]}")
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
  local base log status interrupted duration duration_text start_ts now elapsed elapsed_text key player_pid action
  local player_input_fifo player_input_fd

  base="$(basename "${file}")"
  log="${LOG_DIR}/${index}_${base}.log"
  interrupted=0
  action="complete"
  PLAY_ACTION="complete"

  echo "=== Playing ${base} ==="
  duration="$(get_duration_seconds "${file}")"
  duration_text="$(format_seconds "${duration}")"
  echo "Duration: ${duration_text}"
  echo "Controls: n=next, p=previous, q=quit"
  if ! check_support_before_playback "${file}"; then
    PLAY_ACTION="complete"
    return 0
  fi
  echo "If the screen is black, stuck, or not playing correctly, press n or Ctrl+C to skip this file."
  printf 'Command: '
  quote_cmd_arg "${PLAYER}"
  printf ' -i '
  quote_cmd_arg "$(file_uri "${file}")"
  printf '\n'

  player_input_fifo="$(mktemp -u /tmp/4_23_nvgstplayer_input_XXXXXX)"
  mkfifo "${player_input_fifo}"
  exec {player_input_fd}<>"${player_input_fifo}"

  set +e
  "${PLAYER}" -i "$(file_uri "${file}")" >"${log}" 2>&1 <"${player_input_fifo}" &
  player_pid=$!
  start_ts="$(date +%s)"
  trap 'interrupted=1; action="next"; printf "q\n" >&'"${player_input_fd}"' 2>/dev/null || true; sleep 1; kill "${player_pid}" >/dev/null 2>&1 || true' INT

  while kill -0 "${player_pid}" >/dev/null 2>&1; do
    now="$(date +%s)"
    elapsed=$((now - start_ts))
    elapsed_text="$(format_seconds "${elapsed}")"
    printf '\rProgress: %s / %s' "${elapsed_text}" "${duration_text}"

    key=""
    if [[ -t 0 ]] && read -r -s -n 1 -t 1 key; then
      case "${key}" in
        n|N)
          action="next"
          printf 'q\n' >&"${player_input_fd}" 2>/dev/null || true
          sleep 1
          kill "${player_pid}" >/dev/null 2>&1 || true
          ;;
        p|P)
          action="previous"
          printf 'q\n' >&"${player_input_fd}" 2>/dev/null || true
          sleep 1
          kill "${player_pid}" >/dev/null 2>&1 || true
          ;;
        q|Q)
          action="quit"
          printf 'q\n' >&"${player_input_fd}" 2>/dev/null || true
          sleep 1
          kill "${player_pid}" >/dev/null 2>&1 || true
          ;;
      esac
    elif [[ ! -t 0 ]]; then
      sleep 1
    fi
  done

  wait "${player_pid}"
  status="$?"
  trap - INT
  exec {player_input_fd}>&-
  rm -f "${player_input_fifo}"
  set -e

  now="$(date +%s)"
  elapsed=$((now - start_ts))
  if [[ "${action}" == "complete" && "${duration}" != "N/A" ]]; then
    elapsed_text="$(format_seconds "${duration}")"
  else
    elapsed_text="$(format_seconds "${elapsed}")"
  fi
  printf '\rProgress: %s / %s\n' "${elapsed_text}" "${duration_text}"

  if [[ "${action}" == "next" ]]; then
    PLAY_ACTION="next"
    printf '%sSKIP: %s%s\n' "${COLOR_WARN}" "${base}" "${COLOR_RESET}"
    printf 'RESULT,Video Decode,%s,SKIP\n' "${base}"
    echo "Log: ${log}"
    echo
    return 0
  fi

  if [[ "${action}" == "previous" ]]; then
    PLAY_ACTION="previous"
    echo "Back to previous."
    echo "Log: ${log}"
    echo
    return 0
  fi

  if [[ "${action}" == "quit" ]]; then
    PLAY_ACTION="quit"
    echo "Quit requested."
    echo "Log: ${log}"
    echo
    return 0
  fi

  if [[ "${interrupted}" -eq 1 || "${status}" -eq 130 ]]; then
    PLAY_ACTION="next"
    printf '%sSKIP: %s%s\n' "${COLOR_WARN}" "${base}" "${COLOR_RESET}"
    printf 'RESULT,Video Decode,%s,SKIP\n' "${base}"
    echo "Log: ${log}"
    echo
    return 0
  fi

  if [[ "${status}" -eq 0 ]]; then
    PLAY_ACTION="complete"
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

  if prompt_continue; then
    PLAY_ACTION="complete"
    return 0
  fi
  return 1
}

echo "4.23 Video Decode test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Video directory: ${VIDEO_DIR}"
echo "Local video directory: ${LOCAL_VIDEO_DIR}"
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

declare -a NAS_PLAYLIST_FILES=()
declare -a PLAYLIST_FILES=()
declare -a PLAYLIST_INDEXES=()
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

  NAS_PLAYLIST_FILES+=("${matches[0]}")
  PLAYLIST_INDEXES+=("${index}")
done

select_source_mode
prepare_playback_files

echo "Source mode: ${SOURCE_MODE}"
echo "Playback files: ${#PLAYLIST_FILES[@]}"
echo

current_index=0
while [[ "${current_index}" -lt "${#PLAYLIST_FILES[@]}" ]]; do
  PLAY_ACTION="complete"
  if ! play_file "${PLAYLIST_FILES[${current_index}]}" "${PLAYLIST_INDEXES[${current_index}]}"; then
    exit 1
  fi

  case "${PLAY_ACTION}" in
    complete|next)
      current_index=$((current_index + 1))
      ;;
    previous)
      if [[ "${current_index}" -gt 0 ]]; then
        current_index=$((current_index - 1))
      else
        current_index=0
      fi
      ;;
    quit)
      break
      ;;
    *)
      echo "ERROR: Unknown playback action: ${PLAY_ACTION}" >&2
      exit 1
      ;;
  esac
done

echo "Summary"
echo "-------"
if [[ "${current_index}" -ge "${#PLAYLIST_FILES[@]}" ]]; then
  echo "RESULT,Video Decode,${INDEXES},COMPLETE"
else
  echo "RESULT,Video Decode,${INDEXES},STOPPED"
fi
echo "Logs: ${LOG_DIR}"
