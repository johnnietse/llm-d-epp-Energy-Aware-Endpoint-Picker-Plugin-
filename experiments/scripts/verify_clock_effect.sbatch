#!/bin/bash
#SBATCH --job-name=clk-verify
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --time=00:15:00
#SBATCH --mem=0
#SBATCH --gres=gpu:rtx6000:4
#SBATCH --output=%x-%j.out

# Does the PERMITTED clock lever actually DO anything?
#
# Job 12304131 found that --power-limit and --lock-gpu-clocks are denied to
# this account, but --lock-memory-clocks and --applications-clocks both
# returned 0. That is not evidence they worked. nvidia-smi exiting 0 means the
# command ran; --applications-clocks in particular is deprecated on Turing and
# can succeed while changing nothing. Today has already produced five defects
# of exactly this shape - a component reporting success for something it did
# not do - so this probe checks the EFFECT under load, not the return code.
#
# Method: clamp GPU 0 only, run an identical matmul loop on GPU 0 and GPU 1,
# and compare achieved SM clock, power draw and throughput. GPU 1 is the
# control. If GPU 0 differs, in-node energy heterogeneity is real and Stage 2
# can have a heterogeneous fleet without a multi-node allocation. If it does
# not differ, the lever is cosmetic and the multi-node path is the only one.
set -uo pipefail
module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null || true
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"
ROOT="$HOME/energy-epp"
IMG="$ROOT/images/vllm-v0.30.0.sif"

echo "node=$(hostname) job=${SLURM_JOB_ID:-none}"
nvidia-smi --query-gpu=index,name,driver_version --format=csv,noheader | head -2
echo

bench() {  # $1 = gpu index, $2 = label
  env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" \
    python3 "$ROOT/scripts/clock_effect_bench.py" "$1" "$2"
}

echo "=== baseline: both GPUs unclamped ==="
bench 0 "gpu0-baseline"
bench 1 "gpu1-baseline"

echo
echo "=== apply the permitted levers to GPU 0 ONLY ==="
# Lowest supported memory clock, and a low application clock pair. Values come
# from the supported list the previous probe printed.
nvidia-smi -i 0 --lock-memory-clocks=405,405 2>&1 | tail -1
nvidia-smi -i 0 -ac 405,600 2>&1 | tail -1
echo "  GPU 0 reports: $(nvidia-smi -i 0 --query-gpu=clocks.applications.graphics,clocks.applications.memory --format=csv,noheader)"
echo "  GPU 1 reports: $(nvidia-smi -i 1 --query-gpu=clocks.applications.graphics,clocks.applications.memory --format=csv,noheader)"

echo
echo "=== under load, clamped GPU 0 vs control GPU 1 ==="
bench 0 "gpu0-clamped"
bench 1 "gpu1-control"

echo
echo "=== revert ==="
nvidia-smi -i 0 --reset-memory-clocks 2>&1 | tail -1
nvidia-smi -i 0 -rac 2>&1 | tail -1
bench 0 "gpu0-reverted"

echo
echo "Read it this way: if gpu0-clamped shows a materially lower SM clock,"
echo "lower power, or lower throughput than gpu1-control AND than its own"
echo "baseline, the lever is real. If all four rows match, the lever is"
echo "cosmetic and the multi-node path is the only route to heterogeneity."
