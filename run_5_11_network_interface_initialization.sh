#!/usr/bin/env bash
set -u

DOWN_SECONDS="${DOWN_SECONDS:-3}"
IP_WAIT_SECONDS="${IP_WAIT_SECONDS:-30}"
CYCLE_COUNT="${CYCLE_COUNT:-10}"
DOWN_WAIT_SECONDS="${DOWN_WAIT_SECONDS:-10}"
PING_TARGETS=("1.1.1.1" "8.8.8.8")

if [[ -t 1 ]]; then
  COLOR_PASS=$'\033[1;32m'
  COLOR_FAIL=$'\033[1;31m'
  COLOR_WARN=$'\033[1;33m'
  COLOR_RESET=$'\033[0m'
else
  COLOR_PASS=""
  COLOR_FAIL=""
  COLOR_WARN=""
  COLOR_RESET=""
fi

interface_type() {
  local interface="$1"

  if [[ -d "/sys/class/net/${interface}/wireless" ]]; then
    echo "WIFI"
  else
    echo "LAN"
  fi
}

interface_ipv4() {
  local interface="$1"
  ip -4 -o addr show dev "${interface}" scope global 2>/dev/null |
    awk '{split($4, address, "/"); print address[1]; exit}'
}

interface_state() {
  local interface="$1"
  cat "/sys/class/net/${interface}/operstate" 2>/dev/null || echo "unknown"
}

interface_admin_down() {
  local interface="$1"
  local flags

  flags="$(ip -o link show dev "${interface}" 2>/dev/null |
    sed -n 's/^[^<]*<\([^>]*\)>.*/\1/p')"
  [[ ",${flags}," != *,UP,* ]]
}

timestamp() {
  date '+%H:%M:%S'
}

show_link_state() {
  local interface="$1"

  if [[ -e "/sys/class/net/${interface}" ]]; then
    printf '[%s] Actual state: ' "$(timestamp)"
    ip -brief link show dev "${interface}" 2>/dev/null || true
  else
    printf '[%s] Actual state: %s is absent from the system.\n' \
      "$(timestamp)" "${interface}"
  fi
}

default_interface() {
  ip -4 route show default 2>/dev/null |
    awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}'
}

is_physical_network_interface() {
  local interface="$1"

  [[ "${interface}" != "lo" ]] || return 1
  [[ -e "/sys/class/net/${interface}/device" ]] || return 1

  case "${interface}" in
    docker*|br-*|virbr*|veth*|l4tbr*|usb*|can*) return 1 ;;
  esac

  return 0
}

has_connectivity() {
  local interface="$1"
  local target

  [[ -n "$(interface_ipv4 "${interface}")" ]] || return 1

  for target in "${PING_TARGETS[@]}"; do
    if ping -I "${interface}" -c 1 -W 3 "${target}" >/dev/null 2>&1; then
      return 0
    fi
  done

  return 1
}

wait_for_ip() {
  local interface="$1"
  local elapsed=0

  while [[ "${elapsed}" -lt "${IP_WAIT_SECONDS}" ]]; do
    if [[ -n "$(interface_ipv4 "${interface}")" ]]; then
      return 0
    fi
    sleep 1
    elapsed="$((elapsed + 1))"
  done

  return 1
}

wait_for_disconnected() {
  local interface="$1"
  local type="$2"
  local mode="${3:-normal}"
  local elapsed=0 state radio

  while [[ "${elapsed}" -lt "${DOWN_WAIT_SECONDS}" ]]; do
    if [[ "${mode}" == "driver" ]] && [[ ! -e "/sys/class/net/${interface}" ]]; then
      return 0
    fi

    state="$(nmcli -t -f GENERAL.STATE device show "${interface}" 2>/dev/null |
      cut -d: -f2-)"

    if [[ "${type}" == "WIFI" && "${mode}" == "driver" ]]; then
      radio="$(nmcli radio wifi 2>/dev/null || true)"
      if [[ "${radio}" == "disabled" ]] &&
        [[ -z "$(interface_ipv4 "${interface}")" ]] &&
        [[ "${state}" != 100* ]]; then
        return 0
      fi
    elif [[ "${mode}" == "normal" ]] &&
      interface_admin_down "${interface}"; then
      return 0
    elif [[ -z "$(interface_ipv4 "${interface}")" ]] &&
      [[ "${state}" != 100* ]]; then
      return 0
    fi

    sleep 1
    elapsed="$((elapsed + 1))"
  done

  return 1
}

