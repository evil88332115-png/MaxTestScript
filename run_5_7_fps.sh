#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
NAS_TEST_FILE_DIR="${NAS_TEST_FILE_DIR:-/mnt/nas_home/TEST FILE}"
MEDIA_DIR="${MEDIA_DIR:-}"
LOCAL_MEDIA_DIR="${LOCAL_MEDIA_DIR:-${HOME}/5_7_fps_media}"
LOG_DIR="${LOG_DIR:-/tmp/fps_5_7_logs}"
DURATION="${DURATION:-}"
MODE="${MODE:-gst-launch-hwdecode}"
PLAYER_TIMEOUT="${PLAYER_TIMEOUT:-timeout}"
GST_LAUNCH="${GST_LAUNCH:-gst-launch-1.0}"
FULL_PLAYER="${FULL_PLAYER:-nvgstplayer-1.0}"
VIDEO_SINK="${VIDEO_SINK:-nv3dsink}"
VIDEO_SYNC="${VIDEO_SYNC:-false}"
AUDIO_SINK="${AUDIO_SINK:-autoaudiosink}"
INDEXES="${INDEXES:-}"
SOURCE_MODE="${SOURCE_MODE:-}"
FPS_FOLDER="${FPS_FOLDER:-}"
export DISPLAY="${DISPLAY:-:0}"

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

csv_escape() {
  local value="$1"
  value="${value//\"/\"\"}"
  printf '"%s"' "${value}"
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

prompt_gst_launch() {
  local answer

  if [[ ! -t 0 ]]; then
    return 1
  fi

  while true; do
    read -r -p "Replay this file with gst-launch-1.0? [y/N] " answer
    case "${answer}" in
      y|Y|yes|YES) return 0 ;;
      n|N|no|NO|"") return 1 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

probe_video_info() {
  local file="$1"

  if ! command -v ffprobe >/dev/null 2>&1; then
    echo "codec=unknown"
    echo "width="
    echo "height="
    echo "avg_frame_rate="
    return 0
  fi

  ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height,avg_frame_rate \
    -of default=noprint_wrappers=1:nokey=0 "${file}" 2>/dev/null || true
}

append_csv_row() {
  local file="$1"
  local status="$2"
  local rc="$3"
  local samples="$4"
  local avg_fps="$5"
  local min_fps="$6"
  local max_fps="$7"
  local codec="$8"
  local width="$9"
  local height="${10}"
  local source_fps="${11}"
  local log="${12}"

  {
    csv_escape "$(basename "${file}")"; printf ','
    csv_escape "${status}"; printf ','
    csv_escape "${rc}"; printf ','
    csv_escape "${samples}"; printf ','
    csv_escape "${avg_fps}"; printf ','
    csv_escape "${min_fps}"; printf ','
    csv_escape "${max_fps}"; printf ','
    csv_escape "${codec}"; printf ','
    csv_escape "${width}"; printf ','
    csv_escape "${height}"; printf ','
    csv_escape "${source_fps}"; printf ','
    csv_escape "${log}"
    printf '\n'
  } >>"${SUMMARY_CSV}"
}

parse_fps_log() {
  local log="$1"

  python3 - "${log}" <<'PY'
import re
import statistics
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(errors="replace")
values = []

for line in text.splitlines():
    lowered = line.lower()
    # fpsdisplaysink commonly prints lines such as:
    #   rendered: 123, dropped: 0, current: 29.98, average: 29.97
    # Some builds also prefix the line with "fps", so we accept both styles.
    if not any(token in lowered for token in ("current", "average", "rendered", "fps")):
        continue

    match = re.search(r"(?:current|average|fps)\s*[:=]\s*([0-9]+(?:\.[0-9]+)?)", lowered)
    if match:
        values.append(float(match.group(1)))

    if not match:
        match = re.search(r"rendered\s*[:=]\s*[0-9]+.*?(?:current|average)\s*[:=]\s*([0-9]+(?:\.[0-9]+)?)", lowered)
        if match:
            values.append(float(match.group(1)))

if not values:
    print("0,,,,")
    raise SystemExit(0)

avg = statistics.mean(values)
print(f"{len(values)},{avg:.2f},{min(values):.2f},{max(values):.2f}")
PY
}

