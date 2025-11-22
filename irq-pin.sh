#!/usr/bin/env bash
#
#  irq-pin.sh — IRQ pinning for network interfaces
#  (run as root)
#
#  Strategy:
#  1. Ensure enough channels exist (>= max core + 1)
#  2. Configure RSS to steer traffic only to channels matching selected cores
#  3. Pin channel N's IRQ to CPU N (natural alignment for ndo_xdp_xmit)

set -euo pipefail

IFACE=""
CORE_RANGE=""

usage() {
    echo "Usage: $0 -c <core_range> [-i interface]"
    echo "Example: $0 -c 2"
    echo "Example: $0 -c 10-11 -i 400gp1"
    exit 1
}

while getopts "c:i:h" opt; do
    case $opt in
        c) CORE_RANGE="$OPTARG" ;;
        i) IFACE="$OPTARG" ;;
        *) usage ;;
    esac
done

[[ -z "$CORE_RANGE" ]] && usage

# Auto-detect interface if not specified
if [[ -z "$IFACE" ]]; then
    IFACE=$(./common/get_interface.sh 2>/dev/null) || { echo "Error: specify interface with -i"; exit 1; }
fi

# Parse core spec (e.g., "2", "10-11", "1,3,5") into array
parse_cores() {
    local spec="$1"
    local cores=()
    IFS=',' read -ra PARTS <<< "$spec"
    for part in "${PARTS[@]}"; do
        part=$(echo "$part" | tr -d ' ')
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            for ((c=${BASH_REMATCH[1]}; c<=${BASH_REMATCH[2]}; c++)); do
                cores+=("$c")
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            cores+=("$part")
        else
            echo "Error: invalid core spec '$part'"; exit 1
        fi
    done
    printf '%s\n' "${cores[@]}" | sort -nu
}

CORE_LIST=($(parse_cores "$CORE_RANGE"))
MAX_CORE=$(printf '%s\n' "${CORE_LIST[@]}" | sort -n | tail -1)
MIN_CHANNELS=$((MAX_CORE + 1))

echo "Cores: ${CORE_LIST[*]} (need >= $MIN_CHANNELS channels)"

# Disable RDMA
echo "install irdma /bin/true" > /etc/modprobe.d/irdma-blacklist.conf 2>/dev/null || true
rmmod irdma 2>/dev/null || true

# Ensure enough channels
CURRENT=$(ethtool -l "$IFACE" 2>/dev/null | grep -A5 "Current" | grep "Combined:" | awk '{print $2}')
if [[ $CURRENT -lt $MIN_CHANNELS ]]; then
    echo "Increasing channels: $CURRENT -> $MIN_CHANNELS"
    ethtool -L "$IFACE" combined "$MIN_CHANNELS"
    ip link set "$IFACE" up
    CURRENT=$MIN_CHANNELS
fi

# Stop irqbalance
systemctl stop irqbalance.service 2>/dev/null || true

# Configure RSS to only use selected channels
WEIGHTS=""
for ((q=0; q<CURRENT; q++)); do
    match=0
    for core in "${CORE_LIST[@]}"; do [[ $q -eq $core ]] && match=1 && break; done
    WEIGHTS+="$match "
done
echo "RSS weights: $WEIGHTS"
ethtool -X "$IFACE" weight $WEIGHTS

# Get IRQs
PCI=$(ethtool -i "$IFACE" 2>/dev/null | grep bus-info | awk '{print $2}')
mapfile -t IRQS < <(grep -E "${PCI}.*mlx5_comp[0-9]+@pci" /proc/interrupts | awk '{print $1}' | tr -d ':' | sort -V)
[[ ${#IRQS[@]} -eq 0 ]] && mapfile -t IRQS < <(grep -iE "$IFACE.*TxRx" /proc/interrupts | awk '{print $1}' | tr -d ':')

# Pin channel N's IRQ to CPU N
mask_of() { printf "%x" $((1 << "$1")); }
for core in "${CORE_LIST[@]}"; do
    echo "Channel $core -> CPU $core"
    echo "$(mask_of $core)" > "/proc/irq/${IRQS[$core]}/smp_affinity"
    echo "$(mask_of $core)" > "/sys/class/net/$IFACE/queues/tx-$core/xps_cpus" 2>/dev/null || true
done

# Disable RPS
for q in /sys/class/net/$IFACE/queues/rx-*; do
    echo 0 > "$q/rps_cpus" 2>/dev/null || true
done

# Re-enable RDMA
rm -f /etc/modprobe.d/irdma-blacklist.conf
