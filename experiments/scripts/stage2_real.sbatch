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
# Environment knobs: MODEL, RATES, DURATION, SLO, POLICIES, MAX_GPUS,
#                    PEAK_RPS, CALIBRATE
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
# Cell length in seconds. Defined here, before anything echoes it.
DURATION="${DURATION:-60}"
# REQUESTS was replaced by DURATION; cells are sized by window length now.
if [ -n "${REQUESTS:-}" ]; then
  echo "NOTE: REQUESTS=$REQUESTS is ignored; cells are sized by DURATION"
fi
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
  echo "model=$MODEL cell_window_s=$DURATION policies=$POLICIES"
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
  # Derived from the Stage 1 sweep for THIS GPU type and THIS model, not from a
  # guessed tokens/s constant. The old estimate was NGPU * 2000 / 128, which
  # for 8 RTX 6000 gave 125 req/s; the measured single-GPU peak is 21.1 req/s
  # (concurrency 32, p95 1.53 s), so the real figure is ~169 req/s and the
  # guess was 26% low. Guessing in either direction puts the swept range in
  # the wrong place relative to the SLO knee, which is the whole point of the
  # sweep.
  #
  # The h1 sweep stopped at concurrency 32 with throughput still climbing, so
  # this is a measured LOWER BOUND on capacity, not the peak. The top sweep
  # fraction therefore goes above 1.0 deliberately.
  PEAK_RPS=$(python3 - "$ROOT" "$GPU_NAME" "$MODEL" "$NGPU" <<'PY'
import csv, glob, os, sys
root, gpu_name, model, ngpu = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
want = gpu_name.replace("_", " ")
best = 0.0
for c in sorted(glob.glob(os.path.join(root, "results", "h1-*", "h1.csv"))):
    inst = os.path.join(os.path.dirname(c), "instruments.txt")
    try:
        text = open(inst).read()
    except OSError:
        continue
    if "model=" + model not in text or want not in text:
        continue
    with open(c) as fh:
        for row in csv.DictReader(fh):
            # The file carries a repeated header row; skip any non-numeric row
            # rather than trusting the layout.
            try:
                rps = float(row["throughput_rps"])
            except (TypeError, ValueError):
                continue
            if row.get("note") == "unique_prompts":
                best = max(best, rps)
print("%.1f" % (best * ngpu) if best else "")
PY
) || PEAK_RPS=""
  if [ -n "$PEAK_RPS" ]; then
    echo "PEAK_RPS ${PEAK_RPS} req/s from the measured Stage 1 curve for $GPU_NAME / $MODEL"
  else
    echo "NO measured Stage 1 curve for $GPU_NAME / $MODEL."
    echo "Refusing to invent a capacity figure: run the h1 sweep for this"
    echo "GPU type and model first, or pass PEAK_RPS explicitly."
    exit 1
  fi
fi
# Fractions bracket the SLO knee on both sides. PEAK_RPS is a measured lower
# bound (the Stage 1 sweep was still climbing at its top concurrency), so the
# range extends past 1.0 to make sure the knee is inside the swept interval
# rather than beyond its right edge. Job 12303327 swept 0.4-1.1 of a figure
# that was itself 26% low, which would have put every cell below saturation
# even if the generator had worked.
RATES="${RATES:-$(python3 -c "
p=$PEAK_RPS
print(','.join(f'{p*f:.1f}' for f in (0.4,0.7,1.0,1.3,1.6)))" 2>/dev/null || echo 20,40,60)}"
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
# Cell length is set by DURATION, not by a fixed request count. With a fixed
# count the measurement window shrinks as the offered rate rises - 600
# requests is a 12 s window at 50 req/s but a 4.4 s window at 137.5 req/s - so
# the high-load cells, which are the ones the research question is about, got
# the shortest and noisiest energy windows. Equal windows also keep every cell
# far above the measured counter floor (1.0 s on A30, 0.5 s on RTX 6000) and
# comparable to the 75 s windows used in Stage 1.
IFS=',' read -ra RATE_ARR <<< "$RATES"
for rate in "${RATE_ARR[@]}"; do
  n_req="$(python3 -c "import math;print(max(100, math.ceil($rate * $DURATION)))")"
  echo "=========== offered load ${rate} req/s, ${DURATION}s window, ${n_req} requests ==========="
  env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3 \
    "$ROOT/scripts/policy_harness.py" \
      --endpoints "$(IFS=,; echo "${PORTS[*]}")" \
      --gpus "$(seq -s, 0 $((NGPU-1)))" \
      --endpoint-types "$TYPES" \
      $CURVE_ARGS \
      --policies "$POLICIES" \
      --rate "$rate" --requests "$n_req" --slo "$SLO" \
      --out "$RUN/policies-rate${rate}.json" 2>&1 | tee -a "$RUN/harness.log"
done

# ------------------------------- Pass A-control: prove telemetry costs nothing
# Mandatory. Re-runs ONE policy at the busiest load with the power-poll thread
# disabled (counter reads only). If full telemetry perturbed the measurement,
# this control would disagree with the corresponding Pass A cell. Any
# disagreement beyond the CI means the telemetry gets trimmed, not the result
# accepted.
CTRL_RATE="${RATE_ARR[${#RATE_ARR[@]}-1]}"
# Same window as the Pass A cell it is compared against. Comparing a
# 60 s cell to a 600-request cell would make the perturbation check
# measure the window length difference rather than the telemetry.
CTRL_REQ="$(python3 -c "import math;print(max(100, math.ceil($CTRL_RATE * $DURATION)))")"
if [ -n "${CALIBRATE:-}" ]; then
  # Calibration mode. The point of a calibration run is to find two numbers
  # before committing to a measurement sweep: the highest offered rate this
  # generator can actually deliver, and the load at which the SLO starts to
  # bind. Neither needs the telemetry control or the mechanism pass, and both
  # of those cost ~10 minutes of node time, so skip them.
  echo
  echo "=========== CALIBRATION MODE ==========="
  echo "Skipping Pass A-control and Pass B. Read the per-cell lines above:"
  echo "  fidelity near 100% and no CLIENT LIMITED  -> generator delivered this rate"
  echo "  CLIENT LIMITED                            -> generator ceiling reached"
  echo "  SLO falling while fidelity stays high     -> real saturation knee"
  echo "results in $RUN"
  exit 0
fi
echo "=========== Pass A-control: counter-only at ${CTRL_RATE} req/s ==========="
env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3   "$ROOT/scripts/policy_harness.py"     --endpoints "$(IFS=,; echo "${PORTS[*]}")"     --gpus "$(seq -s, 0 $((NGPU-1)))"     --endpoint-types "$TYPES"     $CURVE_ARGS     --policies slo_packing     --rate "$CTRL_RATE" --requests "$CTRL_REQ" --slo "$SLO"     --poll-interval 0     --out "$RUN/control-counteronly.json" 2>&1 | tee -a "$RUN/harness.log"

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
