#!/bin/bash
# Check if required kernel configs are enabled on the target device.
# Usage: ./check_kernel_config.sh [ip] [user] [password]

TARGET_IP="${1:-192.168.23.131}"
TARGET_USER="${2:-linaro}"
TARGET_PASS="${3:-linaro}"

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
echo " Target: ${TARGET_USER}@${TARGET_IP}"
echo "=============================================="

# Fetch /proc/config.gz from the device
RAW=$(sshpass -p "${TARGET_PASS}" ssh -o StrictHostKeyChecking=no \
	"${TARGET_USER}@${TARGET_IP}" \
	"zcat /proc/config.gz 2>/dev/null || cat /boot/config-\$(uname -r) 2>/dev/null || echo 'CONFIG_NOT_FOUND=unavailable'" 2>&1)

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