print_command_array() {
  printf 'Command:'
  printf ' %q' "$@"
  printf '\n'
}

run_gst_with_terminal_fps() {
  local log="$1"
  shift
  local rc

  print_command_array "$@"
  set +o pipefail
  "$@" 2>&1 \
    | tee "${log}" \
    | grep --line-buffered "last-message = rendered:" \
    | sed -u 's/.*last-message = //' \
    | while IFS= read -r line; do
        printf '\r%s' "${line}"
      done
  rc="${PIPESTATUS[0]}"
  set -o pipefail
  printf '\n'
  return "${rc}"
}

have_gi() {
  python3 - <<'PY' >/dev/null 2>&1
import gi
PY
}

get_parser() {
  local codec="$1"
  case "$codec" in
    h264) echo "h264parse" ;;
    hevc|h265) echo "h265parse" ;;
    vp9) if gst-inspect-1.0 vp9parse >/dev/null 2>&1; then echo "vp9parse"; else echo ""; fi ;;
    vp8) if gst-inspect-1.0 vp8parse >/dev/null 2>&1; then echo "vp8parse"; else echo ""; fi ;;
    av1) if gst-inspect-1.0 av1parse >/dev/null 2>&1; then echo "av1parse"; else echo ""; fi ;;
    mpeg2video|mpeg1video) echo "mpegvideoparse" ;;
    mpeg4) if gst-inspect-1.0 mpeg4videoparse >/dev/null 2>&1; then echo "mpeg4videoparse"; else echo ""; fi ;;
    h263) if gst-inspect-1.0 h263parse >/dev/null 2>&1; then echo "h263parse"; else echo ""; fi ;;
    *) echo "" ;;
  esac
}

get_demux() {
  local file="$1"
  local format="${2:-}"
  local lower
  lower="$(echo "$file" | tr '[:upper:]' '[:lower:]')"

  if echo "$format" | grep -qiE 'mpegts'; then
    echo "tsdemux"
    return
  elif echo "$format" | grep -qiE 'matroska|webm'; then
    echo "matroskademux"
    return
  elif echo "$format" | grep -qiE 'mov|mp4|m4a|3gp|3g2|mj2'; then
    echo "qtdemux"
    return
  elif echo "$format" | grep -qiE 'avi'; then
    echo "avidemux"
    return
  elif echo "$format" | grep -qiE 'mpeg'; then
    echo "mpegpsdemux"
    return
  fi

  case "$lower" in
    *.h265|*.265|*.hevc|*.h264|*.264|*.avc) echo "raw" ;;
    *.mp4|*.m4v|*.mov|*.3gp) echo "qtdemux" ;;
    *.mkv|*.webm) echo "matroskademux" ;;
    *.m2ts|*.mts|*.ts) echo "tsdemux" ;;
    *.mpg|*.mpeg) echo "mpegpsdemux" ;;
    *.avi|*.divx) echo "avidemux" ;;
    *) echo "" ;;
  esac
}

audio_supported_for_demux() {
  local demux="$1"
  case "$demux" in
    qtdemux|matroskademux) return 0 ;;
    *) return 1 ;;
  esac
}

get_display_hz() {
  local hz

  hz="$(xrandr --current 2>/dev/null | awk '
    /\*/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /\*/) {
          gsub(/[^0-9.]/, "", $i)
          print $i
          exit
        }
      }
    }
  ')"

  printf '%s\n' "${hz:-60}"
}

get_display_size() {
  local geometry

  geometry="$(xrandr --current 2>/dev/null | awk '
    / connected primary/ {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+x[0-9]+\+/) {
          split($i, position, "+")
          print position[1]
          exit
        }
      }
    }
    / connected/ && !found {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+x[0-9]+\+/) {
          split($i, position, "+")
          print position[1]
          found = 1
          exit
        }
      }
    }
  ')"

  if [[ "${geometry}" =~ ^[0-9]+x[0-9]+$ ]]; then
    printf '%s\n' "${geometry}"
  else
    printf '0x0\n'
  fi
}

