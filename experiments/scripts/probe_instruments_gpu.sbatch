#!/bin/bash
#SBATCH --job-name=instr-probe
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --gres=gpu:1
#SBATCH --exclusive
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=00:40:00
#SBATCH --output=%x-%j.out
#
# Does each alternative telemetry source actually work for an unprivileged user
# on a Frontenac compute node? Answers per source, recording the exact error
# when one is denied. Changes nothing persistent.
#
# Pin the GPU type when comparing across runs:   sbatch -C rtx6000 this.sbatch
# Requires fetch_instruments.sh to have run first on the login node.

# Lmod bootstrap must precede set -u: the CC profile reads unset variables.
if ! command -v module >/dev/null 2>&1; then
  source /cvmfs/soft.computecanada.ca/config/profile/bash.sh 2>/dev/null \
    || source "${LMOD_PKG:-/cvmfs/soft.computecanada.ca/custom/software/lmod/lmod}/init/bash" 2>/dev/null
fi
set -uo pipefail

module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"

OPT="$HOME/energy-epp/opt"
OUT_DIR="$HOME/energy-epp/instruments-probe"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/gpu-${SLURM_JOB_ID:-nojob}.txt"
IMG="$HOME/energy-epp/images/vllm-v0.30.0.sif"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
hdr() { say ""; say "================ $* ================"; }

: > "$OUT"
say "=== instrumentation probe on a compute node, $(date -Is) ==="
say "node: $(hostname)  job: ${SLURM_JOB_ID:-none}  gpus: ${CUDA_VISIBLE_DEVICES:-unset}"
say "constraint: ${SLURM_JOB_CONSTRAINTS:-none}  apptainer: $APPTAINER"

hdr "0. NVML baseline, the source we already trust"
nvidia-smi --query-gpu=index,uuid,name,driver_version,power.draw,power.limit,power.min_limit,power.max_limit,persistence_mode \
  --format=csv 2>&1 | tee -a "$OUT"
say ""
say "# co-tenancy guard: any process here other than ours contaminates the run"
nvidia-smi --query-compute-apps=pid,used_memory --format=csv 2>&1 | tee -a "$OUT"

hdr "1. the decisive permission bit"
say "# RmProfilingAdminOnly=1 means CUPTI, Nsight and DCGM profiling fields are denied to non-root"
if [ -r /proc/driver/nvidia/params ]; then
  grep -E 'RmProfilingAdminOnly' /proc/driver/nvidia/params 2>&1 | tee -a "$OUT"
else
  say "/proc/driver/nvidia/params UNREADABLE"
fi
say "# the host's own view of perf-event access (affects nsys CPU sampling)"
cat /proc/sys/kernel/perf_event_paranoid 2>&1 | tee -a "$OUT"

hdr "2. IPMI: is there a device node to talk to at all?"
ls -l /dev/ipmi0 /dev/ipmi/0 /dev/ipmidev/0 2>&1 | tee -a "$OUT"
say "# Slurm's energy plugin and this node's advertised features"
scontrol show config 2>/dev/null | grep -i -E 'AcctGatherEnergyType|AcctGatherNodeFreq' | tee -a "$OUT"
scontrol show node "$(hostname -s)" 2>/dev/null | tr ' ' '\n' \
  | grep -i -E 'ActiveFeatures|AvailableFeatures' | tee -a "$OUT"

hdr "3. DCGM, from the user-space extraction"
for v in dcgm3 dcgm4; do
  DBIN="$(find "$OPT/$v" -type f -name dcgmi 2>/dev/null | head -1)"
  HBIN="$(find "$OPT/$v" -type f -name nv-hostengine 2>/dev/null | head -1)"
  LIBD="$(find "$OPT/$v" -name 'libdcgm.so*' 2>/dev/null | head -1)"
  LIBD="${LIBD:+$(dirname "$LIBD")}"
  say ""
  say "--- $v ---"
  say "dcgmi: ${DBIN:-MISSING}"
  say "nv-hostengine: ${HBIN:-MISSING}"
  say "libdir: ${LIBD:-MISSING}"
  [ -n "$DBIN" ] || continue
  export LD_LIBRARY_PATH="${LIBD:-}:${LD_LIBRARY_PATH:-}"

  say "# version"
  "$DBIN" --version 2>&1 | head -4 | tee -a "$OUT"

  if [ -n "$HBIN" ]; then
    PORT=$((5560 + RANDOM % 200))
    say "# starting nv-hostengine unprivileged on 127.0.0.1:$PORT"
    "$HBIN" -b 127.0.0.1 --port "$PORT" -n > "$OUT_DIR/$v-hostengine.log" 2>&1 &
    HPID=$!
    sleep 8
    if kill -0 "$HPID" 2>/dev/null; then
      say "hostengine running (pid $HPID)"
      say "# which fields does THIS version expose? (not hardcoding IDs)"
      "$DBIN" --host "127.0.0.1:$PORT" dmon -l 2>&1 \
        | grep -i -E 'energy|power|sm_active|sm_occupancy|dram|gr_engine' | tee -a "$OUT"
      say ""
      say "# discovery"
      "$DBIN" --host "127.0.0.1:$PORT" discovery -l 2>&1 | head -12 | tee -a "$OUT"
      say ""
      ENERGY_ID="$("$DBIN" --host "127.0.0.1:$PORT" dmon -l 2>/dev/null \
        | grep -i 'energy' | head -1 | grep -oE '[0-9]{3,4}' | head -1)"
      say "# energy field id discovered: ${ENERGY_ID:-NONE}"
      if [ -n "${ENERGY_ID:-}" ]; then
        "$DBIN" --host "127.0.0.1:$PORT" dmon -e "$ENERGY_ID" -c 5 2>&1 | head -12 | tee -a "$OUT"
      fi
      say ""
      PROF_ID="$("$DBIN" --host "127.0.0.1:$PORT" dmon -l 2>/dev/null \
        | grep -i -E 'sm_active|sm occupancy' | head -1 | grep -oE '[0-9]{3,4}' | head -1)"
      say "# profiling (DCP) field id discovered: ${PROF_ID:-NONE} - expect denial if RmProfilingAdminOnly=1"
      if [ -n "${PROF_ID:-}" ]; then
        "$DBIN" --host "127.0.0.1:$PORT" dmon -e "$PROF_ID" -c 5 2>&1 | head -12 | tee -a "$OUT"
      fi
      kill "$HPID" 2>/dev/null
    else
      say "hostengine DIED. its log:"
      head -20 "$OUT_DIR/$v-hostengine.log" 2>/dev/null | tee -a "$OUT"
    fi
  fi
