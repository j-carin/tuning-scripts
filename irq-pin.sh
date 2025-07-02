#!/usr/bin/env bash
#
#  irq-pin.sh — IRQ pinning for network interfaces
#  (run as root)

# Default values
QUEUE_COUNT="auto"
IFACE=""
CORE_RANGE=""

# Function to show usage
usage() {
    echo "Usage: $0 -c <core_range> [-i interface] [-q queue_count]"
    echo "Example: $0 -c 10-11"
    echo "Example: $0 -c 9-16 -i eno12409np1 -q 8"
    echo ""
    echo "Options:"
    echo "  -c <core_spec>    CPU cores (e.g., 11, 10-11, 9-16, 11,15-17) [REQUIRED]"
    echo "  -i <interface>    Network interface (auto-detected if not specified)"
    echo "  -q <queue_count>  Number of queue pairs (default: auto = core count)"
    echo "  -h                Show this help message"
    exit 1
}

# Parse command line arguments
while getopts "c:i:q:h" opt; do
    case $opt in
        c) CORE_RANGE="$OPTARG" ;;
        i) IFACE="$OPTARG" ;;
        q) QUEUE_COUNT="$OPTARG" ;;
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
# Allow more queues than cores for round-robin assignment
if [[ $QUEUE_COUNT -lt ${#CORE_LIST[@]} ]]; then
  echo "Error: QUEUE_COUNT ($QUEUE_COUNT) cannot be less than core count (${#CORE_LIST[@]})"
  exit 1
fi

log_fail() { printf '    ✗ %s\n' "$1"; }

###############################################################################
echo ">>> Stopping irqbalance so affinities stay fixed"
if systemctl list-unit-files | grep -q '^irqbalance\.service'; then
  systemctl --quiet stop irqbalance.service 2>/dev/null || true
elif command -v service &>/dev/null; then
  service irqbalance stop 2>/dev/null || true
fi

###############################################################################
echo ">>> Pinning each queue's IRQ to its core"
mask_of() { printf "%x" $((1 << "$1")); }

mapfile -t IRQS < <(
  grep -iE "$IFACE.*TxRx" /proc/interrupts | awk '{print $1}' | tr -d ':' | \
  head -n "$QUEUE_COUNT"
)
if [[ ${#IRQS[@]} -ne $QUEUE_COUNT ]]; then
  log_fail "found ${#IRQS[@]} IRQs, expected $QUEUE_COUNT — pinning skipped"
else
  for i in $(seq 0 $((QUEUE_COUNT-1))); do
    irq=${IRQS[$i]}
    # Round-robin assignment: use modulo to cycle through available cores
    core_idx=$((i % ${#CORE_LIST[@]}))
    core=${CORE_LIST[$core_idx]}
    echo "    IRQ $irq → CPU$core"
    echo "$(mask_of $core)" > "/proc/irq/$irq/smp_affinity" 2>/dev/null || \
      log_fail "IRQ $irq affinity write failed"
  done
fi

###############################################################################
echo ">>> Disabling RPS (receive packet steering)"
for q in /sys/class/net/$IFACE/queues/rx-*; do
  echo 0 > "$q"/rps_cpus 2>/dev/null || log_fail "$q rps_cpus write failed"
done

###############################################################################
echo ">>> Programming XPS to match IRQ/Core affinity"
if [[ ${#IRQS[@]} -ne $QUEUE_COUNT ]]; then
  log_fail "IRQ count mismatch – cannot set XPS"
else
  for i in $(seq 0 $((QUEUE_COUNT-1))); do
    core_idx=$((i % ${#CORE_LIST[@]}))
    core=${CORE_LIST[$core_idx]}
    mask=$(mask_of $core)
    echo "    tx-$i → CPU$core (mask $mask)"
    echo $mask > /sys/class/net/$IFACE/queues/tx-$i/xps_cpus \
         2>/dev/null || log_fail "tx-$i xps_cpus write failed"
  done
fi

echo ">>> IRQ pinning complete."