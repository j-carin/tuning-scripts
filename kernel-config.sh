#!/usr/bin/env bash
#
# kernel-config.sh — Configure kernel boot parameters for low-latency performance
# Usage: ./kernel-config.sh <enable|disable> [core_range]

#########################
# ─── KERNEL CONFIG ─── #
#########################
# Ultra-low latency kernel parameters
BASE_PARAMS="isolcpus={CORES} nohz_full={CORES} housekeeping=nohz,cpus:0 intel_pstate=disable nosmt intel_idle.max_cstate=0 processor.max_cstate=0 mitigations=off"
#########################

set -euo pipefail

# Check if running as root
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

if [[ $# -lt 1 ]]; then
    echo "Usage: $0 <enable|disable> [core_range]"
    exit 1
fi

ACTION="$1"
CORE_RANGE="${2:-1-27}"
GRUB_CONFIG="/etc/default/grub"


case "$ACTION" in
    enable)
        # Build kernel parameters
        PERF_PARAMS="${BASE_PARAMS//\{CORES\}/${CORE_RANGE}}"

        # Replace the line
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$PERF_PARAMS\"|" "$GRUB_CONFIG"

        # Update GRUB
        update-grub
        echo "✓ Kernel parameters updated. Reboot required."
        ;;

    disable)
        # Set empty parameters
        sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=""|' "$GRUB_CONFIG"

        # Update GRUB
        update-grub
        echo "✓ Kernel parameters disabled. Reboot required."
        ;;

    *)
        echo "Error: Invalid action '$ACTION'"
        exit 1
        ;;
esac