wait_for_interface() {
  local interface="$1"
  local elapsed=0

  while [[ "${elapsed}" -lt "${IP_WAIT_SECONDS}" ]]; do
    [[ -e "/sys/class/net/${interface}" ]] && return 0
    sleep 1
    elapsed="$((elapsed + 1))"
  done

  return 1
}

recover_connection() {
  local interface="$1"

  if wait_for_ip "${interface}"; then
    return 0
  fi

  if command -v nmcli >/dev/null 2>&1; then
    echo "No IP yet; asking NetworkManager to reconnect ${interface}..."
    sudo nmcli device connect "${interface}" >/dev/null 2>&1 || true
    wait_for_ip "${interface}"
    return $?
  fi

  return 1
}

wait_for_connectivity() {
  local interface="$1"
  local elapsed=0

  while [[ "${elapsed}" -lt "${IP_WAIT_SECONDS}" ]]; do
    if has_connectivity "${interface}"; then
      return 0
    fi
    sleep 1
    elapsed="$((elapsed + 1))"
  done

  return 1
}

print_interface() {
  local interface="$1"
  local type state ipv4 connectivity connectivity_color

  type="$(interface_type "${interface}")"
  state="$(interface_state "${interface}")"
  ipv4="$(interface_ipv4 "${interface}")"
  if has_connectivity "${interface}"; then
    connectivity="YES"
    connectivity_color="${COLOR_PASS}"
  else
    connectivity="NO"
    connectivity_color="${COLOR_FAIL}"
  fi

  printf '%-14s type=%-5s state=%-8s ip=%-15s connectivity=%s%s%s\n' \
    "${interface}" "${type}" "${state}" "${ipv4:-none}" \
    "${connectivity_color}" "${connectivity}" "${COLOR_RESET}"
}

