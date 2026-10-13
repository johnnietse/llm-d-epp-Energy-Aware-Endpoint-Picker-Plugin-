#!/bin/bash
#SBATCH --job-name=pred-feas
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --gres=gpu:rtx6000:2
#SBATCH --cpus-per-task=12
#SBATCH --mem=64G
#SBATCH --time=01:30:00
#SBATCH --output=%x-%j-%N.out
#
# Feasibility check for the llmd_latency_least arm (amendment B7). Not a
# measurement. Questions, answered with records:
#   1. does llm-d-latency-predictor (pinned commit, wheels prefetched on the
#      login node) install and run inside the vLLM image on a compute node?
#   2. does the EPP with llm-d's latency stack route real requests through it?
#   3. does the predictor learn: training samples accepted, a model trained,
#      predictions served, and how long until then?
# The TTFT/TPOT SLO split is PROVISIONAL (54.0 / 15.32 ms, from olc-12325350
# at 1 req/s; the registered Stage 1 source has no TTFT). The retraining
# interval is shortened to RETRAIN_S here to see learning within the job; the
# upstream default (1800 s) is recorded as a protocol question, not changed.
set -uo pipefail
module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"
ROOT="$HOME/energy-epp"
IMG="$ROOT/images/vllm-v0.30.0.sif"; ENVOY_IMG="$ROOT/images/envoy.sif"
EPP_BIN="$ROOT/bin/epp-energy-v0.11.0"
: "${EPP_SHA:?}"
PRED="$ROOT/opt/latency-predictor"; SRC="$PRED/src"; VENV="$PRED/venv312"
# Own copies of the harness, config generator and Envoy template, so shipping
# them cannot change a job already running from $ROOT/scripts.
SCR="$ROOT/scripts-predfeas"
MODEL="Qwen/Qwen2.5-1.5B-Instruct"
RATE="${RATE:-20}"; CELLS="${CELLS:-6}"; CELL_S="${CELL_S:-60}"; RETRAIN_S="${RETRAIN_S:-60}"
SLO_TTFT_MS="${SLO_TTFT_MS:-54.0}"; SLO_TPOT_MS="${SLO_TPOT_MS:-15.32}"
RUN="$ROOT/results/pred-feas-$SLURM_JOB_ID"; mkdir -p "$RUN/models"
export HF_HOME="$ROOT/.hf"
BASE=$(( 30000 + (SLURM_JOB_ID % 2000) * 10 ))
V0=$BASE; V1=$((BASE+1)); EPP_GRPC=$((BASE+2)); EPP_HEALTH=$((BASE+3)); EPP_METRICS=$((BASE+4))
ENVOY_PORT=$((BASE+5)); ENVOY_ADMIN=$((BASE+6)); TRAIN_P=$((BASE+7)); PRED_P=$((BASE+8))
PIDS=(); cleanup() { for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; sleep 3; for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null; done; wait 2>/dev/null; }
trap cleanup EXIT
echo "node=$(hostname) job=$SLURM_JOB_ID commit=$(git -C "$SRC" rev-parse HEAD)"
[ "$(sha256sum "$EPP_BIN" | cut -d' ' -f1)" = "$EPP_SHA" ] || { echo "FATAL: EPP hash"; exit 1; }

# ---- 1. install, offline, inside the container
if [ ! -x "$VENV/bin/uvicorn" ]; then
  env -u SSL_CERT_FILE "$APPTAINER" exec "$IMG" bash -c "
    python3 -m venv '$VENV' && '$VENV/bin/pip' install -q --no-index --find-links '$PRED/wheels312' -r '$SRC/requirements.txt'" \
    > "$RUN/install.log" 2>&1
  echo "install exit=$?"; tail -3 "$RUN/install.log"
fi
env -u SSL_CERT_FILE "$APPTAINER" exec "$IMG" "$VENV/bin/python" -c \
  "import fastapi, uvicorn, xgboost, lightgbm, sklearn; print('deps ok: xgboost', xgboost.__version__, 'lightgbm', lightgbm.__version__)" \
  || { echo "FATAL: predictor dependencies do not import in the container"; exit 1; }

