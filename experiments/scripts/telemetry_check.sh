#!/bin/bash
# MANDATORY telemetry capability check. Every measurement job runs this first
# and FAILS FAST if a required source is missing, so no run can silently
# produce numbers from a degraded instrument set.
#
# Required (job aborts if any is unavailable):
#   NVML energy counter      nvmlDeviceGetTotalEnergyConsumption
#   NVML power               nvmlDeviceGetPowerUsage
#   nvidia-smi provenance    GPU UUID, driver, power limits, persistence
#   DCGM energy field 156    DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION
#   DCGM power field 155     DCGM_FI_DEV_POWER_USAGE
#
# Recorded but not required, because we MEASURED that the kernel denies them on
# 13 of 15 Frontenac nodes (RmProfilingAdminOnly=1 -> Result: -29):
#   DCGM DCP fields 1002/1005, Nsight Compute, CUPTI counters
# Their availability per node is written to the report as data. A denial is a
# finding, not a skipped step.
#
# Usage: bash telemetry_check.sh <output-file>
# Exit 0 = all required sources verified. Exit 1 = abort the job.

OUT="${1:-telemetry.txt}"
OPT="$HOME/energy-epp/opt"
IMG="$HOME/energy-epp/images/vllm-v0.30.0.sif"

if ! command -v module >/dev/null 2>&1; then
  source /cvmfs/soft.computecanada.ca/config/profile/bash.sh 2>/dev/null \
    || source "${LMOD_PKG:-/cvmfs/soft.computecanada.ca/custom/software/lmod/lmod}/init/bash" 2>/dev/null
fi
set -uo pipefail
module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"

DCGM_BIN="$OPT/dcgm4/usr/bin"
DCGM_LIB="$OPT/dcgm4/usr/lib64"
NSYS="$OPT/nsight/opt/nvidia/nsight-systems/2025.6.3/target-linux-x64/nsys"

FAIL=0
say() { printf '%s\n' "$*" | tee -a "$OUT"; }
req() { # $1 name, $2 ok(0/1), $3 detail
  if [ "$2" -eq 0 ]; then
    say "  [OK]       $1 — $3"
  else
    say "  [MISSING]  $1 — $3"
    FAIL=1
  fi
}

: > "$OUT"
say "=== MANDATORY telemetry check, $(date -Is) ==="
say "node: $(hostname)   job: ${SLURM_JOB_ID:-none}"
say ""

say "--- node capability facts (recorded with every run) ---"
PROF="$(grep -oE 'RmProfilingAdminOnly: [0-9]+' /proc/driver/nvidia/params 2>/dev/null | awk '{print $2}')"
say "RmProfilingAdminOnly = ${PROF:-UNREADABLE}   (1 = profiling counters denied to us)"
say "perf_event_paranoid  = $(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo NA)"
say "kernel               = $(uname -r)"
say "ipmi device          = $(ls -l /dev/ipmi0 2>/dev/null || echo absent)"
say ""

say "--- REQUIRED sources ---"

# 0. Load generator capability, checked inside the image the harness runs in.
#
# This is a measurement instrument like any other. Job 12303327 produced a
# complete, plausible-looking 8-GPU policy comparison that was entirely
# invalid: the harness issued requests through the default asyncio executor,
# whose width is min(32, cpu_count+4), so on a 32-core node it could never
# exceed ~27 req/s no matter what rate was offered. Every cell from 50 to
# 137.5 req/s measured the client. Nothing in the telemetry gate noticed,
# because the gate only checked energy instruments.
#
# A generator that cannot deliver the offered load is a broken instrument, so
# it belongs here, and it must be checked in the CONTAINER python - the login
# node's CVMFS python is a different interpreter.
if env -u SSL_CERT_FILE "$APPTAINER" exec "$IMG" python3 -c "
import httpx, asyncio
l = httpx.Limits(max_connections=1024, max_keepalive_connections=1024)
c = httpx.AsyncClient(limits=l)
asyncio.get_event_loop_policy()
print(httpx.__version__)
" > /tmp/httpx.$$ 2>/dev/null; then
  req "async load generator (httpx in image)" 0 "httpx $(cat /tmp/httpx.$$)"
else
  req "async load generator (httpx in image)" 1 \
    "absent or unusable; a thread-pool client caps offered load at ~27 req/s"
fi
rm -f /tmp/httpx.$$

# 1. nvidia-smi provenance
if nvidia-smi --query-gpu=index,uuid,name,driver_version,power.limit,power.min_limit,power.max_limit,persistence_mode \
     --format=csv > /tmp/nvsmi.$$ 2>/dev/null; then
  req "nvidia-smi provenance" 0 "$(sed -n 2p /tmp/nvsmi.$$ | cut -c1-80)"
  cat /tmp/nvsmi.$$ >> "$OUT"
else
  req "nvidia-smi provenance" 1 "query failed"
fi
rm -f /tmp/nvsmi.$$

