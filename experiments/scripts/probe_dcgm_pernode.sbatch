#!/bin/bash
#SBATCH --job-name=dcgm-node
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --gres=gpu:1
#SBATCH --exclusive
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=00:20:00
#SBATCH --output=%x-%j-%N.out
#
# Two remaining hypotheses for why DCGM failed in job 12302443 and succeeded in
# 12302781/84/88:
#
#   H-field: DCGM_FI_PROF_SM_ACTIVE (1002) is the only field that needs root,
#            and because DCGM watches a field group atomically, asking for
#            1002 together with 1005 failed BOTH. The shipped exporter counter
#            file has SM_ACTIVE commented out, which is why it never trips.
#
#   H-node:  the permission differs per node. Every failure so far was on
#            frnt152; every success on frnt148.
#
# Run this pinned to each node to separate them:
#   sbatch -w frnt148 probe_dcgm_pernode.sbatch
#   sbatch -w frnt152 probe_dcgm_pernode.sbatch
#   sbatch -w frnt149 probe_dcgm_pernode.sbatch

if ! command -v module >/dev/null 2>&1; then
  source /cvmfs/soft.computecanada.ca/config/profile/bash.sh 2>/dev/null \
    || source "${LMOD_PKG:-/cvmfs/soft.computecanada.ca/custom/software/lmod/lmod}/init/bash" 2>/dev/null
fi
set -uo pipefail

OPT="$HOME/energy-epp/opt"
OUT_DIR="$HOME/energy-epp/instruments-probe"
mkdir -p "$OUT_DIR"
NODE="$(hostname -s)"
OUT="$OUT_DIR/dcgm-pernode-$NODE-${SLURM_JOB_ID:-nojob}.txt"
EXPORTER="$OPT/dcgm-exporter/usr/bin/dcgm-exporter"
SHIPPED="$OPT/dcgm-exporter/etc/dcgm-exporter/default-counters.csv"
DCGMI="$OPT/dcgm4/usr/bin/dcgmi"
HOSTENG="$OPT/dcgm4/usr/bin/nv-hostengine"
export LD_LIBRARY_PATH="$OPT/dcgm4/usr/lib64"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

: > "$OUT"
say "=== DCGM permission profile on $NODE, $(date -Is) ==="
say "job ${SLURM_JOB_ID:-none}"
say ""

say "--- node identity ---"
nvidia-smi --query-gpu=index,name,driver_version --format=csv,noheader | head -1 | tee -a "$OUT"
say "RmProfilingAdminOnly: $(grep -oE 'RmProfilingAdminOnly: [0-9]+' /proc/driver/nvidia/params 2>/dev/null || echo UNREADABLE)"
say "kernel: $(uname -r)"
say "features: $(scontrol show node "$NODE" 2>/dev/null | tr ' ' '\n' | grep -i ActiveFeatures)"
say ""

say "--- H-field: each profiling field asked for ALONE, through a standalone engine ---"
"$HOSTENG" -b 127.0.0.1 --port 5921 -n > "$OUT_DIR/pernode-he-$NODE.log" 2>&1 &
he=$!
sleep 8
if kill -0 "$he" 2>/dev/null; then
  for fid in 1002 1003 1004 1005 1009 1010 155 156; do
    line="$("$DCGMI" dmon -e "$fid" -c 2 -d 500 -i 0 --host 127.0.0.1:5921 2>&1 \
      | grep -E 'Error setting watches|^GPU ' | head -1 | tr -s ' ')"
    say "  field $fid: ${line:-no output}"
  done
  say ""
  say "--- the combination that failed originally: 1002 and 1005 together ---"
  "$DCGMI" dmon -e 1002,1005 -c 2 -d 500 -i 0 --host 127.0.0.1:5921 2>&1 \
    | grep -E 'Error setting watches|^GPU |SMACT' | head -4 | sed 's/^/  /' | tee -a "$OUT"
  kill "$he" 2>/dev/null
else
  say "  host engine died; log:"
  head -10 "$OUT_DIR/pernode-he-$NODE.log" | sed 's/^/    /' | tee -a "$OUT"
fi
sleep 3
say ""

say "--- H-node: the embedded exporter with the shipped counter file ---"
"$EXPORTER" -f "$SHIPPED" --address ":9440" > "$OUT_DIR/pernode-exp-$NODE.log" 2>&1 &
pid=$!
sleep 16
if kill -0 "$pid" 2>/dev/null; then
  body="$(curl -fsS --max-time 15 http://127.0.0.1:9440/metrics 2>/dev/null)"
  say "  exporter UP. total series $(printf '%s' "$body" | grep -c '^DCGM_FI' || true), profiling $(printf '%s' "$body" | grep -c '^DCGM_FI_PROF' || true)"
  printf '%s' "$body" | grep '^DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION{' | head -1 \
    | sed -E 's/^([A-Z_]+)\{.*gpu="([0-9]+)".*\} (.*)$/  \1 gpu=\2 = \3/' | tee -a "$OUT"
  kill "$pid" 2>/dev/null
else
  say "  exporter DIED. decisive line:"
  grep -E 'level=ERROR' "$OUT_DIR/pernode-exp-$NODE.log" 2>/dev/null | head -1 \
    | grep -oE 'error=".*"' | cut -c1-200 | sed 's/^/    /' | tee -a "$OUT"
fi
say ""
say "=== done: $OUT ==="
