#!/usr/bin/env bash
#
# kernel-config.sh — configure kernel boot parameters for low-latency work
# Usage: ./kernel-config.sh <enable|disable> [core_range]

#########################
# ─── KERNEL CONFIG ─── #
#########################
# Ultra-low-latency kernel parameters
#   • {CORES}         → range of isolated CPUs   (e.g. 1-27)
#   • housekeeping    → everything else stays   (here: CPU 0)
#
BASE_PARAMS="housekeeping=cpus:0 \
            intel_pstate=disable \
            nosmt \
            intel_idle.max_cstate=1 \
            processor.max_cstate=1 \
            mitigations=off \
            intel_iommu=off \
            iommu=off"
#########################

set -euo pipefail

[[ $EUID -ne 0 ]] && { echo "Run as root (sudo)"; exit 1; }
[[ $# -lt 1 ]]    && { echo "Usage: $0 <enable|disable> [core_range]"; exit 1; }

ACTION="$1"
CORE_RANGE="${2:-1-27}"
GRUB_CONFIG="/etc/default/grub"

case "$ACTION" in
  enable)
      # Inject the chosen core mask
      PERF_PARAMS="${BASE_PARAMS//\{CORES\}/${CORE_RANGE}}"

      sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${PERF_PARAMS}\"|" \
            "$GRUB_CONFIG"

      update-grub
      echo "✓ Low-latency kernel parameters installed. Reboot to apply."
      ;;
  disable)
      sed -i 's|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=""|' "$GRUB_CONFIG"
      update-grub
      echo "✓ Kernel parameters cleared. Reboot to revert."
      ;;
  *)
      echo "Error: invalid action '$ACTION' (use enable|disable)"
      exit 1
      ;;
esac

