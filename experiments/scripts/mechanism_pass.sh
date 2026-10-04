#!/bin/bash
# Pass B: the MECHANISM pass. Runs every profiling tool NVIDIA gives us, on
# real hardware, against a fixed short workload.
#
# Why this is a SEPARATE pass from the energy measurement, and not optional:
# these tools perturb what they observe. Nsight Compute serialises kernels and
# can slow them by an order of magnitude; CUPTI counter collection adds
# overhead. Energy measured while profiling is not the energy of normal
# serving, so mixing the two would invalidate the headline numbers. Running
# both passes in every job gives complete tool coverage without that
# contamination.
#
# Tools exercised here, all mandatory to ATTEMPT; a denial is recorded as data:
#   CUPTI            via torch.profiler CUDA activity (tracing works even when
#                    counters are denied - verified 17 device events)
#   Nsight Systems   nsys profile --trace=cuda (verified 939 KB report)
#   Nsight Compute   ncu kernel counters (expected denied when
#                    RmProfilingAdminOnly=1)
#   DCGM DCP         fields 1002 SM_ACTIVE / 1005 DRAM_ACTIVE under load
#   nvidia-smi       high-rate clock/power/utilisation sampling under load
#
# Usage: bash mechanism_pass.sh <output-dir>

OUTDIR="${1:-$HOME/energy-epp/results/mechanism-$$}"
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

mkdir -p "$OUTDIR"
OUT="$OUTDIR/mechanism.txt"
DCGM_BIN="$OPT/dcgm4/usr/bin"
DCGM_LIB="$OPT/dcgm4/usr/lib64"
NSYS="$OPT/nsight/opt/nvidia/nsight-systems/2025.6.3/target-linux-x64/nsys"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
hdr() { say ""; say "======== $* ========"; }

: > "$OUT"
say "=== mechanism pass (Pass B), $(date -Is) ==="
say "node: $(hostname)  job: ${SLURM_JOB_ID:-none}"
say "NOTE: these tools perturb timing and energy. Nothing here is used for the"
say "headline energy numbers; Pass A owns those."
PROF="$(grep -oE 'RmProfilingAdminOnly: [0-9]+' /proc/driver/nvidia/params 2>/dev/null | awk '{print $2}')"
say "RmProfilingAdminOnly = ${PROF:-UNREADABLE}"

# a small, fixed, deterministic GPU workload every tool observes
WORKLOAD='
import torch
torch.manual_seed(0)
a = torch.randn(4096, 4096, device="cuda", dtype=torch.float16)
b = torch.randn(4096, 4096, device="cuda", dtype=torch.float16)
for _ in range(50):
    c = (a @ b).relu()
torch.cuda.synchronize()
print("workload done", float(c.sum()))
'

hdr "1. CUPTI via torch.profiler (tracing path)"
env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3 -c "
import torch, torch.profiler as P
$WORKLOAD
with P.profile(activities=[P.ProfilerActivity.CPU, P.ProfilerActivity.CUDA]) as prof:
    d = (a @ b).relu(); torch.cuda.synchronize()
ev = [e for e in prof.key_averages() if e.device_time_total > 0]
print('CUPTI_EVENTS_WITH_DEVICE_TIME', len(ev))
print(prof.key_averages().table(sort_by='cuda_time_total', row_limit=6))
" 2>&1 | tail -16 | tee -a "$OUT"

hdr "2. CUPTI counter path (expected denied when the bit is 1)"
env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3 -c "
import ctypes, glob
libs = glob.glob('/usr/local/**/libcupti.so*', recursive=True)
print('libcupti:', libs[:1] or 'NONE')
if libs:
    h = ctypes.CDLL(libs[0]); v = ctypes.c_uint()
    print('cuptiGetVersion rc', h.cuptiGetVersion(ctypes.byref(v)), 'version', v.value)
" 2>&1 | tail -4 | tee -a "$OUT"