done

hdr "4. DCGM exporter, the path upstream llm-d actually scrapes"
EXP="$(find "$OPT/dcgm-exporter" -type f -name 'dcgm-exporter' 2>/dev/null | head -1)"
say "binary: ${EXP:-MISSING}"
if [ -n "$EXP" ]; then
  LIBD4="$(find "$OPT/dcgm4" -name 'libdcgm.so*' 2>/dev/null | head -1)"
  export LD_LIBRARY_PATH="${LIBD4:+$(dirname "$LIBD4")}:${LD_LIBRARY_PATH:-}"
  "$EXP" --version 2>&1 | head -4 | tee -a "$OUT"
  say "# run it in embedded mode and scrape once"
  "$EXP" --address ":9412" > "$OUT_DIR/dcgm-exporter.log" 2>&1 &
  EPID=$!
  sleep 15
  if kill -0 "$EPID" 2>/dev/null; then
    curl -fsS --max-time 20 http://127.0.0.1:9412/metrics 2>&1 \
      | grep -i -E 'energy|power_usage|sm_active|dram_active' | head -15 | tee -a "$OUT"
    kill "$EPID" 2>/dev/null
  else
    say "exporter DIED. its log:"
    head -25 "$OUT_DIR/dcgm-exporter.log" 2>/dev/null | tee -a "$OUT"
  fi
fi

hdr "5. Nsight Systems: does it run, and will it be allowed to profile?"
NSYS="$(find "$OPT/nsight" -type f -name nsys 2>/dev/null | head -1)"
say "binary: ${NSYS:-MISSING}"
if [ -n "$NSYS" ]; then
  say "# version (this is the glibc test: CVMFS gives 2.37, host 2.28)"
  "$NSYS" --version 2>&1 | head -4 | tee -a "$OUT"
  say ""
  say "# 'nsys status -e' reports whether counter collection is permitted here"
  "$NSYS" status -e 2>&1 | head -25 | tee -a "$OUT"
fi

hdr "6. CUPTI, via the torch profiler already inside our vLLM image"
if [ -f "$IMG" ]; then
  env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python -c '
import torch, torch.profiler as P
print("torch", torch.__version__, "cuda", torch.version.cuda, "gpu", torch.cuda.get_device_name(0))
try:
    with P.profile(activities=[P.ProfilerActivity.CPU, P.ProfilerActivity.CUDA]) as prof:
        a = torch.randn(4096, 4096, device="cuda")
        (a @ a).sum().item()
        torch.cuda.synchronize()
    ev = [e for e in prof.key_averages() if e.device_time_total > 0]
    print("CUPTI OK: captured", len(ev), "events carrying device time")
except Exception as e:
    print("CUPTI FAILED:", type(e).__name__, e)
' 2>&1 | tail -20 | tee -a "$OUT"
else
  say "vLLM image not at $IMG - skipped"
fi

hdr "7. NVML energy counter, the control that we know works"
env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python -c '
import pynvml as n
n.nvmlInit()
h = n.nvmlDeviceGetHandleByIndex(0)
print("uuid", n.nvmlDeviceGetUUID(h))
print("total energy mJ", n.nvmlDeviceGetTotalEnergyConsumption(h))
print("power mW", n.nvmlDeviceGetPowerUsage(h))
print("enforced limit mW", n.nvmlDeviceGetEnforcedPowerLimit(h))
' 2>&1 | tail -8 | tee -a "$OUT"

hdr "8. per-die spread, the experiment from plan section 13.5"
say "# all GPUs on this node at idle, same instant: do nominally identical dies differ?"
nvidia-smi --query-gpu=index,uuid,name,power.draw,temperature.gpu,clocks.sm \
  --format=csv 2>&1 | tee -a "$OUT"

say ""
say "=== done: $OUT ==="