cycle_interface() {
  local interface="$1"
  local lan_mode="${2:-normal}"
  local cycle_total="${3:-${CYCLE_COUNT}}"
  local manual_on_confirm="${4:-no}"
  local type ipv4 cycle cycle_failures=0 down_rc up_rc
  local pci_device="" driver_name="" driver_path=""

  type="$(interface_type "${interface}")"

  if [[ "${type}" == "LAN" || "${lan_mode}" == "normal" ||
    ( "${type}" == "WIFI" && "${lan_mode}" == "driver" ) ]]; then
    sudo -v || return 1
  fi

  if [[ "${type}" == "LAN" && "${lan_mode}" == "driver" ]]; then
    pci_device="$(basename "$(readlink -f "/sys/class/net/${interface}/device")")"
    driver_path="$(readlink -f "/sys/class/net/${interface}/device/driver")"
    driver_name="$(basename "${driver_path}")"

    if [[ -z "${pci_device}" || -z "${driver_name}" ||
      ! -e "${driver_path}/unbind" || ! -e "${driver_path}/bind" ]]; then
      printf '%sERROR: Cannot determine PCI driver bind/unbind path for %s.%s\n' \
        "${COLOR_FAIL}" "${interface}" "${COLOR_RESET}"
      return 1
    fi

    echo "Low-level LAN mode: driver=${driver_name}, device=${pci_device}"
  fi

  for cycle in $(seq 1 "${cycle_total}"); do
    echo
    echo "======================================"
    echo "Testing ${type} interface: ${interface}"
    echo "Cycle: ${cycle}/${cycle_total}"
    echo "Before:"
    print_interface "${interface}"
    if [[ "${type}" == "WIFI" && "${lan_mode}" == "driver" ]]; then
      echo "Command: nmcli radio wifi off"
    elif [[ "${lan_mode}" == "driver" ]]; then
      echo "Command: echo ${pci_device} | sudo tee ${driver_path}/unbind"
    else
      echo "Command: sudo ifconfig ${interface} down"
    fi
    echo "Wait: ${DOWN_SECONDS} seconds"
    if [[ "${type}" == "WIFI" && "${lan_mode}" == "driver" ]]; then
      echo "Command: nmcli radio wifi on"
    elif [[ "${lan_mode}" == "driver" ]]; then
      echo "Command: echo ${pci_device} | sudo tee ${driver_path}/bind"
    else
      echo "Command: sudo ifconfig ${interface} up"
    fi
    echo "======================================"

    if [[ "${type}" == "WIFI" && "${lan_mode}" == "driver" ]]; then
      sudo nmcli radio wifi off
      down_rc="$?"
    elif [[ "${lan_mode}" == "driver" ]]; then
      printf '%s\n' "${pci_device}" | sudo tee "${driver_path}/unbind" >/dev/null
      down_rc="$?"
    else
      sudo ifconfig "${interface}" down
      down_rc="$?"
    fi

    if [[ "${down_rc}" -ne 0 ]]; then
      printf '%sRESULT,NETWORK_INTERFACE,%s,%s,%s/%s,FAIL,down-command%s\n' \
        "${COLOR_FAIL}" "${type}" "${interface}" "${cycle}" "${cycle_total}" "${COLOR_RESET}"
      cycle_failures="$((cycle_failures + 1))"
      return 1
    fi

    printf '[%s] Verifying interface is DOWN...\n' "$(timestamp)"
    if ! wait_for_disconnected "${interface}" "${type}" "${lan_mode}"; then
      if [[ "${type}" == "WIFI" && "${lan_mode}" == "driver" ]]; then
        sudo nmcli radio wifi on >/dev/null 2>&1 || true
      elif [[ "${lan_mode}" == "driver" ]]; then
        printf '%s\n' "${pci_device}" | sudo tee "${driver_path}/bind" >/dev/null || true
      else
        sudo ifconfig "${interface}" up >/dev/null 2>&1 || true
      fi
      printf '%sRESULT,NETWORK_INTERFACE,%s,%s,%s/%s,FAIL,down-not-confirmed%s\n' \
        "${COLOR_FAIL}" "${type}" "${interface}" "${cycle}" "${cycle_total}" "${COLOR_RESET}"
      cycle_failures="$((cycle_failures + 1))"
      return 1
    fi
    if [[ "${lan_mode}" == "normal" ]]; then
      printf '%s[%s] DOWN confirmed: %s administrative UP flag is off.%s\n' \
        "${COLOR_PASS}" "$(timestamp)" "${interface}" "${COLOR_RESET}"
      show_link_state "${interface}"
      echo "Note: The Ethernet LED may re-light while administrative state remains DOWN."
    else
      printf '%s[%s] DOWN confirmed: %s is disconnected.%s\n' \
        "${COLOR_PASS}" "$(timestamp)" "${interface}" "${COLOR_RESET}"
      show_link_state "${interface}"
    fi

    if [[ "${manual_on_confirm}" == "yes" ]]; then
      echo
      printf '%sInterface is OFF. Check the LAN LED or Ubuntu Wi-Fi UI now.%s\n' \
        "${COLOR_WARN}" "${COLOR_RESET}"
      read -r -p "Continue to turn the interface ON? [Enter] "
    else
      printf '[%s] Holding DOWN state for %s seconds...\n' \
        "$(timestamp)" "${DOWN_SECONDS}"
      sleep "${DOWN_SECONDS}"
    fi

    printf '[%s] STARTING UP NOW: %s\n' "$(timestamp)" "${interface}"
    if [[ "${type}" == "WIFI" && "${lan_mode}" == "driver" ]]; then
      sudo nmcli radio wifi on
      up_rc="$?"
    elif [[ "${lan_mode}" == "driver" ]]; then
      printf '%s\n' "${pci_device}" | sudo tee "${driver_path}/bind" >/dev/null
      up_rc="$?"
    else
      sudo ifconfig "${interface}" up
      up_rc="$?"
    fi

    if [[ "${up_rc}" -ne 0 ]]; then
      printf '%sRESULT,NETWORK_INTERFACE,%s,%s,%s/%s,FAIL,up-command%s\n' \
        "${COLOR_FAIL}" "${type}" "${interface}" "${cycle}" "${cycle_total}" "${COLOR_RESET}"
      cycle_failures="$((cycle_failures + 1))"
      return 1
    fi

    show_link_state "${interface}"

    if [[ "${type}" == "LAN" && "${lan_mode}" == "driver" ]]; then
      echo "Waiting for ${interface} to reappear after driver bind..."
      if ! wait_for_interface "${interface}"; then
        printf '%sRESULT,NETWORK_INTERFACE,%s,%s,%s/%s,FAIL,interface-not-restored%s\n' \
          "${COLOR_FAIL}" "${type}" "${interface}" "${cycle}" "${cycle_total}" "${COLOR_RESET}"
        return 1
      fi
    fi

    if ! recover_connection "${interface}"; then
      echo "ifconfig after UP:"
      ifconfig "${interface}" 2>/dev/null || true
      printf '%sRESULT,NETWORK_INTERFACE,%s,%s,%s/%s,FAIL,no-ip%s\n' \
        "${COLOR_FAIL}" "${type}" "${interface}" "${cycle}" "${cycle_total}" "${COLOR_RESET}"
      cycle_failures="$((cycle_failures + 1))"
      return 1
    fi

    ipv4="$(interface_ipv4 "${interface}")"
    echo "ifconfig after UP:"
    ifconfig "${interface}" 2>/dev/null || true
    echo "IP acquired: ${ipv4}"
    echo "Connectivity check: ping -I ${interface} ${PING_TARGETS[*]}"

    if wait_for_connectivity "${interface}"; then
      printf '%sUP confirmed: %s has IP and internet connectivity.%s\n' \
        "${COLOR_PASS}" "${interface}" "${COLOR_RESET}"
      printf '%sRESULT,NETWORK_INTERFACE,%s,%s,%s/%s,PASS,ip=%s%s\n' \
        "${COLOR_PASS}" "${type}" "${interface}" "${cycle}" "${cycle_total}" \
        "${ipv4}" "${COLOR_RESET}"
    else
      printf '%sRESULT,NETWORK_INTERFACE,%s,%s,%s/%s,FAIL,no-internet%s\n' \
        "${COLOR_FAIL}" "${type}" "${interface}" "${cycle}" "${cycle_total}" "${COLOR_RESET}"
      cycle_failures="$((cycle_failures + 1))"
      return 1
    fi
  done

  if [[ "${cycle_failures}" -eq 0 ]]; then
    printf '%sRESULT,NETWORK_INTERFACE,%s,%s,COMPLETE,PASS,cycles=%s%s\n' \
      "${COLOR_PASS}" "${type}" "${interface}" "${cycle_total}" "${COLOR_RESET}"
    return 0
  fi

  printf '%sRESULT,NETWORK_INTERFACE,%s,%s,COMPLETE,FAIL,failed_cycles=%s/%s%s\n' \
    "${COLOR_FAIL}" "${type}" "${interface}" "${cycle_failures}" \
    "${cycle_total}" "${COLOR_RESET}"
  return 1
}

