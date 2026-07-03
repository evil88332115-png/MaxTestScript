#!/usr/bin/env bash
set -euo pipefail

MEDIA_DIR="${MEDIA_DIR:-/mnt/nas_home/TEST FILE/Reader Container Formats}"
LOG_DIR="${LOG_DIR:-/tmp/reader_container_4_24_logs}"
PLAYER="${PLAYER:-nvgstplayer-1.0}"
INDEXES="${INDEXES:-01 02 03 04 05 06 07 08 09 10}"
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

probe_video_codec() {
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | head -n 1 || true
}

probe_audio_codec() {
  ffprobe -v error -select_streams a:0 \
    -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | head -n 1 || true
}

probe_format() {
  ffprobe -v error \
    -show_entries format=format_name \
    -of default=noprint_wrappers=1:nokey=1 "$1" 2>/dev/null | head -n 1 || true
}

get_parser() {
  local codec="$1"
  case "${codec}" in
    h264) echo "h264parse" ;;
    hevc|h265) echo "h265parse" ;;
    vp9) gst-inspect-1.0 vp9parse >/dev/null 2>&1 && echo "vp9parse" || echo "" ;;
    vp8) gst-inspect-1.0 vp8parse >/dev/null 2>&1 && echo "vp8parse" || echo "" ;;
    av1) gst-inspect-1.0 av1parse >/dev/null 2>&1 && echo "av1parse" || echo "" ;;
    mpeg2video|mpeg1video) echo "mpegvideoparse" ;;
    mpeg4) gst-inspect-1.0 mpeg4videoparse >/dev/null 2>&1 && echo "mpeg4videoparse" || echo "" ;;
    h263) gst-inspect-1.0 h263parse >/dev/null 2>&1 && echo "h263parse" || echo "" ;;
    *) echo "" ;;
  esac
}

get_demux() {
  local file="$1"
  local format="${2:-}"
  local lower

  lower="$(echo "${file}" | tr '[:upper:]' '[:lower:]')"
  if echo "${format}" | grep -qiE 'mpegts'; then
    echo "tsdemux"
    return
  elif echo "${format}" | grep -qiE 'matroska|webm'; then
    echo "matroskademux"
    return
  elif echo "${format}" | grep -qiE 'mov|mp4|m4a|3gp|3g2|mj2'; then
    echo "qtdemux"
    return
  elif echo "${format}" | grep -qiE 'avi'; then
    echo "avidemux"
    return
  elif echo "${format}" | grep -qiE 'mpeg'; then
    echo "mpegpsdemux"
    return
  elif echo "${format}" | grep -qiE 'ogg'; then
    echo "oggdemux"
    return
  fi

  case "${lower}" in
    *.h265|*.265|*.hevc|*.h264|*.264|*.avc) echo "raw" ;;
    *.mp4|*.m4v|*.mov|*.3gp) echo "qtdemux" ;;
    *.mkv|*.webm) echo "matroskademux" ;;
    *.m2ts|*.mts|*.ts) echo "tsdemux" ;;
    *.mpg|*.mpeg) echo "mpegpsdemux" ;;
    *.avi|*.divx) echo "avidemux" ;;
    *.ogg|*.ogv) echo "oggdemux" ;;
    *) echo "" ;;
  esac
}

jetson_hw_supported_codec() {
  case "$1" in
    h264|hevc|h265|vp9|av1) return 0 ;;
    *) return 1 ;;
  esac
}

audio_supported_for_demux() {
  case "$1" in
    qtdemux|matroskademux) return 0 ;;
    *) return 1 ;;
  esac
}

get_video_sink() {
  if gst-inspect-1.0 nv3dsink >/dev/null 2>&1; then
    echo "nv3dsink sync=true"
  else
    echo "autovideosink"
  fi
}

print_command_array() {
  local arg
  printf 'Command: '
  for arg in "$@"; do
    if [[ "${arg}" == "gst-launch-1.0" ]]; then
      printf '%s' "${COLOR_RESULT}"
      quote_cmd_arg "${arg}"
      printf '%s' "${COLOR_RESET}"
    else
      quote_cmd_arg "${arg}"
    fi
    printf ' '
  done
  printf '\n'
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
    printf 'RESULT,Reader Container,%s,PRECHECK_UNSUPPORTED,%s,%s\n' "${base}" "${codec}" "${pix_fmt}"
    if prompt_play_unsupported; then
      return 0
    fi
    printf '%sSKIP: %s%s\n' "${COLOR_WARN}" "${base}" "${COLOR_RESET}"
    printf 'RESULT,Reader Container,%s,SKIP_UNSUPPORTED\n' "${base}"
    echo
    return 1
  fi

  return 0
}

