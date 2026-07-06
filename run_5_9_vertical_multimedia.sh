#!/usr/bin/env bash
set -u

MEDIA_DIR="${MEDIA_DIR:-/mnt/nas_home/TEST FILE/Vertical Multimedia 1080x1920}"
LOCAL_MEDIA_DIR="${LOCAL_MEDIA_DIR:-${HOME}/5_9_vertical_multimedia_media}"
LOG_DIR="${LOG_DIR:-/tmp/vertical_multimedia_5_9_logs}"
PLAYER="${PLAYER:-nvgstplayer-1.0}"
SOURCE_MODE="${SOURCE_MODE:-}"
SOURCE_ROOT="${MEDIA_DIR}"
export DISPLAY="${DISPLAY:-:0}"

if [[ -t 1 ]]; then
  COLOR_PASS=$'\033[1;32m'
  COLOR_FAIL=$'\033[1;31m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_PASS=""
  COLOR_FAIL=""
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
  local log="$1"
  shift

  if [[ -t 0 ]]; then
    "${PLAYER}" "$@" >"${log}" 2>&1
  else
    tail -f /dev/null | "${PLAYER}" "$@" >"${log}" 2>&1
    return "${PIPESTATUS[1]}"
  fi
}

probe_video() {
  local file="$1"

  if ! command -v ffprobe >/dev/null 2>&1; then
    printf 'unknown|?|?|unknown\n'
    return
  fi

  local codec width height fps
  codec="$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name -of default=nw=1:nk=1 "${file}" 2>/dev/null | head -n 1)"
  width="$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=width -of default=nw=1:nk=1 "${file}" 2>/dev/null | head -n 1)"
  height="$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=height -of default=nw=1:nk=1 "${file}" 2>/dev/null | head -n 1)"
  fps="$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=avg_frame_rate -of default=nw=1:nk=1 "${file}" 2>/dev/null | head -n 1)"

  if [[ "${fps}" == */* ]]; then
    fps="$(awk -F/ '{ if ($2 > 0) printf "%.3f", $1 / $2; else print "unknown" }' <<<"${fps}")"
  fi

  printf '%s|%s|%s|%s\n' \
    "${codec:-unknown}" "${width:-?}" "${height:-?}" "${fps:-unknown}"
}

find_files() {
  find "${MEDIA_DIR}" -type f \( \
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
  local src relative_path dest src_size dest_size
  local -a prepared=()

  if [[ "${SOURCE_MODE}" == "nas" ]]; then
    SOURCE_MODE="streaming"
  fi

  if [[ "${SOURCE_MODE}" == "streaming" ]]; then
    FILES=("${NAS_FILES[@]}")
    SOURCE_ROOT="${MEDIA_DIR}"
    return 0
  fi

  mkdir -p "${LOCAL_MEDIA_DIR}"
  echo "Copying selected videos to local directory: ${LOCAL_MEDIA_DIR}"

  for src in "${NAS_FILES[@]}"; do
    relative_path="${src#"${MEDIA_DIR}"/}"
    dest="${LOCAL_MEDIA_DIR}/${relative_path}"
    mkdir -p "$(dirname "${dest}")"
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
  SOURCE_ROOT="${LOCAL_MEDIA_DIR}"
}

run_playback() {
  local number="$1"
  local total="$2"
  local file="$3"
  local orientation="$4"
  local log="$5"
  local uri command_label rc
  uri="$(file_uri "${file}")"

  if [[ "${orientation}" == "normal" ]]; then
    command_label="Normal"
    echo "Playback: normal orientation"
    printf 'Command: %q -i %q\n' "${PLAYER}" "${uri}"
    run_player "${log}" -i "${uri}"
    rc="$?"
  else
    command_label="Clockwise 90"
    echo "Playback: clockwise 90 degrees"
    printf 'Command: %q --disable-vnative --svc=%q -i %q\n' \
      "${PLAYER}" "nvvidconv# flip-method=3" "${uri}"
    run_player "${log}" --disable-vnative \
      --svc="nvvidconv# flip-method=3" \
      -i "${uri}"
    rc="$?"
  fi

  if [[ "${rc}" -eq 0 ]]; then
    printf '%sRESULT,VERTICAL_MULTIMEDIA,%s/%s,%s,PASS%s\n' \
      "${COLOR_PASS}" "${number}" "${total}" "${command_label}" "${COLOR_RESET}"
    status="PASS"
    pass="$((pass + 1))"
  else
    printf '%sRESULT,VERTICAL_MULTIMEDIA,%s/%s,%s,FAIL,rc=%s%s\n' \
      "${COLOR_FAIL}" "${number}" "${total}" "${command_label}" "${rc}" "${COLOR_RESET}" >&2
    tail -n 40 "${log}" >&2 || true
    status="FAIL"
    fail="$((fail + 1))"
  fi

  printf '"%s","%s","%s","%s","%s","%s"\n' \
    "${number}" "${relative//\"/\"\"}" "${command_label}" "${status}" "${rc}" "${log}" \
    >>"${SUMMARY}"
}

echo "5.9 Vertical Multimedia 1080x1920"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Media directory: ${MEDIA_DIR}"
echo "Local media directory: ${LOCAL_MEDIA_DIR}"
echo "Search: recursive, including all subdirectories"
echo "Sequence: normal -> clockwise 90 degrees -> next file"
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
printf 'index,file,orientation,status,exit_code,log\n' >"${SUMMARY}"

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
  relative="${file#"${SOURCE_ROOT}"/}"
  IFS='|' read -r codec width height fps < <(probe_video "${file}")

  echo "======================================"
  echo "Video #${number}/${#FILES[@]}: ${relative}"
  echo "Codec: ${codec}"
  echo "Resolution: ${width}x${height}"
  echo "Source FPS: ${fps}"
  echo "======================================"

  run_playback "${number}" "${#FILES[@]}" "${file}" "normal" \
    "${LOG_DIR}/${number}_normal.log"
  echo
  run_playback "${number}" "${#FILES[@]}" "${file}" "clockwise90" \
    "${LOG_DIR}/${number}_clockwise90.log"
  echo
done

echo "5.9 Vertical Multimedia summary"
echo "Video files: ${#FILES[@]}"
echo "Source mode: ${SOURCE_MODE}"
echo "Total playbacks: $((${#FILES[@]} * 2))"
echo "PASS: ${pass}"
echo "FAIL: ${fail}"
echo "CSV: ${SUMMARY}"

if [[ "${fail}" -gt 0 ]]; then
  exit 1
fi
