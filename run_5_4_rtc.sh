#!/usr/bin/env bash
set -u

if [[ -t 1 ]]; then
  GREEN=$'\033[1;32m'
  RED=$'\033[1;31m'
  YELLOW=$'\033[1;33m'
  RESET=$'\033[0m'
else
  GREEN=""
  RED=""
  YELLOW=""
  RESET=""
fi

show_status() {
  local rtc_text

  rtc_text="$(sudo hwclock --show --utc 2>&1 || true)"
  echo
  echo "System time:"
  date
  echo
  echo "RTC read by hwclock (--utc; formatted in current local timezone):"
  echo "${rtc_text}"
  echo
  echo "RTC raw fields from /sys/class/rtc/rtc0:"
  if [[ -r /sys/class/rtc/rtc0/date && -r /sys/class/rtc/rtc0/time ]]; then
    printf '%s %s UTC\n' \
      "$(cat /sys/class/rtc/rtc0/date)" "$(cat /sys/class/rtc/rtc0/time)"
  else
    echo "unavailable"
  fi
  echo
  echo "timedatectl:"
  timedatectl status 2>&1 || true
}

set_system_time() {
  local value confirm timezone

  read -r -p 'Enter date/time [YYYY-MM-DD HH:MM:SS]: ' value
  if [[ ! "${value}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then
    printf '%sInvalid format.%s\n' "${RED}" "${RESET}"
    return
  fi

  timezone="$(timedatectl show -p Timezone --value 2>/dev/null || date +%Z)"
  echo
  echo "Current system time: $(date --iso-8601=seconds)"
  echo "Current RTC time:    $(sudo hwclock --show --utc 2>&1)"
  echo "Current timezone:    ${timezone}"
  echo "New system time:     ${value} (${timezone})"
  echo "Action: disable NTP and change the system clock."
  read -r -p "Apply this date/time? [y/N] " confirm
  case "${confirm}" in
    y|Y|yes|YES) ;;
    *)
      echo "Cancelled. System time was not changed."
      return
      ;;
  esac

  echo "Disabling automatic NTP before manual time setting..."
  sudo timedatectl set-ntp false
  sudo date -s "${value}"
  echo "Updated system time: $(date --iso-8601=seconds)"
}

set_timezone() {
  local timezone output rc actual_timezone persistent_timezone persistent_target

  echo "Examples: Asia/Taipei, America/New_York, UTC"
  read -r -p "Enter timezone: " timezone

  if ! timedatectl list-timezones | grep -Fxq "${timezone}"; then
    printf '%sUnknown timezone: %s%s\n' "${RED}" "${timezone}" "${RESET}"
    echo "Run 'timedatectl list-timezones' to view valid values."
    return
  fi

  echo "Current timezone: $(timedatectl show -p Timezone --value 2>/dev/null)"
  output="$(sudo timedatectl set-timezone "${timezone}" 2>&1)"
  rc="$?"
  actual_timezone="$(timedatectl show -p Timezone --value 2>/dev/null)"
  persistent_timezone="$(cat /etc/timezone 2>/dev/null || true)"
  persistent_target="$(readlink -f /etc/localtime 2>/dev/null || true)"

  if [[ "${persistent_timezone}" != "${timezone}" ||
    "${persistent_target}" != "/usr/share/zoneinfo/${timezone}" ]]; then
    printf '%sTimezone was not persisted by timedatectl; applying file fallback.%s\n' \
      "${YELLOW}" "${RESET}"
    sudo ln -snf "/usr/share/zoneinfo/${timezone}" /etc/localtime
    printf '%s\n' "${timezone}" | sudo tee /etc/timezone >/dev/null
    actual_timezone="$(timedatectl show -p Timezone --value 2>/dev/null)"
    persistent_timezone="$(cat /etc/timezone 2>/dev/null || true)"
    persistent_target="$(readlink -f /etc/localtime 2>/dev/null || true)"
  fi

  if [[ "${actual_timezone}" == "${timezone}" &&
    "${persistent_timezone}" == "${timezone}" &&
    "${persistent_target}" == "/usr/share/zoneinfo/${timezone}" ]]; then
    printf '%sRESULT,RTC,TIMEZONE,PASS,timezone=%s%s\n' \
      "${GREEN}" "${actual_timezone}" "${RESET}"
    if [[ "${rc}" -ne 0 && -n "${output}" ]]; then
      printf '%sWarning: timedatectl returned: %s%s\n' \
        "${YELLOW}" "${output}" "${RESET}"
    fi
  else
    printf '%sRESULT,RTC,TIMEZONE,FAIL,requested=%s,actual=%s,persistent=%s%s\n' \
      "${RED}" "${timezone}" "${actual_timezone:-unknown}" \
      "${persistent_timezone:-unknown}" "${RESET}"
    [[ -n "${output}" ]] && echo "${output}"
    return 1
  fi

  timedatectl status
}