run_controlled_command() {
  local log="$1"
  local duration="$2"
  local duration_text="$3"
  shift 3
  local cmd_pid start_ts now elapsed elapsed_text key action status

  action="complete"
  "$@" >"${log}" 2>&1 &
  cmd_pid=$!
  start_ts="$(date +%s)"
  trap 'action="next"; kill -INT "${cmd_pid}" >/dev/null 2>&1 || true; sleep 1; kill "${cmd_pid}" >/dev/null 2>&1 || true' INT

  while kill -0 "${cmd_pid}" >/dev/null 2>&1; do
    now="$(date +%s)"
    elapsed=$((now - start_ts))
    elapsed_text="$(format_seconds "${elapsed}")"
    printf '\rProgress: %s / %s' "${elapsed_text}" "${duration_text}"

    key=""
    if [[ -t 0 ]] && read -r -s -n 1 -t 1 key; then
      case "${key}" in
        n|N)
          action="next"
          kill -INT "${cmd_pid}" >/dev/null 2>&1 || true
          sleep 1
          kill "${cmd_pid}" >/dev/null 2>&1 || true
          ;;
        p|P)
          action="previous"
          kill -INT "${cmd_pid}" >/dev/null 2>&1 || true
          sleep 1
          kill "${cmd_pid}" >/dev/null 2>&1 || true
          ;;
        q|Q)
          action="quit"
          kill -INT "${cmd_pid}" >/dev/null 2>&1 || true
          sleep 1
          kill "${cmd_pid}" >/dev/null 2>&1 || true
          ;;
      esac
    elif [[ ! -t 0 ]]; then
      sleep 1
    fi
  done

  wait "${cmd_pid}"
  status="$?"
  trap - INT

  now="$(date +%s)"
  elapsed=$((now - start_ts))
  if [[ "${action}" == "complete" && "${duration}" != "N/A" ]]; then
    elapsed_text="$(format_seconds "${duration}")"
  else
    elapsed_text="$(format_seconds "${elapsed}")"
  fi
  printf '\rProgress: %s / %s\n' "${elapsed_text}" "${duration_text}"

  FALLBACK_ACTION="${action}"
  return "${status}"
}