fps_to_decimal() {
  local fps="$1"

  awk -v fps="${fps}" 'BEGIN {
    split(fps, value, "/")
    if (value[1] == "" || value[1] == "0") {
      print "0"
    } else if (value[2] == "" || value[2] == "0") {
      printf "%.3f\n", value[1]
    } else {
      printf "%.3f\n", value[1] / value[2]
    }
  }'
}

calculate_drop_interval() {
  local source_fps="$1"
  local display_hz="$2"

  awk -v source="${source_fps}" -v display="${display_hz}" 'BEGIN {
    if (source <= 0 || display <= 0 || source <= display) {
      print 1
      exit
    }

    interval = int((source / display) + 0.5)
    if (interval < 1)
      interval = 1
    print interval
  }'
}

run_nvgstplayer_playback() {
  local file="$1"
  local log="$2"
  local source_fps_fraction="$3"
  local display_hz source_fps drop_interval output_fps duration_seconds
  local -a player_args

  display_hz="$(get_display_hz)"
  source_fps="$(fps_to_decimal "${source_fps_fraction}")"
  drop_interval="$(calculate_drop_interval "${source_fps}" "${display_hz}")"
  output_fps="$(awk -v source="${source_fps}" -v interval="${drop_interval}" \
    'BEGIN { if (source > 0) printf "%.3f", source / interval; else print "unknown" }')"
  echo "Player: nvgstplayer-1.0"
  echo "Display refresh: ${display_hz} Hz"
  echo "Frame adaptation: ${source_fps} FPS / ${drop_interval} = ${output_fps} FPS"

  player_args=(
    --bg
    --gst-disable-segtrap
    --gst-disable-registry-fork
    "--svd=nvv4l2decoder# drop-frame-interval=${drop_interval}# enable-max-performance=1"
    --svc=nvvidconv
    "--svs=nv3dsink# sync=1"
    -i "$(file_uri "${file}")"
  )

  if [[ -n "${DURATION}" ]]; then
    duration_seconds="$(awk -v value="${DURATION}" 'BEGIN {
      if (value ~ /^[0-9]+ms$/) {
        sub(/ms$/, "", value)
        printf "%.3f", value / 1000
      } else if (value ~ /^[0-9]+s$/) {
        sub(/s$/, "", value)
        print value
      } else if (value ~ /^[0-9]+m$/) {
        sub(/m$/, "", value)
        print value * 60
      } else if (value ~ /^[0-9]+h$/) {
        sub(/h$/, "", value)
        print value * 3600
      } else {
        print value
      }
    }')"
    player_args=(-d "${duration_seconds}" "${player_args[@]}")
  fi

  printf 'Command:'
  printf ' %q' "${FULL_PLAYER}" "${player_args[@]}"
  printf '\n'

  if [[ -t 0 ]]; then
    "${FULL_PLAYER}" "${player_args[@]}" >"${log}" 2>&1
    return $?
  fi

  tail -f /dev/null | "${FULL_PLAYER}" "${player_args[@]}" >"${log}" 2>&1
  return "${PIPESTATUS[1]}"
}

