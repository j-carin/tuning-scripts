#!/usr/bin/env bash
#
#  irq-pin.sh — NIC-specific latency tuning + IRQ pinning
#  (run as root; keeps going when a feature isn’t supported)

# Default values
QUEUE_COUNT="auto"
RING_SIZE="1024"
IFACE=""
CORE_RANGE=""

# Function to show usage
usage() {
    echo "Usage: $0 -c <core_range> [-i interface] [-q queue_count] [-r ring_size]"
    echo "Example: $0 -c 10-11 -q 512"
    echo "Example: $0 -c 9-16 -i eno12409np1 -q 8 -r 256"
    echo ""
    echo "Options:"
    echo "  -c <core_spec>    CPU cores (e.g., 11, 10-11, 9-16, 11,15-17) [REQUIRED]"
    echo "  -i <interface>    Network interface (auto-detected if not specified)"
    echo "  -q <queue_count>  Number of queue pairs (default: auto = core count)"
    echo "  -r <ring_size>    Ring buffer size (default: 1024)"
    echo "  -h                Show this help message"
    exit 1
}

# Parse command line arguments
while getopts "c:i:q:r:h" opt; do
    case $opt in
        c) CORE_RANGE="$OPTARG" ;;
        i) IFACE="$OPTARG" ;;
        q) QUEUE_COUNT="$OPTARG" ;;
        r) RING_SIZE="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

# Check required arguments
if [[ -z "$CORE_RANGE" ]]; then
    echo "Error: Core range (-c) is required"
    usage
fi

# Get interface - use provided arg or auto-detect
if [[ -z "$IFACE" ]]; then
    IFACE=$(./common/get_interface.sh 2>/dev/null)
    if [[ -z "$IFACE" ]]; then
        echo "Error: Could not auto-detect interface. Please specify with -i"
        exit 1
    fi
    echo "Auto-detected interface: $IFACE"
fi

# Parse core specification into array
parse_cores() {
    local spec="$1"
    local cores=()
    
    # Split by comma
    IFS=',' read -ra PARTS <<< "$spec"
    
    for part in "${PARTS[@]}"; do
        part=$(echo "$part" | tr -d ' ')  # Remove spaces
        
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            # Range format: N-M
            local start_core="${BASH_REMATCH[1]}"
            local end_core="${BASH_REMATCH[2]}"
            
            if [[ $start_core -gt $end_core ]]; then
                echo "Error: Invalid range $part (start > end)"
                exit 1
            fi
            
            for ((core=start_core; core<=end_core; core++)); do
                cores+=("$core")
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            # Single core: N
            cores+=("$part")
        else
            echo "Error: Invalid core specification '$part'. Use formats like: 11, 10-11, or 11,15-17"
            exit 1
        fi
    done
    
    # Remove duplicates and sort
    printf '%s\n' "${cores[@]}" | sort -nu
}

CORE_LIST=($(parse_cores "$CORE_RANGE"))

# Auto-set queue count to match core count if not specified
if [[ "$QUEUE_COUNT" == "auto" ]]; then
  QUEUE_COUNT=${#CORE_LIST[@]}
  echo "Auto-setting QUEUE_COUNT to ${QUEUE_COUNT} to match core count"
fi

set -uo pipefail
[[ ${#CORE_LIST[@]} -eq $QUEUE_COUNT ]] || {
  echo "CORE_LIST length (${#CORE_LIST[@]}) ≠ QUEUE_COUNT ($QUEUE_COUNT)"; exit 1; }

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
echo ">>> Stopping irqbalance so affinities stay fixed"
if systemctl list-unit-files | grep -q '^irqbalance\.service'; then
  systemctl --quiet stop irqbalance.service 2>/dev/null || true
elif command -v service &>/dev/null; then
  service irqbalance stop 2>/dev/null || true
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
echo ">>> 4. Resizing to $QUEUE_COUNT combined queues"
ethtool -L "$IFACE" combined $QUEUE_COUNT 2>/dev/null || \
  log_fail "driver refused queue resize (may already match)"

###############################################################################
echo ">>> 5. Pinning each queue’s IRQ to its core"
mask_of() { printf "%x" $((1 << "$1")); }

mapfile -t IRQS < <(
  grep -iE "$IFACE.*TxRx" /proc/interrupts | awk '{print $1}' | tr -d ':' | \
  head -n "$QUEUE_COUNT"
)
if [[ ${#IRQS[@]} -ne $QUEUE_COUNT ]]; then
  log_fail "found ${#IRQS[@]} IRQs, expected $QUEUE_COUNT — pinning skipped"
else
  for i in $(seq 0 $((QUEUE_COUNT-1))); do
    irq=${IRQS[$i]} core=${CORE_LIST[$i]}
    echo "    IRQ $irq → CPU$core"
    echo "$(mask_of $core)" > "/proc/irq/$irq/smp_affinity" 2>/dev/null || \
      log_fail "IRQ $irq affinity write failed"
  done
fi

###############################################################################
echo ">>> 6. Disabling RPS/XPS (software steering)"
for q in /sys/class/net/$IFACE/queues/rx-*; do
  echo 0 > "$q"/rps_cpus 2>/dev/null || log_fail "$q rps_cpus write failed"
done
for q in /sys/class/net/$IFACE/queues/tx-*; do
  echo 0 > "$q"/xps_cpus 2>/dev/null || log_fail "$q xps_cpus write failed"
done

###############################################################################
echo ">>> Re-enabling RDMA if it was previously loaded"
if [[ "$RDMA_WAS_LOADED" == "true" ]]; then
  echo "    Re-loading irdma module"
  modprobe irdma 2>/dev/null || log_fail "failed to reload irdma module"
  sleep 2  # give time for module to initialize
else
  echo "    RDMA was not previously loaded, skipping"
fi

echo ">>> NIC tuning complete (errors above are non-fatal)."

