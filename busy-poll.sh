#!/usr/bin/env bash
#
# busy-poll.sh — Network busy polling configuration
# Usage: ./busy-poll.sh <enable|disable> [microseconds]
# Example: ./busy-poll.sh enable 50
# Example: ./busy-poll.sh disable

set -euo pipefail

show_usage() {
    echo "Usage: $0 <enable|disable> [microseconds]"
    echo "Examples:"
    echo "  $0 enable 50    # Enable busy polling with 50μs timeout"
    echo "  $0 disable      # Disable busy polling"
    echo "  $0 status       # Show current settings"
    exit 1
}

show_status() {
    echo "Current busy polling settings:"
    echo "  busy_read: $(cat /proc/sys/net/core/busy_read)μs"
    echo "  busy_poll: $(cat /proc/sys/net/core/busy_poll)μs"
    echo ""
    if [[ $(cat /proc/sys/net/core/busy_read) -eq 0 ]]; then
        echo "Status: DISABLED"
    else
        echo "Status: ENABLED"
    fi
}

if [[ $# -lt 1 ]]; then
    show_usage
fi

ACTION="$1"
MICROSECONDS="${2:-50}"

case "$ACTION" in
    enable)
        echo "Enabling busy polling with ${MICROSECONDS}μs timeout..."
        echo "$MICROSECONDS" > /proc/sys/net/core/busy_read
        echo "$MICROSECONDS" > /proc/sys/net/core/busy_poll
        echo "✓ Busy polling enabled"
        show_status
        ;;
    disable)
        echo "Disabling busy polling..."
        echo 0 > /proc/sys/net/core/busy_read
        echo 0 > /proc/sys/net/core/busy_poll
        echo "✓ Busy polling disabled"
        show_status
        ;;
    status)
        show_status
        ;;
    *)
        echo "Error: Invalid action '$ACTION'"
        show_usage
        ;;
esac