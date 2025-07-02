#!/usr/bin/env bash
#
#  nic.sh — Network interface configuration for low-latency tuning
#  (run as root; keeps going when a feature isn't supported)

# Default values
RING_SIZE="1024"
IFACE=""
QUEUE_COUNT="auto"

# Function to show usage
usage() {
    echo "Usage: $0 [-i interface] [-r ring_size] [-q queue_count]"
    echo "Example: $0 -r 512"
    echo "Example: $0 -i eno12409np1 -r 256 -q 8"
    echo ""
    echo "Options:"
    echo "  -i <interface>    Network interface (auto-detected if not specified)"
    echo "  -r <ring_size>    Ring buffer size (default: 1024)"
    echo "  -q <queue_count>  Number of queue pairs (default: auto)"
    echo "  -h                Show this help message"
    exit 1
}

# Parse command line arguments
while getopts "i:r:q:h" opt; do
    case $opt in
        i) IFACE="$OPTARG" ;;
        r) RING_SIZE="$OPTARG" ;;
        q) QUEUE_COUNT="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Get interface - use provided arg or auto-detect
if [[ -z "$IFACE" ]]; then
    IFACE=$(./common/get_interface.sh 2>/dev/null)
    if [[ -z "$IFACE" ]]; then
        echo "Error: Could not auto-detect interface. Please specify with -i"
        exit 1
    fi
    echo "Auto-detected interface: $IFACE"
fi

set -uo pipefail

log_fail() { printf '    ✗ %s\n' "$1"; }

###############################################################################
echo ">>> Checking and temporarily disabling RDMA if needed"
RDMA_WAS_LOADED=false
if lsmod | grep -q "irdma"; then
  echo "    RDMA detected, temporarily disabling for queue configuration"
  RDMA_WAS_LOADED=true
  rmmod irdma 2>/dev/null || log_fail "failed to remove irdma module"
  sleep 1  # give time for module unload
else
  echo "    No RDMA detected"
fi

###############################################################################
echo ">>> 1. Disabling pause frames and EEE on $IFACE"

# Pause frames
ethtool -A "$IFACE" rx off tx off 2>/dev/null || \
  log_fail "pause-frame disable not supported"

# EEE
ethtool --set-eee "$IFACE" eee off 2>/dev/null || true  # silently ignore

###############################################################################
echo ">>> 2. Configuring interrupt moderation (1 µs, adaptive off)"
if ! ethtool -C "$IFACE" adaptive-rx off adaptive-tx off 2>/dev/null; then
    log_fail "adaptive mode disable not supported"
fi
if ! ethtool -C "$IFACE" rx-usecs 1 tx-usecs 1 2>/dev/null; then
    log_fail "could not set rx/tx-usecs"
fi

###############################################################################
echo ">>> 3. Setting RX/TX ring size to $RING_SIZE"
ethtool -G "$IFACE" rx $RING_SIZE tx $RING_SIZE 2>/dev/null || \
  log_fail "driver refused ring-size change"

###############################################################################
if [[ "$QUEUE_COUNT" != "auto" ]]; then
  echo ">>> 4. Resizing to $QUEUE_COUNT combined queues"
  ethtool -L "$IFACE" combined $QUEUE_COUNT 2>/dev/null || \
    log_fail "driver refused queue resize (may already match)"
else
  echo ">>> 4. Skipping queue resize (auto mode)"
fi


###############################################################################
echo ">>> Re-enabling RDMA if it was previously loaded"
if [[ "$RDMA_WAS_LOADED" == "true" ]]; then
  echo "    Re-loading irdma module"
  modprobe irdma 2>/dev/null || log_fail "failed to reload irdma module"
  sleep 2  # give time for module to initialize
else
  echo "    RDMA was not previously loaded, skipping"
fi

echo ">>> NIC configuration complete (errors above are non-fatal)."