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
# Pin the GPU type when comparing across runs:  sbatch -C rtx6000 this.sbatch
# Requires fetch_instruments.sh to have run first on the login node.
#
# Measured facts this relies on (2026-10-03, not assumed):
#   DCGM energy field is 156 (DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION), per
#   dcgm_fields.h in the extracted package. DCGM 4.6.1 is the newest -core
#   that actually ships libdcgm.so.4; 4.7.0's core rpm has no payload.

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

DCGM4_BIN="$OPT/dcgm4/usr/bin"
DCGM4_LIB="$OPT/dcgm4/usr/lib64"
DCGM3_BIN="$OPT/dcgm3/usr/bin"
DCGM3_LIB="$OPT/dcgm3/usr/lib64"
EXPORTER="$OPT/dcgm-exporter/usr/bin/dcgm-exporter"
EXPORTER_CSV="$OPT/dcgm-exporter/etc/dcgm-exporter/default-counters.csv"
EXPORTER_DCP_CSV="$OPT/dcgm-exporter/etc/dcgm-exporter/dcp-metrics-included.csv"
NSYS="$OPT/nsight/opt/nvidia/nsight-systems/2025.6.3/target-linux-x64/nsys"

ENERGY_FIELD=156          # DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION
POWER_FIELD=155           # DCGM_FI_DEV_POWER_USAGE
PROF_SM_FIELD=1002        # DCGM_FI_PROF_SM_ACTIVE
PROF_DRAM_FIELD=1005      # DCGM_FI_PROF_DRAM_ACTIVE

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
hdr() { say ""; say "================ $* ================"; }

: > "$OUT"
say "=== instrumentation probe on a compute node, $(date -Is) ==="
say "node: $(hostname)  job: ${SLURM_JOB_ID:-none}  gpus: ${CUDA_VISIBLE_DEVICES:-unset}"

hdr "0. NVML baseline, the source we already trust"
nvidia-smi --query-gpu=index,uuid,name,driver_version,power.draw,power.limit,power.min_limit,power.max_limit,persistence_mode \
  --format=csv 2>&1 | tee -a "$OUT"
say ""
say "# co-tenancy guard: any process other than ours contaminates the run"
nvidia-smi --query-compute-apps=pid,used_memory --format=csv 2>&1 | tee -a "$OUT"

hdr "1. the decisive permission bit"
say "# RmProfilingAdminOnly=1 denies CUPTI, Nsight and DCGM profiling fields to non-root"
if [ -r /proc/driver/nvidia/params ]; then
  grep -E 'RmProfilingAdminOnly' /proc/driver/nvidia/params 2>&1 | tee -a "$OUT"
else
  say "/proc/driver/nvidia/params UNREADABLE"
fi
say "# perf_event_paranoid affects nsys CPU sampling"
cat /proc/sys/kernel/perf_event_paranoid 2>&1 | tee -a "$OUT"

hdr "2. IPMI: is there a device node to talk to at all?"
ls -l /dev/ipmi0 /dev/ipmi/0 /dev/ipmidev/0 2>&1 | tee -a "$OUT"
scontrol show config 2>/dev/null | grep -i -E 'AcctGatherEnergyType|AcctGatherNodeFreq' | tee -a "$OUT"
scontrol show node "$(hostname -s)" 2>/dev/null | tr ' ' '\n' \
  | grep -i -E 'ActiveFeatures|AvailableFeatures' | tee -a "$OUT"

probe_dcgm() {
  local label="$1" bindir="$2" libdir="$3"
  hdr "3.$label DCGM $label"
  local dcgmi="$bindir/dcgmi" hostengine="$bindir/nv-hostengine"
  [ -x "$dcgmi" ] || { say "no dcgmi at $dcgmi"; return; }
  export LD_LIBRARY_PATH="$libdir:${LD_LIBRARY_PATH:-}"
  say "# version"
  "$dcgmi" --version 2>&1 | head -3 | tee -a "$OUT"

  local port=$((5570 + RANDOM % 300))
  say "# starting nv-hostengine unprivileged on 127.0.0.1:$port"
  "$hostengine" -b 127.0.0.1 --port "$port" -n > "$OUT_DIR/hostengine-$label.log" 2>&1 &
  local hpid=$!
  sleep 10
  if ! kill -0 "$hpid" 2>/dev/null; then
    say "hostengine DIED. log:"
    head -25 "$OUT_DIR/hostengine-$label.log" 2>/dev/null | tee -a "$OUT"
    return
  fi
  say "hostengine running (pid $hpid)"

  say ""
  say "# discovery: does it see the GPU with driver 610.43.02?"
  "$dcgmi" discovery -l --host "127.0.0.1:$port" 2>&1 | head -14 | tee -a "$OUT"

  say ""
  say "# ENERGY field $ENERGY_FIELD and POWER field $POWER_FIELD (the fields we care about)"
  "$dcgmi" dmon -e "$ENERGY_FIELD,$POWER_FIELD" -c 5 -d 1000 --host "127.0.0.1:$port" 2>&1 \
    | head -14 | tee -a "$OUT"

  say ""
  say "# PROFILING fields $PROF_SM_FIELD (SM active) and $PROF_DRAM_FIELD (DRAM active)"
  say "# this is the explanatory data we wanted DCGM for; expect denial if profiling is admin-only"
  "$dcgmi" dmon -e "$PROF_SM_FIELD,$PROF_DRAM_FIELD" -c 5 -d 1000 --host "127.0.0.1:$port" 2>&1 \
    | head -14 | tee -a "$OUT"

  kill "$hpid" 2>/dev/null
  sleep 2
}

