#!/bin/bash
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --gres=gpu:1
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
TRIALS=${TRIALS:-2}
export HF_HOME=${HF_HOME:-$ROOT/.hf}

# python with pynvml (module python has it, /usr/bin/python3 does not)
PY=""
for cand in "$(command -v python3)" /cvmfs/soft.computecanada.ca/gentoo/2023/x86-64-v3/usr/bin/python3; do
  [ -x "$cand" ] || continue
  "$cand" -c "import pynvml" 2>/dev/null && { PY="$cand"; break; }
done
[ -n "$PY" ] || { echo "FATAL: no python with pynvml"; exit 1; }

{
  echo "node=$(hostname) job=$SLURM_JOB_ID"
  echo "model=$MODEL levels=$LEVELS seconds=$SECONDS_PER_LEVEL trials=$TRIALS"
  nvidia-smi --query-gpu=index,name,driver_version,power.limit,memory.total,persistence_mode --format=csv
  echo "vllm_image=$(ls -l $ROOT/images/vllm-v0.30.0.sif | awk '{print $5}')"
  "$APPTAINER" exec $ROOT/images/vllm-v0.30.0.sif python3 -c "import vllm,torch;print('vllm',vllm.__version__,'torch',torch.__version__)"
} | tee "$RUN/instruments.txt"

# 1. idle power with NO process on the GPU (one of the three idle states H3 needs)
"$PY" - <<'PY' | tee "$RUN/idle_bare.txt"
import pynvml as n, time
n.nvmlInit(); h = n.nvmlDeviceGetHandleByIndex(0)
e0 = n.nvmlDeviceGetTotalEnergyConsumption(h); t0 = time.time()
time.sleep(30)
e1 = n.nvmlDeviceGetTotalEnergyConsumption(h); t1 = time.time()
print(f"idle_bare_w={(e1-e0)/1000/(t1-t0):.2f}")
PY

# 2. background power trace for the whole sweep
"$PY" $ROOT/scripts/energy_exporter.py --interval 1 --out "$RUN/trace.jsonl" &
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
"$PY" $ROOT/scripts/h1_sweep.py \
  --base http://127.0.0.1:8100 --model "$MODEL" --gpu 0 \
  --levels "$LEVELS" --seconds "$SECONDS_PER_LEVEL" --warmup 15 \
  --max-tokens 128 --trials "$TRIALS" --prefix-levels 8 \
  --out "$RUN/h1.csv" 2>&1 | tee "$RUN/sweep.log"

# 5. teardown, then idle again to check drift
pkill -f "vllm serve" 2>/dev/null
sleep 20
kill $EXPORTER 2>/dev/null

# 6. fit
"$PY" $ROOT/scripts/h1_fit.py "$RUN/h1.csv" 2>&1 | tee "$RUN/fit.txt"
echo "results in $RUN"
