#!/bin/bash
#SBATCH --job-name=epp-gpu-profile
#SBATCH --partition=gpubase_6hrs
#SBATCH --time=02:00:00
#SBATCH --nodes=1
#SBATCH --cpus-per-task=8
#SBATCH --gres=gpu:1
#SBATCH --mem=64G
#SBATCH --output=benchmarks/results/frontenac/profile_%j.out
#SBATCH --error=benchmarks/results/frontenac/profile_%j.err
# ─────────────────────────────────────────────────────────────────────
# 02-profile-gpu.sbatch — Measure real A100 power/latency/throughput
#
# This SLURM job:
#   1. Starts vLLM model server in background (via Apptainer)
#   2. Polls nvidia-smi for power draw every 2 seconds
#   3. Sends inference requests at different rates
#   4. Records power, TTFT, TPOT, tokens/sec
#   5. Saves CSV results for EPP scorer validation
#
# Submit:
#   sbatch benchmarks/scripts/frontenac/02-profile-gpu.sbatch
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────
PROJECT_DIR="$HOME/energy-epp"
RESULTS_DIR="$PROJECT_DIR/benchmarks/results/frontenac/$(date +%Y-%m-%d_%H-%M)_profile"
VLLM_SIF="$HOME/containers/vllm-openai-v0.6.0.sif"
MODEL="facebook/opt-1.3b"  # Small model, fits on single A100
# For gated models, set: export HUGGING_FACE_HUB_TOKEN="hf_..."
VLLM_PORT=8000

mkdir -p "$RESULTS_DIR"

echo "═══════════════════════════════════════════════════════"
echo "  GPU Power Profiling — $(hostname)"
echo "  GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
echo "  Results: $RESULTS_DIR"
echo "═══════════════════════════════════════════════════════"

# ─── Load modules ───────────────────────────────────────────────────
module load apptainer/1.3.5
module load cuda/11.6.1
module load python/3.11.5

# ─── Record GPU baseline (idle power) ───────────────────────────────
echo "[1/5] Recording GPU idle power..."
echo "timestamp,power_w,gpu_util,mem_util,temperature" > "$RESULTS_DIR/idle_power.csv"
for i in $(seq 1 10); do
    nvidia-smi --query-gpu=timestamp,power.draw,utilization.gpu,utilization.memory,temperature.gpu \
        --format=csv,noheader,nounits >> "$RESULTS_DIR/idle_power.csv"
    sleep 2
done
IDLE_POWER=$(awk -F',' '{sum+=$2; n++} END{printf "%.1f", sum/n}' "$RESULTS_DIR/idle_power.csv")
echo "  Idle power: ${IDLE_POWER}W"

# ─── Start vLLM server ──────────────────────────────────────────────
echo "[2/5] Starting vLLM model server (model: $MODEL)..."
apptainer exec --nv "$VLLM_SIF" \
    python3 -m vllm.entrypoints.openai.api_server \
    --model "$MODEL" \
    --max-model-len 2048 \
    --dtype float16 \
    --gpu-memory-utilization 0.85 \
    --port "$VLLM_PORT" \
    &> "$RESULTS_DIR/vllm_server.log" &
VLLM_PID=$!

# Wait for vLLM to be ready
echo "  Waiting for vLLM to load model (up to 5 minutes)..."
for i in $(seq 1 60); do
    if curl -s "http://localhost:${VLLM_PORT}/health" > /dev/null 2>&1; then
        echo "  vLLM ready after ${i}0 seconds"
        break
    fi
    if ! kill -0 $VLLM_PID 2>/dev/null; then
        echo "  ERROR: vLLM process died. Check $RESULTS_DIR/vllm_server.log"
        exit 1
    fi
    sleep 5
done

# Verify vLLM is running
if ! curl -s "http://localhost:${VLLM_PORT}/health" > /dev/null 2>&1; then
    echo "  ERROR: vLLM failed to start"
    cat "$RESULTS_DIR/vllm_server.log"
    exit 1
