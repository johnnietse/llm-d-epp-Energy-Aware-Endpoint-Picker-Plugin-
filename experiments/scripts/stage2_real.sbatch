#!/bin/bash
#SBATCH --job-name=stage2-real
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --exclusive
#SBATCH --cpus-per-task=32
#SBATCH --mem=240G
#SBATCH --time=05:00:00
#SBATCH --output=%x-%j-%N.out
#
# Stage 2, MEASURED. Replaces the modelled gate.
#
# Stands up one vLLM server per GPU on a single exclusive node, then drives them
# with real open-loop load under several placement policies, measuring the joules
# each policy actually costs from NVML's hardware counter per device.
#
# Nothing here is simulated: real queueing, real continuous batching, real
# contention, real energy. The only computed quantity is the lower bound, which
# is a bound by definition and is derived from the measured h1 curves.
#
# THREE MANDATORY PHASES, every job:
#   Pass 0  telemetry_check.sh  - verifies NVML energy+power, nvidia-smi
#                                 provenance and DCGM fields 156/155, and
#                                 ABORTS the job if any is missing. Records
#                                 kernel-gated sources (DCP, ncu) as data.
#   Pass A  policy_harness.py   - the energy measurement. No profiling tools
#                                 run here, because they perturb power and
#                                 timing.
#   Pass B  mechanism_pass.sh   - every profiling tool NVIDIA offers: CUPTI
#                                 tracing and counter probe, Nsight Systems
#                                 trace + stats, Nsight Compute, DCGM DCP
#                                 fields, nvidia-smi high-rate sampling.
#
# The split is why all tools can be mandatory without corrupting the headline
# numbers. Measured on 2026-10-03: RmProfilingAdminOnly=1 on 13 of 15 Frontenac
# nodes, so counter-based tools are denied there; the job records the denial
# rather than skipping silently.
#
# Submit pinned to a multi-GPU node, e.g.
#   sbatch -w frnt155 --gres=gpu:rtx6000:8 stage2_real.sbatch     # 8x RTX 6000
#   sbatch -w frnt154 --gres=gpu:a100:8    stage2_real.sbatch     # 8x A100
#   sbatch -w frnt140 --gres=gpu:a30:2     stage2_real.sbatch     # 2x A30 (smoke)
#
# Environment knobs: MODEL, RATES, REQUESTS, SLO, POLICIES, MAX_GPUS
#
# NOTE: do NOT add --disable-log-requests to the vllm serve line. vLLM 0.30.0
# removed it, and passing it kills every server instantly with
# "unrecognized arguments" - which is exactly how the first smoke run (job
# 12303323) failed. Verify any new serve flag against `vllm serve --help`
# inside the image before adding it.

if ! command -v module >/dev/null 2>&1; then
  source /cvmfs/soft.computecanada.ca/config/profile/bash.sh 2>/dev/null \
    || source "${LMOD_PKG:-/cvmfs/soft.computecanada.ca/custom/software/lmod/lmod}/init/bash" 2>/dev/null
fi
set -uo pipefail

module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"

ROOT="$HOME/energy-epp"
IMG="$ROOT/images/vllm-v0.30.0.sif"
RUN="$ROOT/results/stage2-$SLURM_JOB_ID"
mkdir -p "$RUN"
export HF_HOME="${HF_HOME:-$ROOT/.hf}"

MODEL="${MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"
REQUESTS="${REQUESTS:-600}"
POLICIES="${POLICIES:-round_robin,least_loaded,slo_packing,energy_greedy,energy_consolidate}"

NGPU="$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)"
# --exclusive gives us every GPU on the node regardless of --gres, so a smoke
# run needs an explicit cap. MAX_GPUS=2 proves the launcher without pretending
# to be the real fleet experiment.
if [ -n "${MAX_GPUS:-}" ] && [ "${MAX_GPUS}" -lt "$NGPU" ]; then
  echo "capping $NGPU visible GPUs to MAX_GPUS=$MAX_GPUS"
  NGPU="$MAX_GPUS"
fi
GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1 | tr ' ' '_')"
echo "node=$(hostname) gpus=$NGPU type=$GPU_NAME model=$MODEL"

# ------------------------------------------- MANDATORY telemetry gate (Pass 0)
# Fails the job if any required source is missing, so no numbers can come from
# a degraded instrument set. Records kernel-gated sources as data.
echo "=== mandatory telemetry check ==="
if ! bash "$ROOT/scripts/telemetry_check.sh" "$RUN/telemetry.txt"; then
  echo "FATAL: required telemetry unavailable on $(hostname); see $RUN/telemetry.txt"
  exit 1