write_rtc() {
  local confirm

  echo
  echo "Current system time: $(date --iso-8601=seconds)"
  echo "Current RTC time:    $(sudo hwclock --show --utc 2>&1)"
  echo "Current timezone:    $(timedatectl show -p Timezone --value 2>/dev/null || date +%Z)"
  echo "Action: overwrite RTC with the current system time using UTC mode."
  read -r -p "Write system time to RTC? [y/N] " confirm
  case "${confirm}" in
    y|Y|yes|YES) ;;
    *)
      echo "Cancelled. RTC was not changed."
      return
      ;;
  esac

  echo "Writing current system time to RTC using UTC mode..."
  sudo hwclock --systohc --utc
  echo "Updated RTC time: $(sudo hwclock --show --utc 2>&1)"
  printf '%sRTC write completed.%s\n' "${GREEN}" "${RESET}"
}

compare_clocks() {
  local system_epoch rtc_text rtc_epoch difference

  system_epoch="$(date +%s)"
  rtc_text="$(sudo hwclock --show --utc 2>/dev/null || true)"
  rtc_epoch="$(date -d "${rtc_text}" +%s 2>/dev/null || true)"

  echo "System: $(date --iso-8601=seconds)"
  echo "RTC:    ${rtc_text:-unavailable}"

  if [[ "${rtc_epoch}" =~ ^[0-9]+$ ]]; then
    difference="$((system_epoch - rtc_epoch))"
    [[ "${difference}" -lt 0 ]] && difference="$((-difference))"
    echo "Difference: ${difference} second(s)"

    if [[ "${difference}" -le 2 ]]; then
      printf '%sRESULT,RTC,COMPARE,PASS,difference=%ss%s\n' \
        "${GREEN}" "${difference}" "${RESET}"
    else
      printf '%sRESULT,RTC,COMPARE,FAIL,difference=%ss%s\n' \
        "${RED}" "${difference}" "${RESET}"
    fi
  else
    printf '%sRESULT,RTC,COMPARE,FAIL,cannot-read-rtc%s\n' "${RED}" "${RESET}"
  fi
}

schedule_absolute_shutdown() {
  local value confirm

  read -r -p "Shutdown time [HH:MM]: " value
  if [[ ! "${value}" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then
    printf '%sInvalid time format.%s\n' "${RED}" "${RESET}"
    return
  fi

  read -r -p "Schedule shutdown at ${value}? [y/N] " confirm
  case "${confirm}" in
    y|Y|yes|YES) sudo shutdown -h "${value}" ;;
    *) echo "Cancelled." ;;
  esac
}

schedule_relative_shutdown() {
  local minutes confirm

  read -r -p "Shutdown after how many minutes? [10]: " minutes
  minutes="${minutes:-10}"
  if [[ ! "${minutes}" =~ ^[0-9]+$ ]]; then
    printf '%sInvalid minute value.%s\n' "${RED}" "${RESET}"
    return
  fi

  read -r -p "Schedule shutdown after ${minutes} minute(s)? [y/N] " confirm
  case "${confirm}" in
    y|Y|yes|YES) sudo shutdown -h "+${minutes}" ;;
    *) echo "Cancelled." ;;
  esac
}

while true; do
  echo
  echo "======================================"
  echo "5.4 RTC Test"
  echo "======================================"
  echo "1) Show system time, RTC and timezone"
  echo "2) Set system date/time"
  echo "3) Set timezone"
  echo "4) Write system time to RTC"
  echo "5) Compare system time and RTC"
  echo "6) Schedule shutdown at HH:MM"
  echo "7) Schedule shutdown after N minutes"
  echo "8) Cancel scheduled shutdown"
  echo "q) Quit"

  read -r -p "Select: " selection
  case "${selection}" in
    1) show_status ;;
    2) set_system_time ;;
    3) set_timezone ;;
    4) write_rtc ;;
    5) compare_clocks ;;
    6) schedule_absolute_shutdown ;;
    7) schedule_relative_shutdown ;;
    8)
      sudo shutdown -c
      printf '%sScheduled shutdown cancelled.%s\n' "${GREEN}" "${RESET}"
      ;;
    q|Q) exit 0 ;;
    *) printf '%sInvalid selection.%s\n' "${YELLOW}" "${RESET}" ;;
  esac
done