run_fps_probe_py() {
  local file="$1"
  local log="$2"

  python3 - "${file}" "${DURATION}" "${VIDEO_SINK}" "${VIDEO_SYNC}" "${AUDIO_SINK}" >>"${log}" 2>&1 <<'PY'
import re
import sys
from pathlib import Path

import gi

gi.require_version("Gst", "1.0")
gi.require_version("GLib", "2.0")

from gi.repository import GLib, Gst

file_path = sys.argv[1]
duration_text = sys.argv[2]
video_sink_name = sys.argv[3]
video_sync_text = sys.argv[4].lower()
audio_sink_name = sys.argv[5]


def parse_duration(text: str) -> int:
    if not text or not text.strip():
        return 0
    match = re.fullmatch(r"\s*(\d+)\s*(ms|s|m|h)?\s*", text)
    if not match:
        raise ValueError(f"Unsupported duration: {text!r}")

    value = int(match.group(1))
    unit = match.group(2) or "s"
    if unit == "ms":
        return max(1, value)
    if unit == "s":
        return value * 1000
    if unit == "m":
        return value * 60 * 1000
    if unit == "h":
        return value * 60 * 60 * 1000
    raise ValueError(f"Unsupported duration unit: {unit!r}")


def make_element(factory_name: str, fallback_name: str):
    element = Gst.ElementFactory.make(factory_name, fallback_name)
    if element is None:
        print(f"WARNING: element not available: {factory_name}", flush=True)
    return element


Gst.init(None)
duration_ms = parse_duration(duration_text)
uri = GLib.filename_to_uri(str(Path(file_path).resolve()), None)

playbin = Gst.ElementFactory.make("playbin", "playbin")
if playbin is None:
    raise SystemExit("ERROR: failed to create playbin")

fpssink = Gst.ElementFactory.make("fpsdisplaysink", "fpssink")
if fpssink is None:
    raise SystemExit("ERROR: failed to create fpsdisplaysink")

video_sink = make_element(video_sink_name, "videosink")
if video_sink is None:
    video_sink = Gst.ElementFactory.make("fakesink", "videosink")
    if video_sink is None:
        raise SystemExit("ERROR: failed to create fallback video sink")

audio_sink = make_element(audio_sink_name, "audiosink")
if audio_sink is None:
    audio_sink = Gst.ElementFactory.make("fakesink", "audiosink")
    if audio_sink is None:
        raise SystemExit("ERROR: failed to create fallback audio sink")

fpssink.set_property("video-sink", video_sink)
fpssink.set_property("text-overlay", False)
fpssink.set_property("sync", video_sync_text in {"1", "true", "yes", "on"})
fpssink.set_property("silent", False)
fpssink.set_property("signal-fps-measurements", True)
playbin.set_property("video-sink", fpssink)
playbin.set_property("audio-sink", audio_sink)
playbin.set_property("uri", uri)

samples = []
stopped = {"done": False, "error": None}


def on_fps(*args):
    numeric = [float(arg) for arg in args[1:] if isinstance(arg, (int, float))]
    current = numeric[0] if len(numeric) > 0 else 0.0
    dropped = numeric[1] if len(numeric) > 1 else 0.0
    average = numeric[2] if len(numeric) > 2 else current
    samples.append(current)
    print(
        f"FPS_MEAS current={current:.2f} average={average:.2f} dropped={dropped:.2f}",
        flush=True,
    )


def on_message(bus, message):
    mtype = message.type
    if mtype == Gst.MessageType.ERROR:
        err, dbg = message.parse_error()
        stopped["error"] = f"{err.message} | {dbg or ''}".rstrip()
        print(f"GST_ERROR {err.message}", flush=True)
        if dbg:
            print(f"GST_DEBUG {dbg}", flush=True)
        loop.quit()
    elif mtype == Gst.MessageType.EOS:
        print("GST_EOS", flush=True)
        loop.quit()


fpssink.connect("fps-measurements", on_fps)
bus = playbin.get_bus()
bus.add_signal_watch()
bus.connect("message", on_message)

loop = GLib.MainLoop()


def stop_loop():
    stopped["done"] = True
    loop.quit()
    return False


playbin.set_state(Gst.State.PLAYING)
if duration_ms > 0:
    GLib.timeout_add(duration_ms, stop_loop)
loop.run()
playbin.set_state(Gst.State.NULL)

print(f"FPS_DONE samples={len(samples)}", flush=True)
if stopped["error"]:
    raise SystemExit(1)
raise SystemExit(0)
PY
}