fi

# ---------------------------------------------------------------- provenance
{
  echo "node=$(hostname) job=$SLURM_JOB_ID"
  echo "model=$MODEL requests_per_cell=$REQUESTS policies=$POLICIES"
  nvidia-smi --query-gpu=index,uuid,name,driver_version,power.limit,power.min_limit,power.max_limit,memory.total,persistence_mode --format=csv
  echo "kernel=$(uname -r)"
  echo "rm_profiling_admin_only=$(grep -oE 'RmProfilingAdminOnly: [0-9]+' /proc/driver/nvidia/params 2>/dev/null | awk '{print $2}' || echo NA)"
  echo "cotenants_at_start:"
  nvidia-smi --query-compute-apps=pid,used_memory --format=csv
  "$APPTAINER" exec "$IMG" python3 -c "import vllm,torch;print('vllm',vllm.__version__,'torch',torch.__version__)"
} | tee "$RUN/instruments.txt"

# ------------------------------------------------------- launch one server/GPU
PORTS=()
PIDS=()
for ((i=0; i<NGPU; i++)); do
  port=$((8100 + i))
  PORTS+=("127.0.0.1:$port")
  echo "launching vLLM on GPU $i port $port"
  CUDA_VISIBLE_DEVICES="$i" env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" \
    vllm serve "$MODEL" --served-model-name served \
      --host 127.0.0.1 --port "$port" \
      --gpu-memory-utilization 0.85 --max-model-len 2048 \
      > "$RUN/vllm-gpu$i.log" 2>&1 &
  PIDS+=($!)
done

cleanup() {
  echo "stopping servers"
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  sleep 5
  for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null; done
}
trap cleanup EXIT

echo "waiting for all $NGPU servers to report ready (up to 15 min)"
ready=0
for _ in $(seq 1 180); do
  ready=0
  for ep in "${PORTS[@]}"; do
    curl -fsS --max-time 3 "http://$ep/health" >/dev/null 2>&1 && ready=$((ready+1))
  done
  [ "$ready" -eq "$NGPU" ] && break
  sleep 5
done
echo "ready: $ready/$NGPU"
if [ "$ready" -ne "$NGPU" ]; then
  echo "FATAL: not all servers came up; see $RUN/vllm-gpu*.log"
  tail -20 "$RUN"/vllm-gpu0.log
  exit 1
fi

# ------------------------------------------------- single-endpoint calibration
# The per-endpoint SLO must come from this hardware, not from another node.
echo "calibrating single-request latency on endpoint 0"
CAL=$("$APPTAINER" exec "$IMG" python3 - <<'PY'
import json, time, urllib.request
body = json.dumps({"model":"served","prompt":"calibrate: explain caching.",
                   "max_tokens":128,"temperature":0.0}).encode()
req = urllib.request.Request("http://127.0.0.1:8100/v1/completions", data=body,
                             headers={"Content-Type":"application/json"})
lats=[]
for _ in range(5):
    t0=time.time()
    urllib.request.urlopen(req, timeout=120).read()
    lats.append(time.time()-t0)
lats.sort()
print(f"{lats[len(lats)//2]:.4f}")
PY
)
echo "median single-request latency: ${CAL}s"
SLO="${SLO:-$(python3 -c "print(f'{float('$CAL')*2:.4f}')" 2>/dev/null || echo 2.0)}"
echo "SLO = ${SLO}s (2x measured single-request latency)"

# -------------------------------------------------------------- load levels
# Peak token rate measured on this hardware -> requests/s, then sweep fractions.
PEAK_RPS="${PEAK_RPS:-}"
if [ -z "$PEAK_RPS" ]; then
  PEAK_RPS=$(python3 -c "print(f'{$NGPU * 2000.0 / 128.0:.1f}')" 2>/dev/null || echo 60)
  echo "PEAK_RPS not given; rough estimate ${PEAK_RPS} req/s (refine after the first run)"
fi
RATES="${RATES:-$(python3 -c "
p=$PEAK_RPS
print(','.join(f'{p*f:.1f}' for f in (0.4,0.7,0.9,1.1)))" 2>/dev/null || echo 20,40,60)}"
echo "load levels: $RATES req/s"

