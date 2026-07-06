#!/usr/bin/env bash
set -u

MEDIA_DIR="${MEDIA_DIR:-/mnt/nas_home/TEST FILE/video bit rate}"
LOCAL_MEDIA_DIR="${LOCAL_MEDIA_DIR:-${HOME}/5_8_video_bit_rate_media}"
LOG_DIR="${LOG_DIR:-/tmp/video_bit_rate_5_8_logs}"
PLAYER="${PLAYER:-nvgstplayer-1.0}"
INDEXES="${INDEXES:-}"
SOURCE_MODE="${SOURCE_MODE:-}"
export DISPLAY="${DISPLAY:-:0}"

if [[ -t 1 ]]; then
  COLOR_ERROR=$'\033[1;31m'
  COLOR_RESULT=$'\033[1;32m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_ERROR=""
  COLOR_RESULT=""
  COLOR_RESET=""
fi

file_uri() {
  printf 'file://%s' "$1"
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

run_player() {
  local uri="$1"
  local log="$2"

  if [[ -t 0 ]]; then
    "${PLAYER}" -i "${uri}" >"${log}" 2>&1
  else
    tail -f /dev/null | "${PLAYER}" -i "${uri}" >"${log}" 2>&1
    return "${PIPESTATUS[1]}"
  fi
}

probe_video() {
  local file="$1"

  if ! command -v ffprobe >/dev/null 2>&1; then
    printf 'unknown|?|?|unknown|unknown\n'
    return
  fi

  local codec width height fps stream_bitrate format_bitrate bitrate duration file_size
  codec="$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name -of default=nw=1:nk=1 "${file}" 2>/dev/null | head -n 1)"
  width="$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width -of default=nw=1:nk=1 "${file}" 2>/dev/null | head -n 1)"
  height="$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=height -of default=nw=1:nk=1 "${file}" 2>/dev/null | head -n 1)"
  fps="$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=avg_frame_rate -of default=nw=1:nk=1 "${file}" 2>/dev/null | head -n 1)"
  stream_bitrate="$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=bit_rate -of default=nw=1:nk=1 "${file}" 2>/dev/null | head -n 1)"
  format_bitrate="$(ffprobe -v error \
    -show_entries format=bit_rate -of default=nw=1:nk=1 "${file}" 2>/dev/null | head -n 1)"
  duration="$(ffprobe -v error \
    -show_entries format=duration -of default=nw=1:nk=1 "${file}" 2>/dev/null | head -n 1)"
  file_size="$(stat -c '%s' "${file}" 2>/dev/null || true)"

  if [[ "${stream_bitrate}" =~ ^[0-9]+$ ]]; then
    bitrate="$(awk -v value="${stream_bitrate}" 'BEGIN { printf "%.2f Mbps", value / 1000000 }')"
  elif [[ "${format_bitrate}" =~ ^[0-9]+$ ]]; then
    bitrate="$(awk -v value="${format_bitrate}" 'BEGIN { printf "%.2f Mbps", value / 1000000 }')"
  elif [[ "${file_size}" =~ ^[0-9]+$ ]] && awk -v value="${duration}" 'BEGIN { exit !(value > 0) }'; then
    bitrate="$(awk -v bytes="${file_size}" -v seconds="${duration}" \
      'BEGIN { printf "%.2f Mbps (calculated)", bytes * 8 / seconds / 1000000 }')"
  else
    bitrate="unknown"
  fi

  if [[ "${fps}" == */* ]]; then
    fps="$(awk -F/ '{ if ($2 > 0) printf "%.3f", $1 / $2; else print "unknown" }' <<<"${fps}")"
  fi

  printf '%s|%s|%s|%s|%s\n' \
    "${codec:-unknown}" "${width:-?}" "${height:-?}" "${fps:-unknown}" "${bitrate}"
}

find_files() {
  local pattern

  if [[ -n "${INDEXES}" ]]; then
    for pattern in ${INDEXES}; do
      find "${MEDIA_DIR}" -maxdepth 1 -type f -iname "*${pattern}*"
    done | sort -V | awk '!seen[$0]++'
  else
    find "${MEDIA_DIR}" -maxdepth 1 -type f \( \
      -iname '*.mp4' -o \
      -iname '*.mkv' -o \
      -iname '*.mov' -o \
      -iname '*.avi' -o \
      -iname '*.ts' -o \
      -iname '*.m2ts' -o \
      -iname '*.mts' -o \
      -iname '*.webm' -o \
      -iname '*.h264' -o \
      -iname '*.264' -o \
      -iname '*.h265' -o \
      -iname '*.265' -o \
      -iname '*.hevc' \
    \) | sort -V
  fi
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
  echo "2) Direct NAS streaming from ${MEDIA_DIR}"
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
    FILES=("${NAS_FILES[@]}")
    return 0
  fi

  mkdir -p "${LOCAL_MEDIA_DIR}"
  echo "Copying selected videos to local directory: ${LOCAL_MEDIA_DIR}"

  for src in "${NAS_FILES[@]}"; do
    dest="${LOCAL_MEDIA_DIR}/$(basename "${src}")"
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

  FILES=("${prepared[@]}")
}

echo "5.8 Video Bit Rate test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Media directory: ${MEDIA_DIR}"
echo "Local media directory: ${LOCAL_MEDIA_DIR}"
echo "Player: ${PLAYER} -i"
echo "Playback: full file, then automatically continue"
setup_display
echo "DISPLAY: ${DISPLAY}"
echo "XAUTHORITY: ${XAUTHORITY:-not set}"
echo

if [[ ! -d "${MEDIA_DIR}" ]]; then
  echo "ERROR: Media directory not found: ${MEDIA_DIR}" >&2
  exit 1
fi

if ! command -v "${PLAYER}" >/dev/null 2>&1; then
  echo "ERROR: ${PLAYER} not found." >&2
  exit 1
fi

mkdir -p "${LOG_DIR}"
SUMMARY="${LOG_DIR}/summary.csv"
printf 'index,file,codec,resolution,source_fps,bitrate,status,exit_code,log\n' >"${SUMMARY}"

mapfile -t NAS_FILES < <(find_files)
if [[ "${#NAS_FILES[@]}" -eq 0 ]]; then
  echo "ERROR: No video files found in ${MEDIA_DIR}" >&2
  exit 1
fi

select_source_mode
prepare_playback_files

echo "Source mode: ${SOURCE_MODE}"
echo "Playback files: ${#FILES[@]}"
echo

pass=0
fail=0

for i in "${!FILES[@]}"; do
  file="${FILES[$i]}"
  number="$((i + 1))"
  base="$(basename "${file}")"
  log="${LOG_DIR}/${number}_${base}.log"
  IFS='|' read -r codec width height fps bitrate < <(probe_video "${file}")
  uri="$(file_uri "${file}")"

  echo "======================================"
  echo "Playing #${number}/${#FILES[@]}: ${base}"
  echo "Codec: ${codec}"
  echo "Resolution: ${width}x${height}"
  echo "Source FPS: ${fps}"
  echo "Bit rate: ${bitrate}"
  printf 'Command: %q -i %q\n' "${PLAYER}" "${uri}"
  echo "======================================"

  run_player "${uri}" "${log}"
  rc="$?"

  if [[ "${rc}" -eq 0 ]]; then
    status="PASS"
    pass="$((pass + 1))"
    printf '%sRESULT,VIDEO_BIT_RATE,%s,PASS%s\n' \
      "${COLOR_RESULT}" "${base}" "${COLOR_RESET}"
  else
    status="FAIL"
    fail="$((fail + 1))"
    printf '%sRESULT,VIDEO_BIT_RATE,%s,FAIL,rc=%s%s\n' \
      "${COLOR_ERROR}" "${base}" "${rc}" "${COLOR_RESET}" >&2
    tail -n 40 "${log}" >&2 || true
  fi

  printf '"%s","%s","%s","%sx%s","%s","%s","%s","%s","%s"\n' \
    "${number}" "${base//\"/\"\"}" "${codec}" "${width}" "${height}" \
    "${fps}" "${bitrate}" "${status}" "${rc}" "${log}" >>"${SUMMARY}"
  echo
done

echo "5.8 Video Bit Rate summary"
echo "Files: ${#FILES[@]}"
echo "Source mode: ${SOURCE_MODE}"
echo "PASS: ${pass}"
echo "FAIL: ${fail}"
echo "CSV: ${SUMMARY}"

if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