echo "5.11 Network Interface Initialization"
echo "Host: $(hostname)"
echo "Date: $(date --iso-8601=seconds)"
echo "Default interface: $(default_interface)"
echo "Cycles per connected interface: ${CYCLE_COUNT}"
echo

if ! command -v ifconfig >/dev/null 2>&1; then
  echo "ifconfig not found; installing net-tools..."
  sudo apt-get update &&
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y net-tools
fi

if [[ -n "${SSH_CONNECTION:-}" ]]; then
  printf '\n%sWARNING: SSH session detected.%s\n' "${COLOR_WARN}" "${COLOR_RESET}"
  echo "Cycling the interface carrying SSH may disconnect this session."
  read -r -p "Continue? [y/N] " answer
  case "${answer}" in
    y|Y|yes|YES) ;;
    *) exit 1 ;;
  esac
fi

scan_interfaces() {
  mapfile -t INTERFACES < <(
    for path in /sys/class/net/*; do
      interface="$(basename "${path}")"
      if is_physical_network_interface "${interface}"; then
        echo "${interface}"
      fi
    done | sort
  )
}

show_menu() {
  local index interface connected=0

  scan_interfaces
  echo
  echo "======================================"
  echo "Network Interface Selection"
  echo "Detected interfaces: ${#INTERFACES[@]}"
  echo "======================================"

  for index in "${!INTERFACES[@]}"; do
    interface="${INTERFACES[$index]}"
    printf '%s) ' "$((index + 1))"
    print_interface "${interface}"
    if has_connectivity "${interface}"; then
      connected="$((connected + 1))"
    fi
  done

  echo
  echo "Connected interfaces: ${connected}/${#INTERFACES[@]}"
  echo "r) Refresh interface status"
  echo "q) Quit"
}

while true; do
  show_menu

  if [[ "${#INTERFACES[@]}" -eq 0 ]]; then
    printf '%sNo physical LAN/Wi-Fi interfaces found.%s\n' \
      "${COLOR_FAIL}" "${COLOR_RESET}"
  fi

  read -r -p "Select interface to test, refresh, or quit: " selection

  case "${selection}" in
    r|R)
      echo "Refreshing..."
      continue
      ;;
    q|Q)
      echo "Exit 5.11 Network Interface Initialization."
      exit 0
      ;;
    ''|*[!0-9]*)
      echo "Invalid selection."
      continue
      ;;
  esac

  selected_index="$((selection - 1))"
  if [[ "${selected_index}" -lt 0 || "${selected_index}" -ge "${#INTERFACES[@]}" ]]; then
    echo "Invalid interface number."
    continue
  fi

  selected_interface="${INTERFACES[$selected_index]}"
  selected_type="$(interface_type "${selected_interface}")"
  lan_mode="normal"

  if ! has_connectivity "${selected_interface}"; then
    echo
    if [[ "${selected_type}" == "WIFI" ]]; then
      printf '%sWi-Fi %s is not connected.%s\n' \
        "${COLOR_WARN}" "${selected_interface}" "${COLOR_RESET}"
      echo "Connect Wi-Fi manually, then select r to refresh."
    else
      printf '%sLAN %s is not connected.%s\n' \
        "${COLOR_WARN}" "${selected_interface}" "${COLOR_RESET}"
      echo "Connect or move the LAN cable, then select r to refresh."
    fi
    continue
  fi

  echo
  echo "Test duration:"
  echo "  1) Single observation test"
  echo "     Keep the interface OFF until you confirm the LED or Ubuntu UI."
  echo "  2) Automatic ${CYCLE_COUNT}-cycle test"
  read -r -p "Select test duration [1/2]: " duration_answer
  case "${duration_answer}" in
    1)
      selected_cycles=1
      manual_on_confirm="yes"
      echo "Single observation test selected."
      ;;
    2)
      selected_cycles="${CYCLE_COUNT}"
      manual_on_confirm="no"
      echo "Automatic ${CYCLE_COUNT}-cycle test selected."
      ;;
    *)
      echo "Invalid test duration."
      continue
      ;;
  esac

  if [[ "${selected_type}" == "LAN" ]]; then
    echo
    echo "LAN test mode:"
    echo "  Normal: sudo ifconfig ${selected_interface} down/up"
    echo "  Low-level: PCI driver unbind/bind (interface disappears; LED may turn off)"
    read -r -p "Run low-level driver test? [y/N] " low_level_answer
    case "${low_level_answer}" in
      y|Y|yes|YES)
        lan_mode="driver"
        printf '%sLow-level driver test selected.%s\n' \
          "${COLOR_WARN}" "${COLOR_RESET}"
        ;;
      *)
        lan_mode="normal"
        echo "Normal ifconfig test selected."
        ;;
    esac
  else
    echo
    echo "Wi-Fi test mode:"
    echo "  Normal: sudo ifconfig ${selected_interface} down/up"
    echo "  Low-level: nmcli radio wifi off/on (Ubuntu Settings and icon update)"
    read -r -p "Run low-level Wi-Fi radio test? [y/N] " low_level_answer
    case "${low_level_answer}" in
      y|Y|yes|YES)
        lan_mode="driver"
        printf '%sLow-level Wi-Fi radio test selected.%s\n' \
          "${COLOR_WARN}" "${COLOR_RESET}"
        ;;
      *)
        lan_mode="normal"
        echo "Normal Wi-Fi ifconfig test selected."
        ;;
    esac
  fi

  if cycle_interface "${selected_interface}" "${lan_mode}" \
    "${selected_cycles}" "${manual_on_confirm}"; then
    result="PASS"
    result_color="${COLOR_PASS}"
  else
    result="FAIL"
    result_color="${COLOR_FAIL}"
  fi

  echo
  printf '%sTEST COMPLETE: %s %s = %s%s\n' \
    "${result_color}" "${selected_type}" "${selected_interface}" \
    "${result}" "${COLOR_RESET}"
  echo "Returning to interface selection menu."
done
