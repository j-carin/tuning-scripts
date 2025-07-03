#!/usr/bin/env bash
#
# offloads.sh — Network offload configuration (GRO/GSO/TSO/LRO)
# Usage: ./offloads.sh <enable|disable> [interface]
# Example: ./offloads.sh disable eno12409np1
# Example: ./offloads.sh enable eth0

set -euo pipefail

show_usage() {
    echo "Usage: $0 <enable|disable|status> [interface]"
    echo "Examples:"
    echo "  $0 disable eno12409np1    # Disable offloads for low latency"
    echo "  $0 enable eth0            # Enable offloads for throughput"
    echo "  $0 status eno12409np1     # Show current offload settings"
    exit 1
}

show_status() {
    local iface="$1"
    echo "Current offload settings for $iface:"
    ethtool -k "$iface" | grep -E "offload.*:"
}

get_offload_flags() {
    local iface="$1"
    # Get all supported flags from ethtool
    mapfile -t SUPPORTED_FLAGS < <(ethtool -k "$iface" | awk -F':' '{gsub(/^[ \t]+|[ \t]+$/, "", $1); print $1}' | grep -v '^$')
    
    # Define the offloads we want to control - critical for low latency
    declare -a WANT_FLAGS=(
        generic-receive-offload 
        generic-segmentation-offload 
        tcp-segmentation-offload 
        large-receive-offload
        rx-gro-hw
    )
    
    # Find which ones are supported
    TO_CONTROL=()
    for flag in "${WANT_FLAGS[@]}"; do
        if printf '%s\n' "${SUPPORTED_FLAGS[@]}" | grep -qx "$flag"; then
            TO_CONTROL+=("$flag")
        fi
    done
    
    printf '%s\n' "${TO_CONTROL[@]}"
}

if [[ $# -lt 1 ]]; then
    show_usage
fi

ACTION="$1"

# Get interface - use provided arg or auto-detect
if [[ $# -ge 2 ]]; then
    IFACE="$2"
else
    IFACE=$(./common/get_interface.sh 2>/dev/null)
    if [[ -z "$IFACE" ]]; then
        echo "Error: Could not auto-detect interface. Please specify manually."
        echo "Usage: $0 <enable|disable|status> [interface]"
        exit 1
    fi
    echo "Auto-detected interface: $IFACE"
fi

# Check if interface exists
if ! ip link show "$IFACE" &>/dev/null; then
    echo "Error: Interface '$IFACE' not found"
    exit 1
fi

case "$ACTION" in
    disable)
        echo "Disabling offloads on $IFACE for low latency..."
        
        # Get controllable offload flags
        mapfile -t FLAGS < <(get_offload_flags "$IFACE")
        
        if [[ ${#FLAGS[@]} -eq 0 ]]; then
            echo "  No controllable offload flags found"
        else
            # Build ethtool arguments
            ARGS=()
            for flag in "${FLAGS[@]}"; do
                ARGS+=("$flag" off)
            done
            
            if ethtool -K "$IFACE" "${ARGS[@]}" 2>/dev/null; then
                echo "✓ Offloads disabled: ${FLAGS[*]}"
            else
                echo "✗ Some offloads could not be disabled (may be fixed)"
            fi
        fi
        
        # Set MTU to 1500
        echo "Setting MTU to 1500..."
        if ip link set dev "$IFACE" mtu 1500; then
            echo "✓ MTU set to 1500"
        else
            echo "✗ Failed to set MTU"
        fi
        
        echo ""
        show_status "$IFACE"
        ;;
        
    enable)
        echo "Enabling offloads on $IFACE for throughput..."
        
        # Get controllable offload flags
        mapfile -t FLAGS < <(get_offload_flags "$IFACE")
        
        if [[ ${#FLAGS[@]} -eq 0 ]]; then
            echo "  No controllable offload flags found"
        else
            # Build ethtool arguments
            ARGS=()
            for flag in "${FLAGS[@]}"; do
                ARGS+=("$flag" on)
            done
            
            if ethtool -K "$IFACE" "${ARGS[@]}" 2>/dev/null; then
                echo "✓ Offloads enabled: ${FLAGS[*]}"
            else
                echo "✗ Some offloads could not be enabled"
            fi
        fi
        
        # Set MTU to 1500
        echo "Setting MTU to 1500..."
        if ip link set dev "$IFACE" mtu 1500; then
            echo "✓ MTU set to 1500"
        else
            echo "✗ Failed to set MTU"
        fi
        
        echo ""
        show_status "$IFACE"
        ;;
        
    status)
        show_status "$IFACE"
        ;;
        
    *)
        echo "Error: Invalid action '$ACTION'"
        show_usage
        ;;
esac