play_file() {
  local file="$1"
  local index="$2"
  local base log info codec audio_codec width height source_fps fps_summary samples avg_fps min_fps max_fps rc status

  base="$(basename "${file}")"
  log="${LOG_DIR}/${index}_${base}.log"
  info="$(probe_video_info "${file}")"
  codec="$(printf '%s\n' "${info}" | awk -F= '$1=="codec_name" { print $2; exit }')"
  audio_codec="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "${file}" 2>/dev/null | head -n 1 || true)"
  width="$(printf '%s\n' "${info}" | awk -F= '$1=="width" { print $2; exit }')"
  height="$(printf '%s\n' "${info}" | awk -F= '$1=="height" { print $2; exit }')"
  source_fps="$(printf '%s\n' "${info}" | awk -F= '$1=="avg_frame_rate" { print $2; exit }')"

  echo "=== FPS test ${base} ==="
  echo "Pre-check: codec=${codec:-unknown}, audio=${audio_codec:-none}, size=${width:-?}x${height:-?}, source_fps=${source_fps:-unknown}"
  echo "Duration: ${DURATION:-full}"
  echo "Log: ${log}"

  set +e
  echo "Player: gst-launch-1.0 hardware decode"
  run_hwdecode_playback "${file}" "${log}"
  rc="$?"
  set -e

  fps_summary="$(parse_fps_log "${log}")"
  IFS=',' read -r samples avg_fps min_fps max_fps <<<"${fps_summary}"

  if [[ "${rc}" -eq 0 || ( "${rc}" -eq 124 && -n "${DURATION}" ) ]]; then
    status="PASS"
    printf '%sRESULT,FPS,%s,PASS,mode=gst-launch-hwdecode%s\n' \
      "${COLOR_RESULT}" "${base}" "${COLOR_RESET}"
    append_csv_row "${file}" "${status}" "${rc}" "${samples}" "${avg_fps}" "${min_fps}" "${max_fps}" \
      "${codec:-unknown}" "${width:-}" "${height:-}" "${source_fps:-}" "${log}"
    echo
    return 0
  fi

  status="FAIL"
  printf '%sERROR: FPS test failed: %s%s\n' "${COLOR_ERROR}" "${base}" "${COLOR_RESET}" >&2
  printf '%sRESULT,FPS,%s,FAIL,rc=%s,samples=%s%s\n' \
    "${COLOR_ERROR}" "${base}" "${rc}" "${samples}" "${COLOR_RESET}"
  echo "----- LOG START -----" >&2
  tail -n 80 "${log}" >&2 || true
  echo "----- LOG END -----" >&2
  append_csv_row "${file}" "${status}" "${rc}" "${samples}" "${avg_fps}" "${min_fps}" "${max_fps}" \
    "${codec:-unknown}" "${width:-}" "${height:-}" "${source_fps:-}" "${log}"
  echo

  echo "Continuing to next file."
  return 0
}

run_hwdecode_playback() {
  local file="$1"
  local log="$2"
  local info codec format parser demux audio_codec sink decoder audio_sink
  local display_size display_width display_height video_sink
  local -a launch_prefix gst_cmd

  info="$(probe_video_info "${file}")"
  codec="$(printf '%s\n' "${info}" | awk -F= '$1=="codec_name" { print $2; exit }')"
  audio_codec="$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "${file}" 2>/dev/null | head -n 1 || true)"
  format="$(ffprobe -v error -show_entries format=format_name -of default=noprint_wrappers=1:nokey=1 "${file}" 2>/dev/null | head -n 1 || true)"
  parser="$(get_parser "${codec}")"
  demux="$(get_demux "${file}" "${format}")"
  display_size="$(get_display_size)"
  display_width="${display_size%x*}"
  display_height="${display_size#*x}"
  if [[ "${display_width}" =~ ^[1-9][0-9]*$ && "${display_height}" =~ ^[1-9][0-9]*$ ]]; then
    video_sink="nv3dsink window-x=0 window-y=0 window-width=${display_width} window-height=${display_height} sync=true"
  else
    video_sink="nv3dsink sync=true"
  fi
  sink="fpsdisplaysink video-sink=${video_sink} text-overlay=false silent=false sync=true"
  decoder="nvv4l2decoder"
  audio_sink="${AUDIO_SINK}"
  launch_prefix=()
  if [[ -n "${DURATION}" ]]; then
    launch_prefix=("${PLAYER_TIMEOUT}" --foreground "${DURATION}")
  fi

  echo "Mode: hwdecode"
  echo "Pipeline target: ${demux} -> ${parser} -> ${decoder} -> nvvidconv -> ${sink}"
  echo "Display window: ${display_size}"
  if [[ -n "${audio_codec}" ]] && audio_supported_for_demux "${demux}"; then
    echo "Audio target: ${audio_codec} -> decodebin -> ${audio_sink}"
  else
    echo "Audio target: none"
  fi

  if [[ -z "${parser}" || -z "${demux}" ]]; then
    echo "ERROR: unsupported codec/container for hwdecode mode: codec=${codec:-unknown} format=${format:-unknown}" | tee -a "${log}" >&2
    return 1
  fi

  if [[ "${demux}" == "raw" ]]; then
    gst_cmd=(
      "${launch_prefix[@]}" "${GST_LAUNCH}" -e -v
      filesrc "location=${file}" !
      "${parser}" ! "${decoder}" ! nvvidconv !
      fpsdisplaysink "video-sink=${video_sink}" text-overlay=false silent=false sync=true
    )
    run_gst_with_terminal_fps "${log}" "${gst_cmd[@]}"
    return "$?"
  fi

  if [[ "${demux}" == "tsdemux" || "${demux}" == "mpegpsdemux" || "${demux}" == "avidemux" ]]; then
    gst_cmd=(
      "${launch_prefix[@]}" "${GST_LAUNCH}" -e -v
      filesrc "location=${file}" !
      "${demux}" name=demux
      demux. ! queue !
      "${parser}" ! "${decoder}" ! nvvidconv !
      fpsdisplaysink "video-sink=${video_sink}" text-overlay=false silent=false sync=true
    )
    run_gst_with_terminal_fps "${log}" "${gst_cmd[@]}"
    return "$?"
  fi

  if [[ -n "${audio_codec}" ]] && audio_supported_for_demux "${demux}"; then
    gst_cmd=(
      "${launch_prefix[@]}" "${GST_LAUNCH}" -e -v
      filesrc "location=${file}" !
      "${demux}" name=demux
      demux.video_0 ! queue !
      "${parser}" ! "${decoder}" ! nvvidconv !
      fpsdisplaysink "video-sink=${video_sink}" text-overlay=false silent=false sync=true
      demux.audio_0 ! queue !
      decodebin ! audioconvert ! audioresample !
      "${audio_sink}"
    )
    run_gst_with_terminal_fps "${log}" "${gst_cmd[@]}"
    return "$?"
  fi

  gst_cmd=(
    "${launch_prefix[@]}" "${GST_LAUNCH}" -e -v
    filesrc "location=${file}" !
    "${demux}" name=demux
    demux.video_0 ! queue !
    "${parser}" ! "${decoder}" ! nvvidconv !
    fpsdisplaysink "video-sink=${video_sink}" text-overlay=false silent=false sync=true
  )
  run_gst_with_terminal_fps "${log}" "${gst_cmd[@]}"
}