# ---- 2. predictor servers
cd "$SRC"
env -u SSL_CERT_FILE LATENCY_RETRAINING_INTERVAL_SEC="$RETRAIN_S" \
  LATENCY_TTFT_MODEL_PATH="$RUN/models/ttft.joblib" LATENCY_TPOT_MODEL_PATH="$RUN/models/tpot.joblib" \
  LATENCY_TTFT_SCALER_PATH="$RUN/models/ttft_scaler.joblib" LATENCY_TPOT_SCALER_PATH="$RUN/models/tpot_scaler.joblib" \
  LATENCY_TTFT_GATED_MODEL_PATH="$RUN/models/ttft_gated.joblib" LATENCY_TPOT_GATED_MODEL_PATH="$RUN/models/tpot_gated.joblib" \
  "$APPTAINER" exec "$IMG" "$VENV/bin/uvicorn" training.training_server:app --host 127.0.0.1 --port "$TRAIN_P" \
  > "$RUN/training.log" 2>&1 & PIDS+=($!)
mkdir -p "$RUN/local_models"
env -u SSL_CERT_FILE TRAINING_SERVER_URL="http://127.0.0.1:$TRAIN_P" PREDICT_PORT="$PRED_P" PREDICT_HOST=127.0.0.1 \
  LOCAL_TTFT_MODEL_PATH="$RUN/local_models/ttft.joblib" LOCAL_TPOT_MODEL_PATH="$RUN/local_models/tpot.joblib" \
  LOCAL_TTFT_SCALER_PATH="$RUN/local_models/ttft_scaler.joblib" LOCAL_TPOT_SCALER_PATH="$RUN/local_models/tpot_scaler.joblib" \
  MODEL_SYNC_INTERVAL_SEC=10 \
  "$APPTAINER" exec "$IMG" "$VENV/bin/uvicorn" prediction.prediction_server:app --host 127.0.0.1 --port "$PRED_P" \
  > "$RUN/prediction.log" 2>&1 & PIDS+=($!)
cd "$RUN"
d=$(( $(date +%s) + 180 ))
until curl -fsS "http://127.0.0.1:$TRAIN_P/healthz" >/dev/null 2>&1 && curl -fsS "http://127.0.0.1:$PRED_P/healthz" >/dev/null 2>&1; do
  [ "$(date +%s)" -ge "$d" ] && { echo "FATAL: predictor servers not healthy"; tail -5 "$RUN"/training.log "$RUN"/prediction.log; exit 1; }
  sleep 3
done
echo "predictor servers healthy (training :$TRAIN_P, prediction :$PRED_P)"

# ---- 3. two vLLM servers
STAGE_DIR="/tmp/hfstage-$SLURM_JOB_ID"; MDN="models--Qwen--Qwen2.5-1.5B-Instruct"
mkdir -p "$STAGE_DIR/hub/$MDN"; for part in refs snapshots; do cp -rL "$HF_HOME/hub/$MDN/$part" "$STAGE_DIR/hub/$MDN/"; done
export HF_HOME="$STAGE_DIR" HF_HUB_OFFLINE=1
IFS=',' read -r -a G <<< "${CUDA_VISIBLE_DEVICES:-0,1}"
i=0; for p in "$V0" "$V1"; do
  CUDA_VISIBLE_DEVICES="${G[$i]}" env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" vllm serve "$MODEL" \
    --served-model-name served --host 127.0.0.1 --port "$p" --gpu-memory-utilization 0.85 --max-model-len 2048 \
    --max-num-seqs 256 --max-num-batched-tokens 2048 > "$RUN/vllm-$i.log" 2>&1 & PIDS+=($!); i=$((i+1)); sleep 8
done
d=$(( $(date +%s) + 900 ))
until curl -fsS "http://127.0.0.1:$V0/health" >/dev/null 2>&1 && curl -fsS "http://127.0.0.1:$V1/health" >/dev/null 2>&1; do
  [ "$(date +%s)" -ge "$d" ] && { echo "FATAL: vLLM"; exit 1; }; sleep 5; done
printf 'endpoints:\n  - name: vllm-0\n    address: "127.0.0.1"\n    port: "%s"\n  - name: vllm-1\n    address: "127.0.0.1"\n    port: "%s"\n' "$V0" "$V1" > "$RUN/endpoints.yaml"