try_general_hw_decode() {
  local file="$1"
  local index="$2"
  local base="$3"
  local duration="$4"
  local duration_text="$5"
  local log="${LOG_DIR}/${index}_${base}.general_hw.log"
  local video_codec audio_codec format parser demux sink abs_path status
  local cmd=()

  if ! command -v gst-launch-1.0 >/dev/null 2>&1 || ! command -v gst-inspect-1.0 >/dev/null 2>&1; then
    echo "General HW decode fallback unavailable: gst-launch-1.0 or gst-inspect-1.0 not found."
    return 1
  fi

  video_codec="$(probe_video_codec "${file}")"
  audio_codec="$(probe_audio_codec "${file}")"
  format="$(probe_format "${file}")"
  parser="$(get_parser "${video_codec}")"
  demux="$(get_demux "${file}" "${format}")"
  sink="$(get_video_sink)"

  printf '%snvgstplayer failed. Trying general decode fallback.%s\n' "${COLOR_WARN}" "${COLOR_RESET}"
  printf 'Playback mode: %snot nvgstplayer%s; %sgeneral hardware decode when supported%s.\n' \
    "${COLOR_RESULT}" "${COLOR_RESET}" "${COLOR_RESULT}" "${COLOR_RESET}"
  echo "Detected: video=${video_codec:-unknown}, audio=${audio_codec:-none}, format=${format:-unknown}, demux=${demux:-unknown}"

  if [[ -n "${parser}" && -n "${demux}" ]] && jetson_hw_supported_codec "${video_codec}"; then
    echo "General HW pipeline: ${demux} -> ${parser} -> nvv4l2decoder -> nvvidconv -> ${sink}"
    case "${demux}" in
      raw)
        cmd=(gst-launch-1.0 -e filesrc "location=${file}" ! "${parser}" ! nvv4l2decoder ! nvvidconv ! ${sink})
        ;;
      tsdemux|mpegpsdemux|avidemux|oggdemux)
        cmd=(gst-launch-1.0 -e filesrc "location=${file}" ! "${demux}" name=demux demux. ! queue ! "${parser}" ! nvv4l2decoder ! nvvidconv ! ${sink})
        ;;
      *)
        if [[ -n "${audio_codec}" && "${ENABLE_AUDIO:-true}" == "true" ]] && audio_supported_for_demux "${demux}"; then
          cmd=(gst-launch-1.0 -e filesrc "location=${file}" ! "${demux}" name=demux demux.video_0 ! queue ! "${parser}" ! nvv4l2decoder ! nvvidconv ! ${sink} demux.audio_0 ! queue ! decodebin ! audioconvert ! audioresample ! autoaudiosink)
        else
          cmd=(gst-launch-1.0 -e filesrc "location=${file}" ! "${demux}" name=demux demux.video_0 ! queue ! "${parser}" ! nvv4l2decoder ! nvvidconv ! ${sink})
        fi
        ;;
    esac
  else
    abs_path="$(realpath "${file}" 2>/dev/null || printf '%s' "${file}")"
    echo "General HW fixed pipeline not available for codec/container; using GStreamer playbin fallback."
    echo "Note: playbin may still use available acceleration automatically."
    cmd=(gst-launch-1.0 playbin "uri=file://${abs_path}")
  fi

  print_command_array "${cmd[@]}"
  set +e
  run_controlled_command "${log}" "${duration}" "${duration_text}" "${cmd[@]}"
  status="$?"
  set -e

  case "${FALLBACK_ACTION}" in
    next)
      PLAY_ACTION="next"
      printf '%sSKIP: %s%s\n' "${COLOR_WARN}" "${base}" "${COLOR_RESET}"
      printf 'RESULT,Reader Container,%s,SKIP,general_hw\n' "${base}"
      echo "Log: ${log}"
      echo
      return 0
      ;;
    previous)
      PLAY_ACTION="previous"
      echo "Back to previous."
      echo "Log: ${log}"
      echo
      return 0
      ;;
    quit)
      PLAY_ACTION="quit"
      echo "Quit requested."
      echo "Log: ${log}"
      echo
      return 0
      ;;
  esac

  if [[ "${status}" -eq 0 ]]; then
    PLAY_ACTION="complete"
    printf '%sRESULT,Reader Container,%s,PASS,general_hw%s\n' "${COLOR_RESULT}" "${base}" "${COLOR_RESET}"
    echo "Log: ${log}"
    echo
    return 0
  fi

  echo "General decode fallback failed. Last log lines:" >&2
  tail -n 80 "${log}" >&2 || true
  printf 'RESULT,Reader Container,%s,FAIL,general_hw\n' "${base}"
  return 1
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

  player_input_fifo="$(mktemp -u /tmp/4_24_nvgstplayer_input_XXXXXX)"
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
    printf 'RESULT,Reader Container,%s,SKIP\n' "${base}"
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
    printf 'RESULT,Reader Container,%s,SKIP\n' "${base}"
    echo "Log: ${log}"
    echo
    return 0
  fi

  if [[ "${status}" -eq 0 ]]; then
    PLAY_ACTION="complete"
    printf '%sRESULT,Reader Container,%s,PASS%s\n' "${COLOR_RESULT}" "${base}" "${COLOR_RESET}"
    echo "Log: ${log}"
    echo
    return 0
  fi

  printf '%sERROR: Playback failed: %s%s\n' "${COLOR_ERROR}" "${base}" "${COLOR_RESET}" >&2
  printf '%sLOG: %s%s\n' "${COLOR_WARN}" "${log}" "${COLOR_RESET}" >&2
  echo "----- LOG START -----" >&2
  cat "${log}" >&2
  echo "----- LOG END -----" >&2
  printf 'RESULT,Reader Container,%s,FAIL\n' "${base}"
  echo

  if try_general_hw_decode "${file}" "${index}" "${base}" "${duration}" "${duration_text}"; then
    return 0
  fi

  if prompt_continue; then
    PLAY_ACTION="complete"
    return 0
  fi
  return 1
}

echo "4.24 Reader Container Formats test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Media directory: ${MEDIA_DIR}"
echo "Log directory: ${LOG_DIR}"
setup_display
echo "DISPLAY: ${DISPLAY}"
echo "XAUTHORITY: ${XAUTHORITY:-not set}"
echo

if [[ ! -d "${MEDIA_DIR}" ]]; then
  echo "ERROR: Media directory not found: ${MEDIA_DIR}" >&2
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

declare -a PLAYLIST_FILES=()
declare -a PLAYLIST_INDEXES=()
for index in ${INDEXES}; do
  mapfile -t matches < <(find "${MEDIA_DIR}" -maxdepth 1 -type f -name "TestFile_${index}.*" | sort)

  if [[ "${#matches[@]}" -eq 0 ]]; then
    printf '%sERROR: Missing media file TestFile_%s.* in %s%s\n' "${COLOR_ERROR}" "${index}" "${MEDIA_DIR}" "${COLOR_RESET}" >&2
    if prompt_continue; then
      continue
    fi
    exit 1
  fi
  if [[ "${#matches[@]}" -gt 1 ]]; then
    printf '%sERROR: Multiple media files matched TestFile_%s.*:%s\n' "${COLOR_ERROR}" "${index}" "${COLOR_RESET}" >&2
    printf '  %s\n' "${matches[@]}" >&2
    if prompt_continue; then
      continue
    fi
    exit 1
  fi

  PLAYLIST_FILES+=("${matches[0]}")
  PLAYLIST_INDEXES+=("${index}")
done

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
  echo "RESULT,Reader Container,${INDEXES},COMPLETE"
else
  echo "RESULT,Reader Container,${INDEXES},STOPPED"
fi
echo "Logs: ${LOG_DIR}"