probe_dcgm "4.6.1" "$DCGM4_BIN" "$DCGM4_LIB"
probe_dcgm "3.3.9" "$DCGM3_BIN" "$DCGM3_LIB"

hdr "4. DCGM exporter, the path upstream llm-d scrapes"
say "binary: $EXPORTER"
if [ -x "$EXPORTER" ]; then
  export LD_LIBRARY_PATH="$DCGM4_LIB:${LD_LIBRARY_PATH:-}"
  "$EXPORTER" --version 2>&1 | head -2 | tee -a "$OUT"
  say "# what flag names this build use for the counter file?"
  "$EXPORTER" --help 2>&1 | grep -i -E 'collector|csv|config|address' | head -10 | tee -a "$OUT"
  say ""
  for csv in "$EXPORTER_CSV" "$EXPORTER_DCP_CSV"; do
    say "--- exporter with $(basename "$csv") ---"
    "$EXPORTER" -f "$csv" --address ":9412" > "$OUT_DIR/exporter-$(basename "$csv").log" 2>&1 &
    local_pid=$!
    sleep 18
    if kill -0 "$local_pid" 2>/dev/null; then
      curl -fsS --max-time 20 http://127.0.0.1:9412/metrics 2>&1 \
        | grep -i -E 'TOTAL_ENERGY|POWER_USAGE|SM_ACTIVE|DRAM_ACTIVE' | head -12 | tee -a "$OUT"
      kill "$local_pid" 2>/dev/null
      sleep 3
    else
      say "exporter exited. log:"
      head -25 "$OUT_DIR/exporter-$(basename "$csv").log" 2>/dev/null | tee -a "$OUT"
    fi
    say ""
  done
fi

hdr "5. Nsight Systems: does it run, and may it profile?"
say "binary: $NSYS"
if [ -x "$NSYS" ]; then
  "$NSYS" --version 2>&1 | head -2 | tee -a "$OUT"
  say ""
  say "# 'nsys status -e' states directly whether counter collection is permitted here"
  "$NSYS" status -e 2>&1 | head -30 | tee -a "$OUT"
  say ""
  say "# the GPU-side environment check, reported separately from the CPU one"
  "$NSYS" status --environment 2>&1 | head -30 | tee -a "$OUT"
  say ""
  say "# the distinction that matters: CUDA *tracing* may be allowed even when"
  say "# *counter* collection is not, because RmProfilingAdminOnly gates counters."
  if [ -f "$IMG" ]; then
    env -u SSL_CERT_FILE "$NSYS" profile --trace=cuda --force-overwrite=true \
      -o "$OUT_DIR/nsys-trace-${SLURM_JOB_ID:-nojob}" \
      "$APPTAINER" exec --nv "$IMG" python3 -c \
      'import torch; a=torch.randn(2048,2048,device="cuda"); (a@a).sum().item(); torch.cuda.synchronize(); print("matmul done")' \
      2>&1 | tail -20 | tee -a "$OUT"
    say ""
    say "# did a report actually get written?"
    ls -lh "$OUT_DIR"/nsys-trace-"${SLURM_JOB_ID:-nojob}"* 2>&1 | tee -a "$OUT"
  fi
else
  say "nsys not executable at that path"
fi

hdr "6. CUPTI, via the torch profiler inside our vLLM image"
if [ -f "$IMG" ]; then
  env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3 -c '
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
fi

hdr "7. NVML energy counter, the control we know works"
env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3 -c '
import pynvml as n
n.nvmlInit()
h = n.nvmlDeviceGetHandleByIndex(0)
print("uuid", n.nvmlDeviceGetUUID(h))
print("total energy mJ", n.nvmlDeviceGetTotalEnergyConsumption(h))
print("power mW", n.nvmlDeviceGetPowerUsage(h))
print("enforced limit mW", n.nvmlDeviceGetEnforcedPowerLimit(h))
' 2>&1 | tail -8 | tee -a "$OUT"

hdr "8. per-die spread, the experiment from plan section 13.5"
say "# every GPU on this node at the same instant: do nominally identical dies differ?"
nvidia-smi --query-gpu=index,uuid,name,power.draw,temperature.gpu,clocks.sm \
  --format=csv 2>&1 | tee -a "$OUT"

say ""
say "=== done: $OUT ==="
