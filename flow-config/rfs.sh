#!/usr/bin/env bash

# Check if running as root/sudo
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

# Check for enable/disable argument
if [ $# -ne 1 ] || { [ "$1" != "enable" ] && [ "$1" != "disable" ]; }; then
    echo "Usage: $0 {enable|disable}"
    echo "  enable  - Configure RFS settings"
    echo "  disable - Reset RFS settings to defaults"
    exit 1
fi

ACTION="$1"

# Get the correct network interface
INTERFACE=$(../common/get_interface.sh)
if [ -z "$INTERFACE" ]; then
    echo "Error: Could not determine network interface"
    exit 1
fi

if [ "$ACTION" == "enable" ]; then
    echo "Enabling RFS for interface: $INTERFACE"

    # allocate a global flow-table with 64 K entries
    echo 65536 > /proc/sys/net/core/rps_sock_flow_entries

    # size each Rx queue's per-queue table to 4096 entries
    for q in /sys/class/net/$INTERFACE/queues/rx-*; do
      echo 4096 > "$q"/rps_flow_cnt
    done

    # point every queue's CPU-affinity mask at all online CPUs
    for q in /sys/class/net/$INTERFACE/queues/rx-*; do
      echo ffff > "$q"/rps_cpus
    done

    echo "RFS enabled for $INTERFACE"

elif [ "$ACTION" == "disable" ]; then
    echo "Disabling RFS for interface: $INTERFACE"

    # reset global flow-table to 0 (disabled)
    echo 0 > /proc/sys/net/core/rps_sock_flow_entries

    # reset each Rx queue's per-queue table to 0 (disabled)
    for q in /sys/class/net/$INTERFACE/queues/rx-*; do
      echo 0 > "$q"/rps_flow_cnt
    done

    # reset CPU-affinity mask to 0 (disabled)
    for q in /sys/class/net/$INTERFACE/queues/rx-*; do
      echo 0 > "$q"/rps_cpus
    done

    echo "RFS disabled for $INTERFACE"
fi