#!/bin/bash
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --gres=gpu:2
#SBATCH --cpus-per-task=16
#SBATCH --mem=64G
#SBATCH --time=01:30:00
#SBATCH --job-name=energy-epp-smoke
#SBATCH --output=%x-%j.out

# Month-1 smoke test: 2 vLLM servers + EPP (file discovery) + Envoy on one node,
# with the energy exporter sampling both GPUs throughout.
if ! command -v module >/dev/null 2>&1; then
  source /cvmfs/soft.computecanada.ca/config/profile/bash.sh 2>/dev/null || source ${LMOD_PKG:-/cvmfs/soft.computecanada.ca/custom/software/lmod/lmod}/init/bash 2>/dev/null
fi
module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null
APPTAINER=$(command -v apptainer || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)
echo "apptainer: $APPTAINER"
"$APPTAINER" --version || { echo "FATAL: no apptainer"; exit 1; }
set -u


ROOT=~/energy-epp
RUN=$ROOT/results/$SLURM_JOB_ID
mkdir -p "$RUN"
MODEL=${MODEL:-Qwen/Qwen2.5-1.5B-Instruct}
export HF_HOME=${HF_HOME:-$ROOT/.hf}
mkdir -p "$HF_HOME"


# pick a python that has pynvml (cluster module python has it; /usr/bin/python3 does not)
PY=""
for cand in "$(command -v python3)" /cvmfs/soft.computecanada.ca/gentoo/2023/x86-64-v3/usr/bin/python3 /usr/bin/python3; do
  [ -x "$cand" ] || continue
  "$cand" -c "import pynvml" 2>/dev/null && { PY="$cand"; break; }
done
[ -n "$PY" ] || { echo "FATAL: no python with pynvml"; exit 1; }
echo "exporter python: $PY"

echo "node=$(hostname) job=$SLURM_JOB_ID model=$MODEL" | tee "$RUN/meta.txt"
nvidia-smi --query-gpu=index,name,driver_version,power.limit,memory.total --format=csv | tee -a "$RUN/meta.txt"

# 1. energy exporter for the whole run
"$PY" $ROOT/scripts/energy_exporter.py --interval 1 --out "$RUN/energy.jsonl" &
EXPORTER=$!

# 2. one vLLM per GPU
for i in 0 1; do
  PORT=$((8100 + i))
  CUDA_VISIBLE_DEVICES=$i env -u SSL_CERT_FILE -u REQUESTS_CA_BUNDLE -u CURL_CA_BUNDLE -u SSL_CERT_DIR "$APPTAINER" exec --nv \
    --env HF_HOME=$HF_HOME \
    "$ROOT/images/vllm-v0.30.0.sif" \
    vllm serve "$MODEL" --port $PORT --host 127.0.0.1 \
      --gpu-memory-utilization 0.85 --max-model-len 4096 \
      > "$RUN/vllm_$i.log" 2>&1 &
done

# 3. wait for both to answer
for i in 0 1; do
  PORT=$((8100 + i))
  for t in $(seq 1 120); do
    curl -sf "http://127.0.0.1:$PORT/v1/models" >/dev/null && { echo "vllm$i up after ${t}0s"; break; }
    sleep 10
  done
done

# 4. endpoints file for EPP file discovery
cat > "$RUN/endpoints.yaml" <<EOF
endpoints:
  - name: vllm-0
    address: "127.0.0.1"
    port: "8100"
  - name: vllm-1
    address: "127.0.0.1"
    port: "8101"
EOF

sed "s|ENDPOINTS_PATH|$RUN/endpoints.yaml|" $ROOT/config/epp-config.yaml > "$RUN/epp-config.yaml"

# 5. EPP
$ROOT/bin/epp --pool-name energy --config-file "$RUN/epp-config.yaml" \
  --grpc-port 9002 --grpc-health-port 9003 --metrics-port 9090 --secure-serving=false \
  > "$RUN/epp.log" 2>&1 &
EPP=$!
sleep 10

# 6. Envoy
"$APPTAINER" exec "$ROOT/images/envoy.sif" /usr/local/bin/envoy \
  -c $ROOT/config/envoy.yaml --log-level warn > "$RUN/envoy.log" 2>&1 &
ENVOY=$!
sleep 10

# 7. drive traffic through Envoy (port 8080)
echo "=== requests via Envoy ===" | tee "$RUN/requests.txt"
for n in $(seq 1 20); do
  curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" \
    -X POST http://127.0.0.1:8080/v1/completions \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"prompt\":\"Explain GPU power capping in one sentence.\",\"max_tokens\":64}" \
    >> "$RUN/requests.txt"
done
tail -5 "$RUN/requests.txt"

# 8. which endpoint got picked
grep -i "destination\|endpoint" "$RUN/epp.log" | tail -5 > "$RUN/routing.txt" 2>/dev/null

# 9. teardown
kill $ENVOY $EPP $EXPORTER 2>/dev/null
pkill -f "vllm serve" 2>/dev/null
sleep 5

echo "=== energy summary ==="
"$PY" - <<PY | tee "$RUN/summary.txt"
import json
rows=[]
for l in open("$RUN/energy.jsonl"):
    try: r=json.loads(l)
    except Exception: continue
    if r.get("energy_mj") is not None: rows.append(r)
for g in (0,1):
    rs=[r for r in rows if r["gpu"]==g]
    if len(rs)<2: continue
    dt=rs[-1]["ts"]-rs[0]["ts"]; dE=rs[-1]["energy_mj"]-rs[0]["energy_mj"]
    print(f"gpu{g}: {dE/1000:.0f} J over {dt:.0f}s = {dE/1000/dt:.1f} W avg, peak_polled={max(r['power_w'] for r in rs):.1f} W")
PY
echo "results in $RUN"