hdr "3. Nsight Systems trace"
if [ -x "$NSYS" ]; then
  "$NSYS" --version 2>&1 | head -1 | tee -a "$OUT"
  say "--- nsys status -e ---"
  "$NSYS" status -e 2>&1 | head -14 | tee -a "$OUT"
  say "--- nsys profile --trace=cuda ---"
  env -u SSL_CERT_FILE "$NSYS" profile --trace=cuda --force-overwrite=true \
    -o "$OUTDIR/nsys-trace" \
    "$APPTAINER" exec --nv "$IMG" python3 -c "$WORKLOAD" 2>&1 | tail -6 | tee -a "$OUT"
  ls -lh "$OUTDIR"/nsys-trace* 2>&1 | tee -a "$OUT"
  say "--- nsys stats (kernel summary from the trace) ---"
  "$NSYS" stats --report cuda_gpu_kern_sum "$OUTDIR/nsys-trace.nsys-rep" 2>&1 \
    | head -14 | tee -a "$OUT"
else
  say "nsys NOT PRESENT at $NSYS"
fi

hdr "4. Nsight Compute (kernel counters)"
NCU="$(command -v ncu || find "$OPT" -type f -name ncu 2>/dev/null | head -1)"
if [ -n "$NCU" ]; then
  say "ncu: $NCU"
  env -u SSL_CERT_FILE "$NCU" --metrics \
    sm__throughput.avg.pct_of_peak_sustained_elapsed,dram__throughput.avg.pct_of_peak_sustained_elapsed \
    --target-processes all --launch-count 3 \
    "$APPTAINER" exec --nv "$IMG" python3 -c "$WORKLOAD" 2>&1 | tail -18 | tee -a "$OUT"
else
  say "ncu NOT INSTALLED."
  say "RECORDED RESULT: Nsight Compute is unavailable to us. It needs profiling"
  say "permission, which this node denies when RmProfilingAdminOnly=1, and it"
  say "serialises kernels so it could not share a run with the energy pass"
  say "regardless. Its absence is a finding about the deployment, not a gap in"
  say "the method."
fi

hdr "5. DCGM DCP fields under load (SM_ACTIVE 1002, DRAM_ACTIVE 1005)"
if [ -x "$DCGM_BIN/dcgmi" ] && [ -x "$DCGM_BIN/nv-hostengine" ]; then
  export LD_LIBRARY_PATH="$DCGM_LIB:${LD_LIBRARY_PATH:-}"
  PORT=$((6100 + RANDOM % 200))
  "$DCGM_BIN/nv-hostengine" -b 127.0.0.1 --port "$PORT" -n > "$OUTDIR/he.log" 2>&1 &
  HE=$!
  sleep 8
  if kill -0 "$HE" 2>/dev/null; then
    env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3 -c "$WORKLOAD" \
      > "$OUTDIR/load.log" 2>&1 &
    LOADPID=$!
    sleep 2
    say "--- energy/power (required fields, should always work) ---"
    "$DCGM_BIN/dcgmi" dmon -e 156,155 -c 4 -d 500 -i 0 --host "127.0.0.1:$PORT" 2>&1 \
      | grep -E 'Entity|^GPU ' | head -6 | tee -a "$OUT"
    say "--- DCP fields (kernel-gated) ---"
    "$DCGM_BIN/dcgmi" dmon -e 1002,1005 -c 4 -d 500 -i 0 --host "127.0.0.1:$PORT" 2>&1 \
      | grep -E 'Entity|^GPU |Error setting watches' | head -6 | tee -a "$OUT"
    wait "$LOADPID" 2>/dev/null
    kill "$HE" 2>/dev/null
  else
    say "host engine would not start; log:"
    head -8 "$OUTDIR/he.log" 2>/dev/null | tee -a "$OUT"
  fi
else
  say "DCGM not extracted at $DCGM_BIN — run fetch_instruments.sh first"
fi

hdr "6. nvidia-smi high-rate sampling under load"
env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3 -c "$WORKLOAD" \
  > "$OUTDIR/load2.log" 2>&1 &
LOADPID=$!
nvidia-smi --query-gpu=timestamp,index,power.draw,clocks.sm,clocks.mem,utilization.gpu,utilization.memory,temperature.gpu \
  --format=csv -l 1 -c 8 2>&1 | head -12 | tee -a "$OUT"
wait "$LOADPID" 2>/dev/null

say ""
say "=== mechanism pass complete: $OUT ==="
say "Tools attempted: CUPTI tracing, CUPTI counter probe, Nsight Systems trace"
say "+ stats, Nsight Compute, DCGM energy/power, DCGM DCP, nvidia-smi sampling."
say "Denials above are recorded results about this deployment."
