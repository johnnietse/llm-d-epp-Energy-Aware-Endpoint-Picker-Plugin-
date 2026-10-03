#!/bin/bash
#SBATCH --job-name=instr-probe
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --gres=gpu:1
#SBATCH --exclusive
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=00:30:00
#SBATCH --output=%x-%j.out
#
# Does each alternative telemetry source actually work for an unprivileged
# user on a Frontenac compute node? Answers per source, with the exact
# error when it fails. Changes nothing persistent.
#
# Pin the GPU type with -C when comparing across runs, e.g.
#   sbatch -C rtx6000 probe_instruments_gpu.sbatch

# Lmod bootstrap before set -u (the CC profile reads unset variables).
if [ -f /opt/software/cc-wrapper/profile.sh ]; then
  . /opt/software/cc-wrapper/profile.sh
elif [ -f /etc/profile.d/z-01-cc-modules.sh ]; then
  . /etc/profile.d/z-01-cc-modules.sh
fi
set -uo pipefail

OUT_DIR="$HOME/energy-epp/instruments-probe"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/gpu-${SLURM_JOB_ID:-nojob}.txt"
IMG="$HOME/energy-epp/images/vllm-v0.30.0.sif"
APPTAINER="$(command -v apptainer || echo /opt/software/apptainer/bin/apptainer)"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
run() { say "\$ $*"; "$@" 2>&1 | tee -a "$OUT"; say "(exit $?)"; say ""; }

: > "$OUT"
say "=== instrumentation probe on a compute node, $(date -Is) ==="
say "node: $(hostname)  job: ${SLURM_JOB_ID:-none}  gpus: ${CUDA_VISIBLE_DEVICES:-unset}"
say ""

say "--- 0. baseline: NVML, which we already rely on ---"
run nvidia-smi --query-gpu=index,uuid,name,power.draw,power.limit,power.min_limit,power.max_limit,persistence_mode --format=csv
say "# co-tenancy guard: anything here but our own job means the run is contaminated"
run nvidia-smi --query-compute-apps=pid,used_memory --format=csv

say "--- 1. THE decisive permission bit ---"
say "# RmProfilingAdminOnly=1 => CUPTI, Nsight and DCGM profiling fields are denied to us"
if [ -r /proc/driver/nvidia/params ]; then
  grep -E 'RmProfilingAdminOnly' /proc/driver/nvidia/params | tee -a "$OUT"
else
  say "/proc/driver/nvidia/params UNREADABLE"
fi
say ""

say "--- 2. IPMI: is there even a device node to talk to? ---"
run ls -l /dev/ipmi0 /dev/ipmi/0 /dev/ipmidev/0
say "# Slurm's own energy plugin (null => sacct ConsumedEnergy will be 0)"
run bash -c "scontrol show config | grep -i -E 'AcctGatherEnergyType|AcctGatherNodeFreq'"
say "# does this node advertise the power_ipmi feature?"
run bash -c "scontrol show node $(hostname) | tr ' ' '\n' | grep -i -E 'ActiveFeatures|AvailableFeatures'"

say "--- 3. CUPTI, via the torch profiler already inside our vLLM image ---"
if [ -f "$IMG" ]; then
  say "# torch.profiler with CUDA activity is a direct CUPTI test"
  env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python -c '
import torch, torch.profiler as P
print("torch", torch.__version__, "cuda", torch.version.cuda, "dev", torch.cuda.get_device_name(0))
try:
    with P.profile(activities=[P.ProfilerActivity.CPU, P.ProfilerActivity.CUDA]) as prof:
        a = torch.randn(4096, 4096, device="cuda")
        (a @ a).sum().item()
        torch.cuda.synchronize()
    ev = [e for e in prof.key_averages() if e.device_time_total > 0]
    print("CUPTI OK: captured", len(ev), "events with device time")
    print(prof.key_averages().table(sort_by="cuda_time_total", row_limit=5))
except Exception as e:
    print("CUPTI FAILED:", type(e).__name__, e)
' 2>&1 | tee -a "$OUT"
  say ""
  say "# the counter-level test: this is what hits ERR_NVGPUCTRPERM if profiling is admin-only"
  env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" bash -lc \
    'ls -l /usr/local/cuda*/extras/CUPTI/lib64/libcupti.so* 2>/dev/null; python -c "import ctypes,glob,sys
c=glob.glob(\"/usr/local/**/libcupti.so*\",recursive=True)+glob.glob(\"/usr/lib/**/libcupti.so*\",recursive=True)
print(\"libcupti found:\", c[:3] or \"NONE\")
if c:
    h=ctypes.CDLL(c[0]); v=ctypes.c_uint()
    print(\"cuptiGetVersion rc=\", h.cuptiGetVersion(ctypes.byref(v)), \"version=\", v.value)"' 2>&1 | tee -a "$OUT"
  say ""
else
  say "vLLM image not at $IMG - skipping CUPTI test"
fi

say "--- 4. DCGM: is dcgmi reachable any way at all? ---"
run bash -c "command -v dcgmi nv-hostengine"
say "# the shared library route: DCGM's host engine can run embedded, no daemon, no root"
run bash -c "find / -maxdepth 6 -name 'libdcgm*.so*' 2>/dev/null | head"
say "# python binding, if the stack happens to ship it"
run bash -c "python3 -c 'import pydcgm; print(pydcgm.__file__)'"

say "--- 5. Nsight ---"
run bash -c "command -v nsys ncu"
if [ -f "$IMG" ]; then
  say "# some NGC-derived images ship nsys even when the host does not"
  run env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" bash -lc "command -v nsys ncu || echo 'not in image'"
fi

say "--- 6. NVML energy counter, as the control that we know works ---"
run bash -c "python3 -c \"
import pynvml as n
n.nvmlInit()
h = n.nvmlDeviceGetHandleByIndex(0)
print('uuid', n.nvmlDeviceGetUUID(h))
print('total energy mJ', n.nvmlDeviceGetTotalEnergyConsumption(h))
print('power mW', n.nvmlDeviceGetPowerUsage(h))
print('enforced limit mW', n.nvmlDeviceGetEnforcedPowerLimit(h))
\""

say "=== done: $OUT ==="
