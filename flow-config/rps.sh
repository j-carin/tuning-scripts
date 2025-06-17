#!/usr/bin/env bash

# Check if running as root/sudo
if [ "$EUID" -ne 0 ]; then
    echo "Error: This script must be run as root (use sudo)"
    exit 1
fi

# Check for enable/disable argument
if [ $# -ne 1 ] || { [ "$1" != "enable" ] && [ "$1" != "disable" ]; }; then
    echo "Usage: $0 {enable|disable}"
    echo "  enable  - Configure RPS settings"
    echo "  disable - Reset RPS settings to defaults"
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
    echo "Enabling RPS for interface: $INTERFACE"

    # point every queue's CPU-affinity mask at all online CPUs
    for q in /sys/class/net/$INTERFACE/queues/rx-*; do
      echo ffff > "$q"/rps_cpus
    done

    echo "RPS enabled for $INTERFACE"

elif [ "$ACTION" == "disable" ]; then
    echo "Disabling RPS for interface: $INTERFACE"

    # reset CPU-affinity mask to 0 (disabled)
    for q in /sys/class/net/$INTERFACE/queues/rx-*; do
      echo 0 > "$q"/rps_cpus
    done

    echo "RPS disabled for $INTERFACE"
fi