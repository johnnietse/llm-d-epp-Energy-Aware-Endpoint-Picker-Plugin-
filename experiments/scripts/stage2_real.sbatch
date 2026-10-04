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
# Environment knobs: MODEL, RATES, DURATION, SLO, POLICIES, MAX_GPUS, WORKERS, SEED,
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
# Arrival-process seed. The rejected verdict from job 12303355 rested on a
# sub-percent latency difference with one trial per cell and no confidence
# interval, so repeat trials under different seeds are mandatory before any
# policy ordering is reported. make_prompt() derives prompt length from
# (seed, request index), so a seed now genuinely reproduces a workload.
SEED="${SEED:-7}"
# Load-generator processes. 0 = let the harness choose from core count.
# One asyncio process was measured at ~115 req/s on this node (job
# 12303350), below the SLO knee, so the generator has to shard.
WORKERS="${WORKERS:-0}"
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
  echo "model=$MODEL cell_window_s=$DURATION policies=$POLICIES generator_workers=$WORKERS seed=$SEED"
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
  # Stagger. All eight servers read the SAME 2.88 GiB checkpoint from GPFS;
  # launching them simultaneously means eight cold concurrent readers of one
  # file, which is the most likely trigger for the wedge seen in job 12303653.
  # A short offset lets the first reader warm the page cache for the rest.
  # Explicit if, not "[ ] && sleep": the latter evaluates false on the last
  # iteration, which is harmless under "set -uo pipefail" but would abort
  # the loop the moment anyone adds -e.
  if [ "$i" -lt "$((NGPU - 1))" ]; then sleep "${LAUNCH_STAGGER_S:-8}"; fi
done

cleanup() {
  echo "stopping servers"
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  sleep 5
  for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null; done
}
trap cleanup EXIT

