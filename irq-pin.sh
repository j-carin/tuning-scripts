#!/usr/bin/env bash
#
#  nic_lowlatency_setup.sh — NIC-specific latency tuning + IRQ pinning
#  (run as root; keeps going when a feature isn’t supported)

#########################
# ─── CONFIG START ───  #
#########################
QUEUE_COUNT="${3:-auto}"       # combined Rx+Tx queue pairs (default auto-matches core count)
RING_SIZE="${4:-1024}"          # small rings reduce latency (default or 4th arg)
#########################
# ───  CONFIG END  ───  #
#########################

# Get interface - use provided arg or auto-detect
if [[ $# -ge 2 ]]; then
    IFACE="$2"
else
    IFACE=$(./common/get_interface.sh 2>/dev/null)
    if [[ -z "$IFACE" ]]; then
        echo "Error: Could not auto-detect interface. Please specify manually."
        echo "Usage: $0 <core_range> [interface] [queue_count] [ring_size]"
        exit 1
    fi
    echo "Auto-detected interface: $IFACE"
fi

# Parse core range argument
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <core_range> [interface] [queue_count] [ring_size]"
  echo "Example: $0 9-16 eno12409np1 8 256"
  exit 1
fi

CORE_RANGE="$1"

# Parse core range into array
if [[ "$CORE_RANGE" =~ ^([0-9]+)-([0-9]+)$ ]]; then
  START_CORE="${BASH_REMATCH[1]}"
  END_CORE="${BASH_REMATCH[2]}"

  if [[ $START_CORE -gt $END_CORE ]]; then
    echo "Error: Start core ($START_CORE) cannot be greater than end core ($END_CORE)"
    exit 1
  fi

  CORE_LIST=()
  for ((core=START_CORE; core<=END_CORE; core++)); do
    CORE_LIST+=("$core")
  done
else
  echo "Error: Invalid core range format. Use format like '9-16'"
  exit 1
fi

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

