#!/usr/bin/env bash
set -euo pipefail

[[ $# -ne 1 ]] && { echo "Usage: $0 <core_range>"; exit 1; }
[[ $EUID -ne 0 ]] && { echo "Run as root"; exit 1; }
[[ ! "$1" =~ ^[0-9]+-[0-9]+$ ]] && { echo "Invalid format. Use: 9-16"; exit 1; }

cd "$(dirname "$0")"

echo "Tuning for cores: $1"
./cpu.sh
./irq-pin.sh -c "$1"
./offloads.sh disable
./busy-poll.sh enable 50
echo "Done"
