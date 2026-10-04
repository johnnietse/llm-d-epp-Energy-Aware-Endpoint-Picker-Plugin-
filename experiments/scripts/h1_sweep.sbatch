#!/bin/bash
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --gres=gpu:1
#SBATCH --exclusive
#SBATCH --cpus-per-task=12
#SBATCH --mem=48G
#SBATCH --time=03:00:00
#SBATCH --job-name=h1-sweep
#SBATCH --output=%x-%j.out

# H1: power and energy-per-token as a function of load, on one GPU.
# Environment handling mirrors smoke_test.sbatch (Lmod in batch shells, set -u
# ordering, container cert vars) -- see that script's history for why.

if ! command -v module >/dev/null 2>&1; then
  source /cvmfs/soft.computecanada.ca/config/profile/bash.sh 2>/dev/null || source ${LMOD_PKG:-/cvmfs/soft.computecanada.ca/custom/software/lmod/lmod}/init/bash 2>/dev/null
fi
module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null
APPTAINER=$(command -v apptainer || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)
"$APPTAINER" --version >/dev/null || { echo "FATAL: no apptainer"; exit 1; }
set -u

ROOT=~/energy-epp
RUN=$ROOT/results/h1-$SLURM_JOB_ID
mkdir -p "$RUN"
MODEL=${MODEL:-Qwen/Qwen2.5-1.5B-Instruct}
LEVELS=${LEVELS:-1,2,4,8,16,32}
SECONDS_PER_LEVEL=${SECONDS_PER_LEVEL:-75}
TRIALS=${TRIALS:-5}
export HF_HOME=${HF_HOME:-$ROOT/.hf}

# Python that can actually READ THE ENERGY COUNTER, not merely import pynvml.
#
# This probe used to be `python3 -c "import pynvml"`. pynvml is pip-installed
# under ~/.local for the CVMFS python, so the import succeeds there even when
# the driver library is not on that interpreter's loader path - and nvmlInit()
# then dies with "libnvidia-ml.so.1: cannot open shared object file". Job
# 12303357 was lost exactly that way, after the probe had reported success.
#
# So the probe now exercises the whole path we depend on: import, nvmlInit,
# and one read of the total-energy counter. If the host pythons cannot do it,
# fall back to the container python, where apptainer --nv injects the driver
# libraries. PY is a command PREFIX so either case is invoked the same way.
pynvml_works() {  # $@ = candidate command prefix
  "$@" - <<'PROBE' >/dev/null 2>&1
import pynvml
pynvml.nvmlInit()
pynvml.nvmlDeviceGetTotalEnergyConsumption(pynvml.nvmlDeviceGetHandleByIndex(0))
PROBE
}

PY=""
for cand in "$(command -v python3)" /cvmfs/soft.computecanada.ca/gentoo/2023/x86-64-v3/usr/bin/python3; do
  [ -x "$cand" ] || continue
  if pynvml_works "$cand"; then PY="$cand"; break; fi
done
if [ -z "$PY" ]; then
  echo "no host python can read the NVML energy counter; trying the container"
  if pynvml_works env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$ROOT/images/vllm-v0.30.0.sif" python3; then
    PY="env -u SSL_CERT_FILE $APPTAINER exec --nv $ROOT/images/vllm-v0.30.0.sif python3"
  fi
fi
if [ -z "$PY" ]; then
  echo "FATAL: no python can read the NVML energy counter."
  echo "An import check is not sufficient here: pynvml imports from ~/.local"
  echo "even when libnvidia-ml.so.1 is unreachable, which is how job 12303357"
  echo "failed after its probe passed. Refusing to run a sweep with no"
  echo "energy instrument."
  exit 1
fi
echo "energy-counter python: $PY"

