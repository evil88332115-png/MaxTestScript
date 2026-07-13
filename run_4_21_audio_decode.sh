#!/usr/bin/env bash
set -euo pipefail

AUDIO_DIR="${AUDIO_DIR:-/mnt/nas_home/TEST FILE/Audio Decode}"
LOCAL_AUDIO_DIR="${LOCAL_AUDIO_DIR:-${HOME}/4_21_audio_decode_media}"
SOURCE_MODE="${SOURCE_MODE:-}"

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

find_player() {
  if command -v ffplay >/dev/null 2>&1; then
    PLAYER="ffplay"
    return 0
  fi
  if command -v gst-play-1.0 >/dev/null 2>&1; then
    PLAYER="gst-play-1.0"
    return 0
  fi
  if command -v cvlc >/dev/null 2>&1; then
    PLAYER="cvlc"
    return 0
  fi

  echo "ERROR: No supported audio player found. Install ffmpeg, gstreamer1.0-tools, or vlc." >&2
  exit 1
}

print_command() {
  printf 'Command:'
  printf ' %q' "$@"
  echo
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
  echo "2) Direct NAS streaming from ${AUDIO_DIR}"
  read -r -p "Select [1/2, default 1]: " choice

  case "${choice}" in
    2) SOURCE_MODE="streaming" ;;
    *) SOURCE_MODE="local" ;;
  esac
}

prepare_playback_files() {
  local src dest src_size dest_size
  local -a prepared=()

  if [[ "${SOURCE_MODE}" == "nas" ]]; then
    SOURCE_MODE="streaming"
  fi

  if [[ "${SOURCE_MODE}" == "streaming" ]]; then
    PLAYLIST=("${NAS_PLAYLIST[@]}")
    return 0
  fi

  mkdir -p "${LOCAL_AUDIO_DIR}"
  echo "Copying selected files to local directory: ${LOCAL_AUDIO_DIR}"

  for src in "${NAS_PLAYLIST[@]}"; do
    dest="${LOCAL_AUDIO_DIR}/$(basename "${src}")"
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

  PLAYLIST=("${prepared[@]}")
}

play_file() {
  local file="$1"
  local duration duration_text start_ts now elapsed elapsed_text rc log_file player_pid key action
  local -a command

  echo "=== Playing $(basename "${file}") ==="
  duration="$(get_duration_seconds "${file}")"
  duration_text="$(format_seconds "${duration}")"
  echo "Duration: ${duration_text}"
  echo "Controls: n=next, p=previous, q=quit"

  log_file="$(mktemp /tmp/4_21_audio_decode_XXXXXX.log)"
  case "${PLAYER}" in
    ffplay)
      command=(ffplay -nodisp -autoexit -hide_banner -loglevel warning "${file}")
      ;;
    gst-play-1.0)
      command=(gst-play-1.0 "${file}")
      ;;
    cvlc)
      command=(cvlc --play-and-exit "${file}")
      ;;
    *)
      echo "ERROR: Unsupported player: ${PLAYER}" >&2
      exit 1
      ;;
  esac
  print_command "${command[@]}"
  "${command[@]}" >"${log_file}" 2>&1 </dev/null &
  player_pid=$!
  start_ts="$(date +%s)"
  action="complete"

  while kill -0 "${player_pid}" >/dev/null 2>&1; do
    now="$(date +%s)"
    elapsed=$((now - start_ts))
    elapsed_text="$(format_seconds "${elapsed}")"
    printf '\rProgress: %s / %s' "${elapsed_text}" "${duration_text}"
    key=""
    if read -r -s -n 1 -t 1 key; then
      case "${key}" in
        n|N)
          action="next"
          kill "${player_pid}" >/dev/null 2>&1 || true
          ;;
        p|P)
          action="previous"
          kill "${player_pid}" >/dev/null 2>&1 || true
          ;;
        q|Q)
          action="quit"
          kill "${player_pid}" >/dev/null 2>&1 || true
          ;;
      esac
    fi
  done

  set +e
  wait "${player_pid}"
  rc=$?
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
    echo "Skip to next."
    rm -f "${log_file}"
    PLAY_ACTION="next"
    return 0
  fi
  if [[ "${action}" == "previous" ]]; then
    echo "Back to previous."
    rm -f "${log_file}"
    PLAY_ACTION="previous"
    return 0
  fi
  if [[ "${action}" == "quit" ]]; then
    echo "Quit requested."
    rm -f "${log_file}"
    PLAY_ACTION="quit"
    return 0
  fi

  if [[ "${rc}" -ne 0 ]]; then
    echo "ERROR: Playback failed: $(basename "${file}")" >&2
    echo "Last player log lines:" >&2
    tail -n 20 "${log_file}" >&2 || true
    rm -f "${log_file}"
    exit "${rc}"
  fi

  rm -f "${log_file}"
  PLAY_ACTION="complete"
  echo "RESULT,Audio Decode,$(basename "${file}"),PASS"
  echo
}

echo "4.21 Audio Decode test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Audio directory: ${AUDIO_DIR}"
echo "Local audio directory: ${LOCAL_AUDIO_DIR}"
echo

if [[ ! -d "${AUDIO_DIR}" ]]; then
  echo "ERROR: Audio directory not found: ${AUDIO_DIR}" >&2
  echo "Please mount NAS first, for example: /home/p/run_0_mount_nas.sh" >&2
  exit 1
fi

find_player
echo "Player: ${PLAYER}"
echo

declare -a NAS_PLAYLIST=()
declare -a PLAYLIST=()
for index in 01 02 03 04 05 06 07 08; do
  mapfile -t matches < <(find "${AUDIO_DIR}" -maxdepth 1 -type f -name "TestFile_${index}_*" | sort)

  if [[ "${#matches[@]}" -eq 0 ]]; then
    echo "ERROR: Missing audio file TestFile_${index}_* in ${AUDIO_DIR}" >&2
    exit 1
  fi
  if [[ "${#matches[@]}" -gt 1 ]]; then
    echo "ERROR: Multiple audio files matched TestFile_${index}_*:" >&2
    printf '  %s\n' "${matches[@]}" >&2
    exit 1
  fi

  NAS_PLAYLIST+=("${matches[0]}")
done

select_source_mode
prepare_playback_files

echo "Source mode: ${SOURCE_MODE}"
echo "Playback files: ${#PLAYLIST[@]}"
echo

current_index=0
while [[ "${current_index}" -lt "${#PLAYLIST[@]}" ]]; do
  PLAY_ACTION="complete"
  set +e
  play_file "${PLAYLIST[${current_index}]}"
  play_rc=$?
  set -e

  if [[ "${play_rc}" -ne 0 ]]; then
    exit "${play_rc}"
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
if [[ "${current_index}" -ge "${#PLAYLIST[@]}" ]]; then
  echo "RESULT,Audio Decode,01-08,COMPLETE"
else
  echo "RESULT,Audio Decode,01-08,STOPPED"
fi
