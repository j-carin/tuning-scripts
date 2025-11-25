#!/usr/bin/env bash
#
#  flow-steer.sh — Configure ntuple/Flow Director rules for port-based steering
#  (run as root)
#
#  Steers traffic based on source port ranges to specific queues/CPUs.
#  Each CPU gets a contiguous range of source ports.
#
#  Example:
#    ./flow-steer.sh -i 400gp1 -p 20000 -n 25 -c 1-8 -d 11211
#    This creates rules:
#      src-port 20000-20024, dst-port 11211 -> queue 1
#      src-port 20025-20049, dst-port 11211 -> queue 2
#      ...
#      src-port 20175-20199, dst-port 11211 -> queue 8

set -euo pipefail

IFACE=""
BASE_PORT=""
TOTAL_CONNS=""
CORE_RANGE=""
DST_PORT=""
RESET=false

usage() {
    echo "Usage: $0 -i <interface> -p <base_port> -n <total_conns> -c <cpu_list> -d <dst_port>"
    echo "       $0 -i <interface> --reset"
    echo ""
    echo "Options:"
    echo "  -i <interface>      Network interface (e.g., 400gp1)"
    echo "  -p <base_port>      Starting source port (e.g., 20000)"
    echo "  -n <total_conns>    Total number of connections (max 512, creating 1024 rules)"
    echo "  -c <cpu_list>       CPU/queue list (e.g., 1-8 or 1,3,5)"
    echo "  -d <dst_port>       Destination port to match (e.g., 11211)"
    echo "  --reset             Clear all ntuple rules and exit"
    echo ""
    echo "Note: This script creates both TCP and UDP rules for each connection."
    echo ""
    echo "Example:"
    echo "  $0 -i 400gp1 -p 20000 -n 200 -c 1-8 -d 11211"
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -i) IFACE="$2"; shift 2 ;;
        -p) BASE_PORT="$2"; shift 2 ;;
        -n) TOTAL_CONNS="$2"; shift 2 ;;
        -c) CORE_RANGE="$2"; shift 2 ;;
        -d) DST_PORT="$2"; shift 2 ;;
        --reset) RESET=true; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# Validate interface is always required
[[ -z "$IFACE" ]] && { echo "Error: -i <interface> is required"; usage; }

# Reset mode: clear all rules and exit
if [[ "$RESET" == true ]]; then
    echo "Clearing all ntuple rules on $IFACE..."

    # Get all rule IDs and delete them
    RULE_IDS=$(ethtool -n "$IFACE" 2>/dev/null | grep "Filter:" | awk '{print $2}')
    if [[ -z "$RULE_IDS" ]]; then
        echo "No rules to delete."
    else
        COUNT=0
        for id in $RULE_IDS; do
            ethtool -U "$IFACE" delete "$id" 2>/dev/null || true
            COUNT=$((COUNT + 1))
        done
        echo "Deleted $COUNT rules."
    fi

    # Verify
    ethtool -n "$IFACE" | head -3
    exit 0
fi

# For non-reset mode, all arguments are required
[[ -z "$BASE_PORT" ]] && { echo "Error: -p <base_port> is required"; usage; }
[[ -z "$TOTAL_CONNS" ]] && { echo "Error: -n <total_conns> is required"; usage; }
[[ -z "$CORE_RANGE" ]] && { echo "Error: -c <cpu_list> is required"; usage; }
[[ -z "$DST_PORT" ]] && { echo "Error: -d <dst_port> is required"; usage; }

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
NUM_CPUS=${#CORE_LIST[@]}

# Validate total connections is a multiple of CPU count
if (( TOTAL_CONNS % NUM_CPUS != 0 )); then
    echo "Error: total connections ($TOTAL_CONNS) must be a multiple of CPU count ($NUM_CPUS)"
    exit 1
fi

# Limit check: Max 1024 rules allowed.
# Since we create 2 rules per connection (TCP + UDP), max connections = 512.
if (( TOTAL_CONNS > 512 )); then
    echo "Error: total connections ($TOTAL_CONNS) exceeds limit of 512."
    echo "       (This would create > 1024 rules because TCP and UDP are both enabled)"
    exit 1
fi

CONNS_PER_CPU=$((TOTAL_CONNS / NUM_CPUS))

echo "Interface: $IFACE"
echo "CPUs/Queues: ${CORE_LIST[*]} ($NUM_CPUS total)"
echo "Base port: $BASE_PORT"
echo "Total connections: $TOTAL_CONNS"
echo "Connections per CPU: $CONNS_PER_CPU"
echo "Destination port: $DST_PORT"
echo ""

# Enable ntuple filtering
echo "Enabling ntuple filtering..."
ethtool -K "$IFACE" ntuple on

# Create rules
echo "Creating flow steering rules (Round-Robin)..."

for ((i=0; i<TOTAL_CONNS; i++)); do
    # Calculate current source port
    p=$((BASE_PORT + i))

    # Calculate target queue index (round-robin)
    idx=$((i % NUM_CPUS))
    queue=${CORE_LIST[$idx]}

    for proto in tcp4 udp4; do
        if ethtool -U "$IFACE" flow-type "$proto" src-port "$p" dst-port "$DST_PORT" action "$queue"; then
            echo "    Added rule ($proto) src-port $p -> queue $queue"
        else
            echo "    Failed to add $proto rule for src-port $p -> queue $queue"
        fi
    done
done

echo ""
echo "Done. Total rules:"
ethtool -n "$IFACE" | head -3

echo ""
echo "To verify during load:"
echo "  ethtool -S $IFACE | grep -E 'fdir|rx_queue'"
echo "  watch -n1 'grep $IFACE /proc/interrupts'"