find_files_by_indexes() {
  local index

  for index in ${INDEXES}; do
    find "${MEDIA_DIR}" -maxdepth 1 -type f \( \
      -name "TestFile_${index}.*" -o \
      -name "TestFile${index}_*" -o \
      -name "*${index}*" \
    \) | sort
  done
}

find_all_video_files() {
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
  \) | sort
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
  echo "2) Direct NAS streaming from selected FPS folder"
  read -r -p "Select [1/2, default 1]: " choice

  case "${choice}" in
    2)
      SOURCE_MODE="streaming"
      ;;
    *)
      SOURCE_MODE="local"
      ;;
  esac
}

select_fps_folder() {
  local choice

  if [[ -n "${MEDIA_DIR}" ]]; then
    echo "FPS media directory preset by MEDIA_DIR: ${MEDIA_DIR}"
    return 0
  fi

  if [[ -n "${FPS_FOLDER}" ]]; then
    case "${FPS_FOLDER}" in
      FPS-30|FPS-60)
        MEDIA_DIR="${NAS_TEST_FILE_DIR}/${FPS_FOLDER}"
        return 0
        ;;
      30)
        FPS_FOLDER="FPS-30"
        MEDIA_DIR="${NAS_TEST_FILE_DIR}/${FPS_FOLDER}"
        return 0
        ;;
      60)
        FPS_FOLDER="FPS-60"
        MEDIA_DIR="${NAS_TEST_FILE_DIR}/${FPS_FOLDER}"
        return 0
        ;;
      *)
        echo "ERROR: unsupported FPS_FOLDER=${FPS_FOLDER}. Use FPS-30, FPS-60, 30, or 60." >&2
        exit 1
        ;;
    esac
  fi

  if [[ ! -t 0 ]]; then
    FPS_FOLDER="FPS-60"
    MEDIA_DIR="${NAS_TEST_FILE_DIR}/${FPS_FOLDER}"
    echo "Non-interactive shell; defaulting FPS folder to ${FPS_FOLDER}."
    return 0
  fi

  echo "FPS source folder:"
  echo "1) FPS-60 (${NAS_TEST_FILE_DIR}/FPS-60)"
  echo "2) FPS-30 (${NAS_TEST_FILE_DIR}/FPS-30)"
  read -r -p "Select [1/2, default 1]: " choice

  case "${choice}" in
    2)
      FPS_FOLDER="FPS-30"
      ;;
    *)
      FPS_FOLDER="FPS-60"
      ;;
  esac

  MEDIA_DIR="${NAS_TEST_FILE_DIR}/${FPS_FOLDER}"
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