fi

# ─── Start power monitor (background) ───────────────────────────────
echo "[3/5] Starting power monitor..."
echo "timestamp,power_w,gpu_util,mem_util,temperature,fan_speed" > "$RESULTS_DIR/power_timeseries.csv"
(
    while true; do
        nvidia-smi --query-gpu=timestamp,power.draw,utilization.gpu,utilization.memory,temperature.gpu,fan.speed \
            --format=csv,noheader,nounits >> "$RESULTS_DIR/power_timeseries.csv" 2>/dev/null
        sleep 2
    done
) &
MONITOR_PID=$!

# ─── Run workloads at different request rates ────────────────────────
echo "[4/5] Running inference workloads..."

# Workload generator script
cat > "$RESULTS_DIR/workload.py" << 'WORKLOAD_PY'
#!/usr/bin/env python3
"""Send inference requests to vLLM and measure latency."""
import sys, json, time, urllib.request, statistics, os

url = f"http://localhost:{os.environ.get('VLLM_PORT', '8000')}/v1/chat/completions"
num_requests = int(sys.argv[1])
target_rps = float(sys.argv[2])
output_file = sys.argv[3]
max_tokens = int(sys.argv[4]) if len(sys.argv) > 4 else 100

prompts = [
    "Explain quantum computing in simple terms.",
    "Write a short poem about the ocean.",
    "What are the benefits of renewable energy?",
    "How does a neural network learn?",
    "Summarize the history of the internet.",
    "What is the greenhouse effect?",
    "Explain how batteries work.",
    "Describe the water cycle.",
]

delay = 1.0 / target_rps if target_rps > 0 else 0
results = []
ttfts = []
total_tokens = 0
start_all = time.time()

for i in range(num_requests):
    prompt = prompts[i % len(prompts)]
    payload = json.dumps({
        "model": os.environ.get("MODEL", "facebook/opt-1.3b"),
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.7,
    }).encode()

    req = urllib.request.Request(url, data=payload,
        headers={"Content-Type": "application/json"})
    try:
        t0 = time.time()
        resp = urllib.request.urlopen(req, timeout=60)
        t1 = time.time()
        data = json.loads(resp.read())
        latency_ms = (t1 - t0) * 1000
        tokens = data.get("usage", {}).get("completion_tokens", 0)
        ttfts.append(latency_ms)
        total_tokens += tokens
        results.append({"latency_ms": round(latency_ms, 2), "tokens": tokens, "ok": True})
    except Exception as e:
        results.append({"latency_ms": 0, "tokens": 0, "ok": False, "error": str(e)})

    if delay > 0 and i < num_requests - 1:
        time.sleep(delay)

elapsed = time.time() - start_all
ok_latencies = [r["latency_ms"] for r in results if r["ok"]]

summary = {
    "target_rps": target_rps,
    "total_requests": num_requests,
    "successful": len(ok_latencies),
    "failed": num_requests - len(ok_latencies),
    "total_tokens": total_tokens,
    "elapsed_seconds": round(elapsed, 2),
    "actual_rps": round(len(ok_latencies) / elapsed, 2) if elapsed > 0 else 0,
    "tokens_per_sec": round(total_tokens / elapsed, 2) if elapsed > 0 else 0,
    "latency_p50_ms": round(statistics.median(ok_latencies), 2) if ok_latencies else 0,
    "latency_p95_ms": round(sorted(ok_latencies)[int(len(ok_latencies)*0.95)], 2) if ok_latencies else 0,
    "latency_p99_ms": round(sorted(ok_latencies)[int(len(ok_latencies)*0.99)], 2) if ok_latencies else 0,
    "latency_mean_ms": round(statistics.mean(ok_latencies), 2) if ok_latencies else 0,
    "max_tokens_per_request": max_tokens,
}