# 2 + 3. NVML counter and power, inside the image we actually measure with
NVML_OUT="$(env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3 -c "
import pynvml as n
n.nvmlInit()
h = n.nvmlDeviceGetHandleByIndex(0)
e = n.nvmlDeviceGetTotalEnergyConsumption(h)
p = n.nvmlDeviceGetPowerUsage(h)
print(f'energy_mJ={e} power_mW={p} uuid={n.nvmlDeviceGetUUID(h)}')
" 2>&1 | tail -1)"
case "$NVML_OUT" in
  energy_mJ=*) req "NVML energy counter + power" 0 "$NVML_OUT" ;;
  *)           req "NVML energy counter + power" 1 "$NVML_OUT" ;;
esac

# 4 + 5. DCGM energy 156 and power 155 through an unprivileged host engine
if [ -x "$DCGM_BIN/dcgmi" ] && [ -x "$DCGM_BIN/nv-hostengine" ]; then
  export LD_LIBRARY_PATH="$DCGM_LIB:${LD_LIBRARY_PATH:-}"
  PORT=$((5990 + RANDOM % 100))
  "$DCGM_BIN/nv-hostengine" -b 127.0.0.1 --port "$PORT" -n \
    > "$(dirname "$OUT")/dcgm-hostengine.log" 2>&1 &
  HE=$!
  sleep 8
  if kill -0 "$HE" 2>/dev/null; then
    D="$("$DCGM_BIN/dcgmi" dmon -e 156,155 -c 2 -d 500 -i 0 --host "127.0.0.1:$PORT" 2>&1 \
         | grep -E '^GPU ' | head -1 | tr -s ' ')"
    if [ -n "$D" ]; then
      req "DCGM energy 156 + power 155" 0 "$D"
    else
      req "DCGM energy 156 + power 155" 1 "dmon returned no rows"
    fi
    # DCP fields: recorded, not required
    say ""
    say "--- RECORDED, not required (kernel-gated) ---"
    DCP="$("$DCGM_BIN/dcgmi" dmon -e 1002,1005 -c 2 -d 500 -i 0 --host "127.0.0.1:$PORT" 2>&1 \
           | grep -E '^GPU |Error setting watches' | head -1 | tr -s ' ')"
    say "  DCGM DCP 1002/1005: ${DCP:-no output}"
    kill "$HE" 2>/dev/null
  else
    req "DCGM energy 156 + power 155" 1 "host engine would not start"
    say "--- RECORDED, not required (kernel-gated) ---"
  fi
else
  req "DCGM energy 156 + power 155" 1 "dcgmi/nv-hostengine not extracted at $DCGM_BIN"
  say "--- RECORDED, not required (kernel-gated) ---"
fi

# Intel/AMD RAPL: CPU and DRAM energy. Recorded, not required.
# TokenPowerBench (AAAI'26) uses RAPL for CPU/DRAM alongside NVML/DCGM for GPU
# and IPMI for the node. We were measuring GPU-package only, so RAPL is a free
# coverage gain IF readable - note CVE-2020-8694 (Platypus) caused many distros
# to restrict energy_uj to root, so this may be denied. Either way it is data.
say ""
say "--- RAPL (CPU + DRAM energy), recorded not required ---"
RAPL_OK=0
if [ -d /sys/class/powercap ]; then
  for z in /sys/class/powercap/intel-rapl:*/ /sys/class/powercap/amd-rapl:*/; do
    [ -d "$z" ] || continue
    nm="$(cat "$z/name" 2>/dev/null || echo unknown)"
    if uj="$(cat "$z/energy_uj" 2>/dev/null)"; then
      say "  [readable] $(basename "$z") name=$nm energy_uj=$uj"
      RAPL_OK=1
    else
      say "  [DENIED]   $(basename "$z") name=$nm — energy_uj not readable "
      say "             (expected: CVE-2020-8694 hardening makes this root-only)"
    fi
  done
  [ "$RAPL_OK" -eq 0 ] && say "  RESULT: RAPL present but unreadable; CPU/DRAM energy unavailable to us"
else
  say "  /sys/class/powercap absent — no RAPL on this kernel"
fi

# Nsight Systems presence and permission (used in the mechanism pass only)
if [ -x "$NSYS" ]; then
  say "  nsys: $("$NSYS" --version 2>&1 | head -1)"
  say "  nsys counter permission: $("$NSYS" status -e 2>&1 | grep -E 'system-wide|Paranoid' | tr '\n' ' ' | cut -c1-110)"
else
  say "  nsys: NOT PRESENT at $NSYS"
fi

# Nsight Compute: kernel counters, denied where profiling is admin-only
NCU="$(command -v ncu || find "$OPT" -type f -name ncu 2>/dev/null | head -1)"
say "  ncu: ${NCU:-not installed} (kernel counters; expected denied when RmProfilingAdminOnly=1)"

say ""
if [ "$FAIL" -ne 0 ]; then
  say "=== RESULT: ABORT — a required telemetry source is unavailable ==="
  say "Refusing to produce numbers from a degraded instrument set."
  exit 1
fi
say "=== RESULT: all required telemetry verified; measurement may proceed ==="
exit 0