echo "5.7 FPS test"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Mode: ${MODE}"
echo "NAS test file directory: ${NAS_TEST_FILE_DIR}"
echo "Media directory: ${MEDIA_DIR:-not selected}"
echo "Local media directory: ${LOCAL_MEDIA_DIR}"
echo "Log directory: ${LOG_DIR}"
echo "Duration per file: ${DURATION}"
setup_display
echo "DISPLAY: ${DISPLAY:-not set}"
echo "XAUTHORITY: ${XAUTHORITY:-not set}"
echo

select_source_mode
select_fps_folder

echo "Selected FPS folder: ${FPS_FOLDER:-custom}"
echo "Media directory: ${MEDIA_DIR}"
echo

if [[ ! -d "${MEDIA_DIR}" ]]; then
  echo "ERROR: Media directory not found: ${MEDIA_DIR}" >&2
  echo "Please mount NAS first, for example: ${HOME}/run_0_mount_nas.sh" >&2
  exit 1
fi

if ! command -v "${GST_LAUNCH}" >/dev/null 2>&1; then
  echo "ERROR: ${GST_LAUNCH} not found." >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 not found." >&2
  exit 1
fi

mkdir -p "${LOG_DIR}"
SUMMARY_CSV="${LOG_DIR}/5-7_fps_summary.csv"
SUMMARY_TXT="${LOG_DIR}/summary.txt"

echo "file,status,exit_code,samples,avg_fps,min_fps,max_fps,codec,width,height,source_fps,log" >"${SUMMARY_CSV}"
echo "Player: $(command -v "${GST_LAUNCH}")"
echo "Pipeline: parser -> nvv4l2decoder -> nvvidconv -> fpsdisplaysink video-sink=nv3dsink text-overlay=false silent=false sync=true"
echo "Audio sink: ${AUDIO_SINK} (used only when the source file has an audio track)"
echo "Playback: full file, then automatically continue"
echo

if [[ -n "${INDEXES}" ]]; then
  mapfile -t NAS_FILES < <(find_files_by_indexes | awk '!seen[$0]++')
else
  mapfile -t NAS_FILES < <(find_all_video_files)
fi

if [[ "${#NAS_FILES[@]}" -eq 0 ]]; then
  echo "ERROR: No video files found in ${MEDIA_DIR}" >&2
  exit 1
fi

prepare_playback_files

echo "Source mode: ${SOURCE_MODE}"
echo "FPS folder: ${FPS_FOLDER:-custom}"
echo "Playback files: ${#FILES[@]}"
echo

for idx in "${!FILES[@]}"; do
  if ! play_file "${FILES[$idx]}" "$((idx + 1))"; then
    exit 1
  fi
done

{
  echo "5.7 FPS test summary"
  echo "Host: $(hostname)"
  echo "Date: $(date --iso-8601=seconds)"
  echo "Media directory: ${MEDIA_DIR}"
  echo "Local media directory: ${LOCAL_MEDIA_DIR}"
  echo "Source mode: ${SOURCE_MODE}"
  echo "FPS folder: ${FPS_FOLDER:-custom}"
  echo "Duration per file: ${DURATION}"
  echo "Video sink: fpsdisplaysink video-sink=nv3dsink text-overlay=false silent=false sync=true"
  echo "Player: gst-launch-1.0 hardware decode"
  echo "Files: ${#FILES[@]}"
  echo "CSV: ${SUMMARY_CSV}"
} >"${SUMMARY_TXT}"

echo "Summary"
echo "-------"
cat "${SUMMARY_TXT}"
echo "RESULT,FPS,5-7,COMPLETE"
echo "Artifacts: ${LOG_DIR}"
