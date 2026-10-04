#!/bin/bash
#SBATCH --job-name=clk-probe
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --time=00:08:00
#SBATCH --mem=0
#SBATCH --gres=gpu:rtx6000:4
#SBATCH --output=%x-%j.out

# Can an unprivileged user create ENERGY HETEROGENEITY inside one node?
#
# Why this matters. Every Stage 2 result so far says routing barely matters on
# a homogeneous fleet: the load balancers sit within +-1% of each other on
# J/req, and plain round-robin beats every consolidating policy on SLO-goodput
# per joule. An energy-aware scorer needs replicas with genuinely different
# energy profiles. The obvious way to get that is a multi-node allocation with
# two GPU types, but NVML is node-local, so per-cell energy would then need
# cross-node collection and window alignment - a large change to the meter.
#
# A much cheaper route, if permitted: take identical GPUs in ONE node and give
# some of them a different performance/power profile. Then the fleet is
# heterogeneous in exactly the dimension the policies care about, the energy
# meter stays local, and nothing about the harness changes.
#
# We already know "nvidia-smi -pl" (power limit) is denied to this account
# ("Insufficient Permissions"). This probes the other levers:
#   --lock-gpu-clocks      (-lgc)  graphics clock range
#   --lock-memory-clocks   (-lmc)  memory clock range
#   --applications-clocks  (-ac)   application clock pair
# Each is tried, and reverted whether or not it worked, so the node is left as
# it was found.
set -uo pipefail

echo "node=$(hostname) job=${SLURM_JOB_ID:-none}"
nvidia-smi --query-gpu=index,name,driver_version,clocks.max.graphics,clocks.max.memory \
  --format=csv
echo
echo "supported graphics clocks on GPU 0 (first 12):"
nvidia-smi -i 0 --query-supported-clocks=graphics --format=csv,noheader 2>/dev/null | head -12
echo

try() {  # $1 label, rest: nvidia-smi args
  local label="$1"; shift
  local out rc
  out="$(nvidia-smi "$@" 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "  [PERMITTED] $label"
  else
    echo "  [DENIED]    $label -- $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-110)"
  fi
  return "$rc"
}

echo "=== can we constrain GPU 0 only, leaving 1-3 at stock? ==="
LOCKED=0
if try "lock-gpu-clocks 300,900 on GPU 0" -i 0 --lock-gpu-clocks=300,900; then
  LOCKED=1
  echo "  resulting clocks: $(nvidia-smi -i 0 --query-gpu=clocks.gr,clocks.sm --format=csv,noheader)"
  echo "  GPU 1 unchanged:  $(nvidia-smi -i 1 --query-gpu=clocks.gr,clocks.sm --format=csv,noheader)"
fi
try "lock-memory-clocks on GPU 0" -i 0 --lock-memory-clocks=405,405 && LOCKED=1
try "applications-clocks on GPU 0" -i 0 -ac 405,900 && LOCKED=1

echo
echo "=== revert everything, regardless of what succeeded ==="
nvidia-smi -i 0 --reset-gpu-clocks        >/dev/null 2>&1 && echo "  reset-gpu-clocks ok"
nvidia-smi -i 0 --reset-memory-clocks     >/dev/null 2>&1 && echo "  reset-memory-clocks ok"
nvidia-smi -i 0 -rac                      >/dev/null 2>&1 && echo "  reset-applications-clocks ok"
echo "  GPU 0 clocks after revert: $(nvidia-smi -i 0 --query-gpu=clocks.gr,clocks.sm --format=csv,noheader)"

echo
if [ "$LOCKED" -eq 1 ]; then
  echo "RESULT: at least one clock lever is PERMITTED."
  echo "In-node energy heterogeneity is achievable: clamp a subset of GPUs,"
  echo "measure a curve per profile, and Stage 2 becomes a genuinely"
  echo "heterogeneous fleet with the energy meter still node-local."
else
  echo "RESULT: every clock lever is DENIED, as --power-limit already was."
  echo "In-node heterogeneity is not available to this account, so testing the"
  echo "research question needs a multi-node allocation with two GPU types and"
  echo "cross-node energy collection. That is the larger path and should be"
  echo "costed before it is started."
fi