with open(output_file, "w") as f:
    json.dump(summary, f, indent=2)

print(f"  RPS={target_rps}: {len(ok_latencies)}/{num_requests} OK, "
      f"TPS={summary['tokens_per_sec']}, p50={summary['latency_p50_ms']}ms")
WORKLOAD_PY

# Run at different rates to build a power-vs-load curve
export VLLM_PORT MODEL

echo ""
echo "── Warmup (10 requests at 1 RPS) ──"
python3 "$RESULTS_DIR/workload.py" 10 1 "$RESULTS_DIR/warmup.json"

for RPS in 1 2 5 10 20; do
    echo ""
    echo "── Load test: ${RPS} RPS (50 requests) ──"
    MARKER_TS=$(date +%s)
    echo "load_marker,$MARKER_TS,$RPS" >> "$RESULTS_DIR/load_markers.csv"

    python3 "$RESULTS_DIR/workload.py" 50 "$RPS" "$RESULTS_DIR/load_rps_${RPS}.json"

    # Snapshot current power
    nvidia-smi --query-gpu=power.draw,utilization.gpu,memory.used,memory.total \
        --format=csv,noheader,nounits > "$RESULTS_DIR/snapshot_rps_${RPS}.txt"

    sleep 5  # Let GPU stabilize between runs
done

# ─── Prefill vs Decode profiling ────────────────────────────────────
echo ""
echo "── Prefill profile (short prompts, many tokens) ──"
python3 "$RESULTS_DIR/workload.py" 30 5 "$RESULTS_DIR/prefill_profile.json" 200

echo ""
echo "── Decode profile (long prompts, few tokens) ──"
python3 "$RESULTS_DIR/workload.py" 30 5 "$RESULTS_DIR/decode_profile.json" 20

# ─── Stop power monitor ─────────────────────────────────────────────
kill $MONITOR_PID 2>/dev/null || true

# ─── Record GPU load power stats ────────────────────────────────────
echo ""
echo "[5/5] Generating summary..."
LOAD_POWER=$(awk -F',' 'NR>1 && $3+0>10 {sum+=$2; n++} END{printf "%.1f", n>0?sum/n:0}' "$RESULTS_DIR/power_timeseries.csv")
MAX_POWER=$(awk -F',' 'NR>1 {if($2+0>max) max=$2+0} END{printf "%.1f", max}' "$RESULTS_DIR/power_timeseries.csv")
SAMPLES=$(wc -l < "$RESULTS_DIR/power_timeseries.csv")

cat > "$RESULTS_DIR/gpu_profile_summary.json" << SUMMARY
{
  "hostname": "$(hostname)",
  "gpu": "$(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)",
  "gpu_memory_gb": $(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | awk '{printf "%.0f", $1/1024}'),
  "tdp_watts": $(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits | head -1),
  "idle_power_watts": $IDLE_POWER,
  "avg_load_power_watts": $LOAD_POWER,
  "max_power_watts": $MAX_POWER,
  "power_samples": $SAMPLES,
  "timestamp": "$(date -Iseconds)"
}
SUMMARY

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  PROFILING COMPLETE"
echo ""
echo "  GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
echo "  Idle power:  ${IDLE_POWER}W"
echo "  Load power:  ${LOAD_POWER}W (avg when GPU util >10%)"
echo "  Max power:   ${MAX_POWER}W"
echo "  Samples:     ${SAMPLES}"
echo ""
echo "  Results: $RESULTS_DIR/"
echo ""
echo "  Next: Run EPP scoring with real data:"
echo "    bash benchmarks/scripts/frontenac/04-run-epp-scoring.sh $RESULTS_DIR"
echo "═══════════════════════════════════════════════════════"

# ─── Cleanup ─────────────────────────────────────────────────────────
kill $VLLM_PID 2>/dev/null || true
wait $VLLM_PID 2>/dev/null || true