TYPES="$(python3 -c "print(','.join(['$GPU_NAME']*$NGPU))")"
CURVE_ARGS=""
# Two bugs lived here and both were caught by the smoke run (job 12303325):
#   1. the pairs were passed WITHOUT the --curves flag, so argparse rejected
#      them as positional and Pass A failed at every load level;
#   2. several h1.csv files share a GPU type name, including the 7B run, so the
#      last one won and the router would have been handed the 7B curve while
#      serving 1.5B. Now the curve must match the model actually being served.
for c in "$ROOT"/results/h1-*/h1.csv; do
  [ -f "$c" ] || continue
  inst="$(dirname "$c")/instruments.txt"
  [ -f "$inst" ] || continue
  # only curves measured with the SAME model we are serving
  grep -q "model=$MODEL" "$inst" || continue
  n="$(grep -m1 -oE 'NVIDIA A30|Quadro RTX 6000|NVIDIA L4|NVIDIA A100[^,]*|NVIDIA L40S|Quadro RTX 8000|Tesla V100[^,]*'         "$inst" 2>/dev/null | tr ' ' '_')"
  [ -n "$n" ] || continue
  # first match per type wins, so a later duplicate cannot silently replace it
  case " $CURVE_ARGS " in
    *"=$n "*) echo "  skipping duplicate curve for $n: $c" ;;
    *) CURVE_ARGS="$CURVE_ARGS $c=$n"; echo "  curve for $n: $c" ;;
  esac
done
[ -n "$CURVE_ARGS" ] && CURVE_ARGS="--curves $CURVE_ARGS"
echo "curves passed to the router: $CURVE_ARGS"

# ------------------------------------------------------------------- the runs
IFS=',' read -ra RATE_ARR <<< "$RATES"
for rate in "${RATE_ARR[@]}"; do
  echo "=========== offered load ${rate} req/s ==========="
  env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3 \
    "$ROOT/scripts/policy_harness.py" \
      --endpoints "$(IFS=,; echo "${PORTS[*]}")" \
      --gpus "$(seq -s, 0 $((NGPU-1)))" \
      --endpoint-types "$TYPES" \
      $CURVE_ARGS \
      --policies "$POLICIES" \
      --rate "$rate" --requests "$REQUESTS" --slo "$SLO" \
      --out "$RUN/policies-rate${rate}.json" 2>&1 | tee -a "$RUN/harness.log"
done

# ------------------------------- Pass A-control: prove telemetry costs nothing
# Mandatory. Re-runs ONE policy at the busiest load with the power-poll thread
# disabled (counter reads only). If full telemetry perturbed the measurement,
# this control would disagree with the corresponding Pass A cell. Any
# disagreement beyond the CI means the telemetry gets trimmed, not the result
# accepted.
CTRL_RATE="${RATE_ARR[${#RATE_ARR[@]}-1]}"
echo "=========== Pass A-control: counter-only at ${CTRL_RATE} req/s ==========="
env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3   "$ROOT/scripts/policy_harness.py"     --endpoints "$(IFS=,; echo "${PORTS[*]}")"     --gpus "$(seq -s, 0 $((NGPU-1)))"     --endpoint-types "$TYPES"     $CURVE_ARGS     --policies slo_packing     --rate "$CTRL_RATE" --requests "$REQUESTS" --slo "$SLO"     --poll-interval 0     --out "$RUN/control-counteronly.json" 2>&1 | tee -a "$RUN/harness.log"

echo "--- perturbation check: full telemetry vs counter-only ---"
python3 "$ROOT/scripts/perturbation_check.py"   "$RUN/policies-rate${CTRL_RATE}.json" "$RUN/control-counteronly.json"   2>&1 | tee -a "$RUN/harness.log"

# ------------------------------------------------------- Pass B: mechanism
# Separate pass, mandatory, AFTER all energy measurement is complete. These
# tools perturb timing and power, so they must never share a run with Pass A.
echo "letting the GPUs settle for 60 s so Pass B cannot touch Pass A numbers"
sleep 60
echo "=========== Pass B: mechanism (all profiling tools) ==========="
bash "$ROOT/scripts/mechanism_pass.sh" "$RUN/mechanism" 2>&1 | tail -40

echo "results in $RUN"
ls -l "$RUN"
echo
echo "Pass A (measured energy): policies-rate*.json"
echo "Pass B (mechanism):       mechanism/mechanism.txt"
echo "Telemetry gate:           telemetry.txt"
