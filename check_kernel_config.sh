#!/bin/bash
# Check if required kernel configs are enabled on the target device.
# Usage:
#   ./check_kernel_config.sh
#   ./check_kernel_config.sh local
#   ./check_kernel_config.sh ssh [ip] [user] [password]

TARGET_IP_HINT="192.168.xx.xx"
DEFAULT_TARGET_USER="p"
DEFAULT_TARGET_PASS="p"

prompt_value() {
	local label="$1"
	local default_value="$2"
	local value

	printf "%s:[%s] " "${label}" "${default_value}" >&2
	read -r value
	echo "${value:-$default_value}"
}

prompt_required_value() {
	local label="$1"
	local hint="$2"
	local value

	while true; do
		printf "%s:[%s] " "${label}" "${hint}" >&2
		read -r value
		if [ -n "${value}" ]; then
			echo "${value}"
			return 0
		fi
		echo "ERROR: ${label} is required." >&2
	done
}

prompt_password() {
	local default_value="$1"
	local value

	printf "password:[%s] " "${default_value}" >&2
	read -r -s value
	printf "\n" >&2
	echo "${value:-$default_value}"
}

prompt_mode() {
	local mode

	while true; do
		echo "Select check target:" >&2
		echo "1. local" >&2
		echo "2. ssh" >&2
		printf "choice:[1] " >&2
		read -r mode

		case "${mode:-1}" in
			1|local|LOCAL)
				echo "local"
				return 0
				;;
			2|ssh|SSH)
				echo "ssh"
				return 0
				;;
			*)
				echo "ERROR: choose 1 or 2." >&2
				;;
		esac
	done
}

MODE=""
TARGET_IP=""
TARGET_USER=""
TARGET_PASS=""

case "${1:-}" in
	local|LOCAL)
		MODE="local"
		;;
	ssh|SSH)
		MODE="ssh"
		TARGET_IP="${2:-}"
		TARGET_USER="${3:-$DEFAULT_TARGET_USER}"
		TARGET_PASS="${4:-$DEFAULT_TARGET_PASS}"
		;;
	"")
		MODE=$(prompt_mode)
		if [ "${MODE}" = "ssh" ]; then
			TARGET_IP=$(prompt_required_value "ip" "${TARGET_IP_HINT}")
			TARGET_USER=$(prompt_value "username" "${DEFAULT_TARGET_USER}")
			TARGET_PASS=$(prompt_password "${DEFAULT_TARGET_PASS}")
		fi
		;;
	*)
		MODE="ssh"
		TARGET_IP="$1"
		TARGET_USER="${2:-$DEFAULT_TARGET_USER}"
		TARGET_PASS="${3:-$DEFAULT_TARGET_PASS}"
		;;
esac

if [ "${MODE}" = "ssh" ] && [ -z "${TARGET_IP}" ]; then
	TARGET_IP=$(prompt_required_value "ip" "${TARGET_IP_HINT}")
fi

CONFIGS=(
	# PPP core
	CONFIG_PPP
	CONFIG_PPP_ASYNC
	CONFIG_PPP_SYNC_TTY
	CONFIG_PPP_DEFLATE
	CONFIG_PPP_BSDCOMP
	CONFIG_PPP_FILTER
	CONFIG_PPP_MPPE
	CONFIG_PPP_MULTILINK
	# USB network modem interfaces
	CONFIG_USB_USBNET
	CONFIG_USB_NET_QMI_WWAN
	CONFIG_USB_NET_CDC_NCM
	CONFIG_USB_NET_CDC_MBIM
	CONFIG_USB_NET_HUAWEI_CDC_NCM
	CONFIG_USB_NET_RNDIS_HOST
	CONFIG_USB_NET_CDC_EEM
	# USB serial modem (already in base defconfig, verify anyway)
	CONFIG_USB_SERIAL
	CONFIG_USB_SERIAL_OPTION
	CONFIG_USB_ACM
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=============================================="
echo " Kernel Config Check"
if [ "${MODE}" = "local" ]; then
	echo " Target: local ($(hostname 2>/dev/null || echo unknown))"
else
	echo " Target: ${TARGET_USER}@${TARGET_IP}"
fi
echo "=============================================="

read_kernel_config() {
	zcat /proc/config.gz 2>/dev/null ||
		cat "/boot/config-$(uname -r)" 2>/dev/null ||
		echo 'CONFIG_NOT_FOUND=unavailable'
}

if [ "${MODE}" = "local" ]; then
	RAW=$(read_kernel_config 2>&1)
else
	if ! command -v sshpass >/dev/null 2>&1; then
		echo -e "${RED}ERROR: sshpass is required for remote checks.${NC}"
		echo "       Install sshpass or run this script directly on ${TARGET_IP}."
		exit 1
	fi

	RAW=$(sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no \
		"${TARGET_USER}@${TARGET_IP}" \
		"zcat /proc/config.gz 2>/dev/null || cat /boot/config-\$(uname -r) 2>/dev/null || echo 'CONFIG_NOT_FOUND=unavailable'" 2>&1)
fi

if echo "${RAW}" | grep -q "CONFIG_NOT_FOUND=unavailable"; then
	echo -e "${RED}ERROR: Cannot read kernel config from device.${NC}"
	echo "       Make sure CONFIG_IKCONFIG and CONFIG_IKCONFIG_PROC are enabled."
	exit 1
fi

if echo "${RAW}" | grep -qiE "Permission denied|Connection refused|No route"; then
	echo -e "${RED}ERROR: SSH connection failed.${NC}"
	echo "${RAW}"
	exit 1
fi

PASS_COUNT=0
FAIL_COUNT=0

echo ""
printf "%-40s %s\n" "CONFIG" "STATUS"
echo "----------------------------------------------"

for cfg in "${CONFIGS[@]}"; do
	line=$(echo "${RAW}" | grep -E "^${cfg}=|^# ${cfg} is not set")

	if echo "${line}" | grep -q "^${cfg}=y"; then
		printf "%-40s ${GREEN}[  OK  ] built-in (=y)${NC}\n" "${cfg}"
		((PASS_COUNT++))
	elif echo "${line}" | grep -q "^${cfg}=m"; then
		printf "%-40s ${YELLOW}[  OK  ] module  (=m)${NC}\n" "${cfg}"
		((PASS_COUNT++))
	elif echo "${line}" | grep -q "# ${cfg} is not set"; then
		printf "%-40s ${RED}[ FAIL ] not set${NC}\n" "${cfg}"
		((FAIL_COUNT++))
	else
		printf "%-40s ${RED}[ FAIL ] not found${NC}\n" "${cfg}"
		((FAIL_COUNT++))
	fi
done

echo "----------------------------------------------"
echo ""
echo -e "Result: ${GREEN}${PASS_COUNT} passed${NC}, ${RED}${FAIL_COUNT} failed${NC}"
echo ""

if [ "${FAIL_COUNT}" -gt 0 ]; then
	echo -e "${RED}Some configs are missing. Please rebuild the kernel with the required configs enabled.${NC}"
	exit 1
else
	echo -e "${GREEN}All configs are enabled.${NC}"
	exit 0
fi