# ---- 4. EPP (llm-d latency stack) + Envoy
ARM=llmd_latency_least ENDPOINTS="$RUN/endpoints.yaml" bash "$SCR/epp-config.sh" > "$RUN/epp.yaml"
TRAINING_SERVER_URL="http://127.0.0.1:$TRAIN_P" PREDICTION_SERVER_URL="http://127.0.0.1:$PRED_P" \
  "$EPP_BIN" --pool-name epp --config-file "$RUN/epp.yaml" --secure-serving=false --metrics-endpoint-auth=false \
  --tracing=false --grpc-port "$EPP_GRPC" --grpc-health-port "$EPP_HEALTH" --metrics-port "$EPP_METRICS" \
  > "$RUN/epp.log" 2>&1 & PIDS+=($!)
sed -e "s/ENVOY_ADMIN/$ENVOY_ADMIN/; s/ENVOY_PORT/$ENVOY_PORT/; s/EPP_GRPC/$EPP_GRPC/g" "$SCR/envoy-template.yaml" > "$RUN/envoy.yaml"
"$APPTAINER" exec "$ENVOY_IMG" envoy -c "$RUN/envoy.yaml" --disable-hot-restart --log-level warn > "$RUN/envoy.log" 2>&1 & PIDS+=($!)
d=$(( $(date +%s) + 120 ))
until [ "$(curl -s --max-time 2 "http://127.0.0.1:$ENVOY_ADMIN/ready")" = "LIVE" ] && curl -s "http://127.0.0.1:$EPP_METRICS/metrics" >/dev/null; do
  [ "$(date +%s)" -ge "$d" ] && { echo "FATAL: router"; tail -5 "$RUN/epp.log"; exit 1; }; sleep 2; done
grep -oE '\{Filters: \[[^]]*\], Scorers: \[[^]]*\], Picker: [^}"]*' "$RUN/epp.log" | head -1

served() { local n; n="$(grep -c 'POST /v1/completions' "$RUN/vllm-$1.log" 2>/dev/null)"; echo "${n:-0}"; }
snap() {  # $1 label: predictor state
  echo "--- $1 $(date +%H:%M:%S)"
  curl -s --max-time 5 "http://127.0.0.1:$TRAIN_P/data/status" | head -c 600; echo
  curl -s --max-time 5 "http://127.0.0.1:$PRED_P/status" | head -c 600; echo
}
snap "before traffic" | tee -a "$RUN/predictor-state.txt"

# ---- 5. consecutive cells: does it learn?
for c in $(seq 1 "$CELLS"); do
  a="$(served 0)"; b="$(served 1)"
  env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3 "$SCR/policy_harness.py" \
    --endpoints "127.0.0.1:$V0,127.0.0.1:$V1" --gpus 0,1 --endpoint-types rtx6000,rtx6000 \
    --policies llmd_latency_least --router "127.0.0.1:$ENVOY_PORT" --epp-metrics "127.0.0.1:$EPP_METRICS" \
    --slo-ttft-ms "$SLO_TTFT_MS" --slo-tpot-ms "$SLO_TPOT_MS" --energy-window traffic \
    --rate "$RATE" --requests $(( RATE * CELL_S )) --slo 2.0 --workers 2 --scratch "$RUN" --seed $((900 + c)) \
    --out "$RUN/cell-$c.json" > "$RUN/cell-$c.log" 2>&1
  d0=$(( $(served 0) - a )); d1=$(( $(served 1) - b ))
  python3 - "$RUN/cell-$c.json" "$c" "$d0" "$d1" <<'PY' | tee -a "$RUN/cells.txt"
import json, sys
try:
    r = json.load(open(sys.argv[1])); r = r["results"][0]
    print("cell %s: completed=%s errors=%s split=%s/%s p95=%.2fs slo=%.3f ttft_p50=%.3fs keepup=%.3f"
          % (sys.argv[2], r["completed"], r["errors"], sys.argv[3], sys.argv[4], r["latency_p95"] or -1,
             r["slo_rate"], r["ttft_p50"] or -1, r["keepup"] or -1))
except Exception as e:
    print("cell %s: no record (%s)" % (sys.argv[2], e))
PY
  snap "after cell $c" >> "$RUN/predictor-state.txt"
done
echo; echo "=== predictor state over time"; cat "$RUN/predictor-state.txt" | cut -c1-300
echo; echo "=== EPP prediction errors (count)"; grep -c '"severity_text":"ERROR"' "$RUN/epp.log"
grep -m3 '"severity_text":"ERROR"' "$RUN/epp.log" | cut -c1-300
exit 0
