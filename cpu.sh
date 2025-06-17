#!/usr/bin/env bash
#
#  cpu_lowlatency_setup.sh — minimise scheduling / wake-up latency
#  (run as root; writes directly to sysfs; keeps going on individual failures)

#########################
# ─── CONFIG START ───  #
#########################
DATAPLANE_CORES="1-27"   # cores running the hot path
DISABLE_SMT=true        # true → echo off > smt/control
#########################
# ───  CONFIG END  ───  #
#########################

# Abort only on unbound variables and pipeline errors; allow individual writes to fail
set -uo pipefail

log_fail() { printf '    ✗ %s\n' "$1"; }

###############################################################################
echo ">>> Governor → performance (per cpufreq policy)"
for pol in /sys/devices/system/cpu/cpufreq/policy*; do
    gov="$pol/scaling_governor"
    if ! echo performance > "$gov" 2>/dev/null; then
        log_fail "policy ${pol##*/policy}: could not set governor"
    fi
done

echo ">>> Locking min_freq = max_freq"
for pol in /sys/devices/system/cpu/cpufreq/policy*; do
    min="$pol/scaling_min_freq"; max="$pol/scaling_max_freq"
    if [[ -e $min && -e $max ]]; then
        if ! cat "$max" > "$min" 2>/dev/null; then
            log_fail "policy ${pol##*/policy}: could not lock min_freq"
        fi
    fi
done

###############################################################################
echo ">>> Disabling turbo boost (Intel only)"
if [[ -w /sys/devices/system/cpu/intel_pstate/no_turbo ]]; then
    echo 1 > /sys/devices/system/cpu/intel_pstate/no_turbo || \
        log_fail "intel_pstate/no_turbo write failed"
fi

###############################################################################
echo ">>> Limiting C-states to C1 (module parameters)"
for f in /sys/module/intel_idle/parameters/max_cstate \
         /sys/module/processor/parameters/max_cstate; do
  [[ -w $f ]] && echo 1 > "$f" || log_fail "$(basename "$f") write failed"
done

echo ">>> Disabling individual CPU idle states (C1 and above)"
for cpu in /sys/devices/system/cpu/cpu*/cpuidle; do
    if [[ -d $cpu ]]; then
        # Disable all C-states except C0 (only keep C0 active)
        for state in "$cpu"/state[1-9]*; do
            if [[ -w $state/disable ]]; then
                echo 1 > "$state/disable" 2>/dev/null || \
                    log_fail "$(basename "$cpu")/$(basename "$state") disable failed"
            fi
        done
    fi
done

###############################################################################
echo ">>> Transparent Huge Pages → off"
echo never > /sys/kernel/mm/transparent_hugepage/enabled || \
    log_fail "THP disable failed"

echo ">>> Automatic NUMA balancing → off"
echo 0 > /proc/sys/kernel/numa_balancing || \
    log_fail "NUMA balancing disable failed"

echo ">>> Disabling swap"
swapoff -a 2>/dev/null || \
    log_fail "swap disable failed"

###############################################################################
if $DISABLE_SMT; then
  echo ">>> SMT (hyper-threads) → off"
  if [[ -w /sys/devices/system/cpu/smt/control ]]; then
    echo off > /sys/devices/system/cpu/smt/control || \
        log_fail "smt/control write failed"
  else
    log_fail "smt/control not writable or missing"
  fi
fi

echo ">>> CPU tuning complete (errors above are non-fatal)."