# Readiness wait, bounded by WALL CLOCK and by progress, not by an iteration
# count.
#
# This loop used to be `for _ in $(seq 1 180)` with a 5 s sleep, described as
# "up to 15 min". That only holds if every curl returns instantly; with
# --max-time 3 against eight endpoints an iteration can take 29 s, so the real
# bound was 87 minutes. Job 12303653 did worse than either: vLLM wedged at
# "Loading safetensors checkpoint shards: 0%" and wrote nothing for two hours
# while the job held an 8-GPU exclusive node, and the script never reached its
# own FATAL branch.
#
# So: a hard deadline from date(1), and a stall check on the server logs. A
# load that has not written a byte in STALL_S is not slow, it is stuck, and
# waiting longer costs node time without changing the outcome.
READY_TIMEOUT_S="${READY_TIMEOUT_S:-900}"
STALL_S="${STALL_S:-240}"
echo "waiting for all $NGPU servers to report ready"
echo "  hard deadline ${READY_TIMEOUT_S}s; abort if no server log grows for ${STALL_S}s"
ready=0
deadline=$(( $(date +%s) + READY_TIMEOUT_S ))
# Sizes as a concatenated string, not a sum: change detection does not need
# arithmetic, and this avoids depending on bc or awk being present.
log_size_sum() { stat -c%s "$RUN"/vllm-gpu*.log 2>/dev/null | tr "
" " "; }
last_size="$(log_size_sum)"; last_change=$(date +%s)
while [ "$(date +%s)" -lt "$deadline" ]; do
  ready=0
  for ep in "${PORTS[@]}"; do
    curl -fsS --max-time 3 "http://$ep/health" >/dev/null 2>&1 && ready=$((ready+1))
  done
  [ "$ready" -eq "$NGPU" ] && break
  now_size="$(log_size_sum)"
  if [ "$now_size" != "$last_size" ]; then
    last_size="$now_size"; last_change=$(date +%s)
  elif [ $(( $(date +%s) - last_change )) -ge "$STALL_S" ]; then
    echo "FATAL: no server log has grown in ${STALL_S}s and only $ready/$NGPU are up."
    echo "The model load is wedged, not slow. Last lines per server:"
    for f in "$RUN"/vllm-gpu*.log; do
      printf '  %s: ' "$(basename "$f")"; tail -1 "$f" | cut -c1-120
    done
    exit 1
  fi
  sleep 5
done
echo "ready: $ready/$NGPU after $(( $(date +%s) - (deadline - READY_TIMEOUT_S) ))s"
if [ "$ready" -ne "$NGPU" ]; then
  echo "FATAL: not all servers came up within ${READY_TIMEOUT_S}s; see $RUN/vllm-gpu*.log"
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

# Curve selection. Three bugs have lived here.
#
#   1. The pairs were passed WITHOUT the --curves flag, so argparse took them
#      as positional arguments and Pass A failed at every load level (job
#      12303325).
#   2. Several h1.csv files share a GPU type name, including the 7B sweep, so
#      the last match won and the router could be handed a 7B energy curve
#      while serving 1.5B.
#   3. "First match per type wins" plus a lexically sorted glob meant the
#      OLDEST curve won, which is the WORST one. The A30 curve in use was
#      h1-12302437 with levels=1,4 - two points - while h1-12303200 has six.
#      And an extended curve measured to concurrency 128 would have been
#      discarded as a duplicate of the 32-level one it was meant to replace,
#      silently leaving the router extrapolating exactly as before.
#
# So selection is now explicit: among curves measured with the SAME model and
# matching the GPU type, take the one whose top concurrency level is highest,
# breaking ties on the newest job id. Coverage is what matters, because a
# lookup above the top measured level now returns no answer at all.
CURVE_ARGS="$(python3 - "$ROOT" "$MODEL" <<'PYSEL'
import glob
import os
import re
import sys

root, model = sys.argv[1], sys.argv[2]
TYPES = (r"NVIDIA A30|Quadro RTX 6000|NVIDIA L4|NVIDIA A100[^,\s]*|NVIDIA L40S"
         r"|Quadro RTX 8000|Tesla V100[^,\s]*")

best = {}
for csv_path in glob.glob(os.path.join(root, "results", "h1-*", "h1.csv")):
    run_dir = os.path.dirname(csv_path)
    try:
        text = open(os.path.join(run_dir, "instruments.txt")).read()
    except OSError:
        continue
    if "model=" + model not in text:
        continue
    gpu = re.search(TYPES, text)
    if not gpu:
        continue
    levels = re.search(r"levels=([0-9,]+)", text)
    if not levels:
        continue
    try:
        tops = max(int(x) for x in levels.group(1).split(",") if x)
    except ValueError:
        continue
    jobid = re.search(r"h1-(\d+)", run_dir)
    jobid = int(jobid.group(1)) if jobid else 0
    name = gpu.group(0).replace(" ", "_")
    key = (tops, jobid)
    if name not in best or key > best[name][0]:
        best[name] = (key, csv_path, levels.group(1))

args = []
for name in sorted(best):
    (tops, jobid), csv_path, levels = best[name]
    print("  curve for %s: %s (levels=%s, top concurrency %d)"
          % (name, csv_path, levels, tops), file=sys.stderr)
    args.append("%s=%s" % (csv_path, name))
if args:
    print("--curves " + " ".join(args))
PYSEL
)"
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
      --rate "$rate" --requests "$n_req" --slo "$SLO" --workers "$WORKERS" --scratch "$RUN" --seed "$SEED" \
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
env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3   "$ROOT/scripts/policy_harness.py"     --endpoints "$(IFS=,; echo "${PORTS[*]}")"     --gpus "$(seq -s, 0 $((NGPU-1)))"     --endpoint-types "$TYPES"     $CURVE_ARGS     --policies slo_packing     --rate "$CTRL_RATE" --requests "$CTRL_REQ" --slo "$SLO"     --workers "$WORKERS" --scratch "$RUN" --seed "$SEED"     --poll-interval 0     --out "$RUN/control-counteronly.json" 2>&1 | tee -a "$RUN/harness.log"

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