{
  echo "node=$(hostname) job=$SLURM_JOB_ID"
  echo "model=$MODEL levels=$LEVELS seconds=$SECONDS_PER_LEVEL trials=$TRIALS"
  nvidia-smi --query-gpu=index,uuid,name,driver_version,power.limit,power.min_limit,power.max_limit,memory.total,persistence_mode --format=csv
  # Non-uniform across this cluster (survey 2026-10-03), so comparability
  # depends on recording them per run, not on assuming they match:
  echo "kernel=$(uname -r)"
  echo "rm_profiling_admin_only=$(grep -oE 'RmProfilingAdminOnly: [0-9]+' /proc/driver/nvidia/params 2>/dev/null | awk '{print $2}' || echo NA)"
  echo "slurm_constraint=${SLURM_JOB_CONSTRAINTS:-none} exclusive=${SLURM_JOB_NUM_NODES:-?}node"
  echo "node_features=$(scontrol show node "$(hostname -s)" 2>/dev/null | tr ' ' '
' | grep -oE 'ActiveFeatures=.*' || echo NA)"
  # Co-tenancy guard: anything listed here but our own vLLM invalidates the run
  echo "cotenants_at_start:"
  nvidia-smi --query-compute-apps=pid,used_memory --format=csv
  echo "vllm_image=$(ls -l $ROOT/images/vllm-v0.30.0.sif | awk '{print $5}')"
  "$APPTAINER" exec $ROOT/images/vllm-v0.30.0.sif python3 -c "import vllm,torch;print('vllm',vllm.__version__,'torch',torch.__version__)"
} | tee "$RUN/instruments.txt"

# 1. idle power with NO process on the GPU (one of the three idle states H3 needs)
$PY - <<'PY' | tee "$RUN/idle_bare.txt"
import pynvml as n, time
n.nvmlInit(); h = n.nvmlDeviceGetHandleByIndex(0)
e0 = n.nvmlDeviceGetTotalEnergyConsumption(h); t0 = time.time()
time.sleep(30)
e1 = n.nvmlDeviceGetTotalEnergyConsumption(h); t1 = time.time()
print(f"idle_bare_w={(e1-e0)/1000/(t1-t0):.2f}")
PY

# 2. background power trace for the whole sweep
$PY $ROOT/scripts/energy_exporter.py --interval 1 --out "$RUN/trace.jsonl" &
EXPORTER=$!

# 3. one vLLM on the GPU
env -u SSL_CERT_FILE -u REQUESTS_CA_BUNDLE -u CURL_CA_BUNDLE -u SSL_CERT_DIR \
  "$APPTAINER" exec --nv --env HF_HOME=$HF_HOME \
  "$ROOT/images/vllm-v0.30.0.sif" \
  vllm serve "$MODEL" --port 8100 --host 127.0.0.1 \
    --gpu-memory-utilization 0.85 --max-model-len 4096 \
    > "$RUN/vllm.log" 2>&1 &

for t in $(seq 1 90); do
  curl -sf http://127.0.0.1:8100/v1/models >/dev/null && { echo "vllm up after ${t}0s"; break; }
  sleep 10
done
curl -sf http://127.0.0.1:8100/v1/models >/dev/null || { echo "FATAL: vllm never came up"; tail -20 "$RUN/vllm.log"; kill $EXPORTER; exit 1; }

# 4. the sweep
$PY $ROOT/scripts/h1_sweep.py \
  --base http://127.0.0.1:8100 --model "$MODEL" --gpu 0 \
  --levels "$LEVELS" --seconds "$SECONDS_PER_LEVEL" --warmup 15 \
  --max-tokens 128 --trials "$TRIALS" --prefix-levels 8 \
  --out "$RUN/h1.csv" 2>&1 | tee "$RUN/sweep.log"

# 5. teardown, then idle again to check drift
pkill -f "vllm serve" 2>/dev/null
sleep 20
kill $EXPORTER 2>/dev/null

# 6. fit
$PY $ROOT/scripts/h1_fit.py "$RUN/h1.csv" 2>&1 | tee "$RUN/fit.txt"
echo "results in $RUN"
