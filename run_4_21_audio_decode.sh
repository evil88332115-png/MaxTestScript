#!/usr/bin/env bash
set -euo pipefail

AUDIO_DIR="${AUDIO_DIR:-/mnt/nas_home/TEST FILE/Audio Decode}"

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

play_file() {
  local file="$1"

  echo "=== Playing $(basename "${file}") ==="
  case "${PLAYER}" in
    ffplay)
      ffplay -nodisp -autoexit -hide_banner -loglevel warning "${file}"
      ;;
    gst-play-1.0)
      gst-play-1.0 "${file}"
      ;;
    cvlc)
      cvlc --play-and-exit "${file}"
      ;;
    *)
      echo "ERROR: Unsupported player: ${PLAYER}" >&2
      exit 1
      ;;
  esac
  echo "RESULT,Audio Decode,$(basename "${file}"),PASS"
  echo
}

echo "4.21 Audio Decode test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Audio directory: ${AUDIO_DIR}"
echo

if [[ ! -d "${AUDIO_DIR}" ]]; then
  echo "ERROR: Audio directory not found: ${AUDIO_DIR}" >&2
  echo "Please mount NAS first, for example: /home/p/run_0_mount_nas.sh" >&2
  exit 1
fi

find_player
echo "Player: ${PLAYER}"
echo

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

  play_file "${matches[0]}"
done

echo "Summary"
echo "-------"
echo "RESULT,Audio Decode,01-08,COMPLETE"
