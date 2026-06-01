#!/bin/bash
#SBATCH --job-name=epp-power-sweep
#SBATCH --partition=gpubase_6hrs
#SBATCH --time=04:00:00
#SBATCH --nodes=1
#SBATCH --cpus-per-task=16
#SBATCH --gres=gpu:2
#SBATCH --mem=128G
#SBATCH --output=benchmarks/results/frontenac/sweep_%j.out
#SBATCH --error=benchmarks/results/frontenac/sweep_%j.err
# ─────────────────────────────────────────────────────────────────────
# 03-power-sweep.sbatch — Multi-GPU utilization sweep
#
# Requests 2 A100s on the same DGX node, then runs vLLM at increasing
# load levels on EACH gpu to build a utilization-vs-power curve.
# This emulates "heterogeneous hardware" by varying concurrency per GPU.
#
# Key output: CSV mapping (concurrency → power → throughput → energy/tok)
#
# Submit:
#   sbatch benchmarks/scripts/frontenac/03-power-sweep.sbatch
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

PROJECT_DIR="$HOME/energy-epp"
RESULTS_DIR="$PROJECT_DIR/benchmarks/results/frontenac/$(date +%Y-%m-%d_%H-%M)_sweep"
VLLM_SIF="$HOME/containers/vllm-openai-v0.6.0.sif"
MODEL="facebook/opt-1.3b"

mkdir -p "$RESULTS_DIR"

echo "═══════════════════════════════════════════════════════"
echo "  Multi-GPU Power Sweep — $(hostname)"
echo "  GPUs: $(nvidia-smi --query-gpu=name --format=csv,noheader | wc -l)x $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
echo "  Results: $RESULTS_DIR"
echo "═══════════════════════════════════════════════════════"

module load apptainer/1.3.5
module load cuda/11.6.1
module load python/3.11.5

# ─── Record per-GPU info ─────────────────────────────────────────────
nvidia-smi --query-gpu=index,name,power.max_limit,memory.total \
    --format=csv > "$RESULTS_DIR/gpu_inventory.csv"
echo "GPU inventory:"
cat "$RESULTS_DIR/gpu_inventory.csv"

NUM_GPUS=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)
echo "Detected $NUM_GPUS GPUs"

# ─── Start vLLM on GPU 0 (prefill server) ────────────────────────────
echo ""
echo "Starting vLLM on GPU 0 (port 8000)..."
CUDA_VISIBLE_DEVICES=0 apptainer exec --nv "$VLLM_SIF" \
    python3 -m vllm.entrypoints.openai.api_server \
    --model "$MODEL" --max-model-len 2048 --dtype float16 \
    --gpu-memory-utilization 0.85 --port 8000 \
    &> "$RESULTS_DIR/vllm_gpu0.log" &
PID_GPU0=$!

# Start vLLM on GPU 1 (decode server) if available
PID_GPU1=""
if [[ $NUM_GPUS -ge 2 ]]; then
    echo "Starting vLLM on GPU 1 (port 8001)..."
    CUDA_VISIBLE_DEVICES=1 apptainer exec --nv "$VLLM_SIF" \
        python3 -m vllm.entrypoints.openai.api_server \
        --model "$MODEL" --max-model-len 2048 --dtype float16 \
        --gpu-memory-utilization 0.85 --port 8001 \
        &> "$RESULTS_DIR/vllm_gpu1.log" &
    PID_GPU1=$!
fi

# Wait for servers to start
echo "Waiting for vLLM servers..."
for i in $(seq 1 60); do
    GPU0_OK=$(curl -s http://localhost:8000/health 2>/dev/null && echo "yes" || echo "no")
    GPU1_OK="n/a"
    if [[ -n "$PID_GPU1" ]]; then
        GPU1_OK=$(curl -s http://localhost:8001/health 2>/dev/null && echo "yes" || echo "no")
    fi

    if [[ "$GPU0_OK" == "yes" ]] && [[ "$GPU1_OK" == "yes" || "$GPU1_OK" == "n/a" ]]; then
        echo "  All servers ready after $((i*5))s"
        break
    fi
    sleep 5
done

# ─── Workload generator ─────────────────────────────────────────────
cat > "$RESULTS_DIR/send_requests.py" << 'PYSCRIPT'
import sys, json, time, urllib.request, statistics

port = int(sys.argv[1])
num = int(sys.argv[2])
rps = float(sys.argv[3])
out = sys.argv[4]
max_tok = int(sys.argv[5]) if len(sys.argv) > 5 else 100

url = f"http://localhost:{port}/v1/chat/completions"
prompts = [
    "Explain quantum computing.", "Write a poem about stars.",
    "How do batteries work?", "Describe photosynthesis.",
    "What is machine learning?", "Explain the water cycle.",
]

delay = 1.0 / rps if rps > 0 else 0
latencies = []
total_tokens = 0
t_start = time.time()

for i in range(num):
    payload = json.dumps({
        "model": "facebook/opt-1.3b",
        "messages": [{"role": "user", "content": prompts[i % len(prompts)]}],
        "max_tokens": max_tok, "temperature": 0.7,
    }).encode()
    req = urllib.request.Request(url, data=payload,
        headers={"Content-Type": "application/json"})
    try:
        t0 = time.time()
        resp = urllib.request.urlopen(req, timeout=60)
        lat = (time.time() - t0) * 1000
        data = json.loads(resp.read())
        toks = data.get("usage", {}).get("completion_tokens", 0)
        latencies.append(lat)
        total_tokens += toks
    except Exception as e:
        latencies.append(-1)
    if delay > 0 and i < num - 1:
        time.sleep(delay)

elapsed = time.time() - t_start
ok = [l for l in latencies if l > 0]
summary = {
    "port": port, "rps": rps, "requests": num,
    "ok": len(ok), "tokens": total_tokens,
    "tps": round(total_tokens / elapsed, 2) if elapsed > 0 else 0,
    "p50_ms": round(statistics.median(ok), 2) if ok else 0,
    "p95_ms": round(sorted(ok)[int(len(ok)*0.95)], 2) if ok else 0,
    "mean_ms": round(statistics.mean(ok), 2) if ok else 0,
}
with open(out, "w") as f:
    json.dump(summary, f, indent=2)
print(f"  GPU@:{port} RPS={rps} → TPS={summary['tps']} p50={summary['p50_ms']}ms")
PYSCRIPT

# ─── Start per-GPU power monitors ───────────────────────────────────
for gpu_idx in $(seq 0 $((NUM_GPUS - 1))); do
    echo "timestamp,power_w,gpu_util,mem_util,temp" > "$RESULTS_DIR/power_gpu${gpu_idx}.csv"
    (
        while true; do
            nvidia-smi --id=$gpu_idx \
                --query-gpu=timestamp,power.draw,utilization.gpu,utilization.memory,temperature.gpu \
                --format=csv,noheader,nounits >> "$RESULTS_DIR/power_gpu${gpu_idx}.csv" 2>/dev/null
            sleep 2
        done
    ) &
    eval "MONITOR_PID_GPU${gpu_idx}=$!"
done

# ─── Utilization sweep on GPU 0 ─────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
echo "  GPU 0 — Utilization Sweep (Prefill)"
echo "════════════════════════════════════════"
echo "rps,tps,power_w,gpu_util,p50_ms,p95_ms,energy_per_token_mj" > "$RESULTS_DIR/sweep_gpu0.csv"

for RPS in 0.5 1 2 5 10 20; do
    echo "── GPU 0 @ ${RPS} RPS ──"
    sleep 3

    # Record power snapshot before
    PRE_POWER=$(nvidia-smi --id=0 --query-gpu=power.draw --format=csv,noheader,nounits)

    python3 "$RESULTS_DIR/send_requests.py" 8000 40 "$RPS" "$RESULTS_DIR/gpu0_rps${RPS}.json" 150

    # Record power and util after
    POST_POWER=$(nvidia-smi --id=0 --query-gpu=power.draw --format=csv,noheader,nounits)
    GPU_UTIL=$(nvidia-smi --id=0 --query-gpu=utilization.gpu --format=csv,noheader,nounits)
    AVG_POWER=$(python3 -c "print(round(($PRE_POWER + $POST_POWER) / 2, 1))")

    TPS=$(python3 -c "import json; print(json.load(open('$RESULTS_DIR/gpu0_rps${RPS}.json'))['tps'])")
    P50=$(python3 -c "import json; print(json.load(open('$RESULTS_DIR/gpu0_rps${RPS}.json'))['p50_ms'])")
    P95=$(python3 -c "import json; print(json.load(open('$RESULTS_DIR/gpu0_rps${RPS}.json'))['p95_ms'])")
    EPT=$(python3 -c "p=$AVG_POWER; t=$TPS; print(round(p/t*1000, 2) if t>0 else 0)")

    echo "${RPS},${TPS},${AVG_POWER},${GPU_UTIL},${P50},${P95},${EPT}" >> "$RESULTS_DIR/sweep_gpu0.csv"
    echo "  Power=${AVG_POWER}W Util=${GPU_UTIL}% TPS=${TPS} EPT=${EPT} mJ/tok"

    sleep 5
done

# ─── Utilization sweep on GPU 1 ─────────────────────────────────────
if [[ -n "$PID_GPU1" ]]; then
    echo ""
    echo "════════════════════════════════════════"
    echo "  GPU 1 — Utilization Sweep (Decode)"
    echo "════════════════════════════════════════"
    echo "rps,tps,power_w,gpu_util,p50_ms,p95_ms,energy_per_token_mj" > "$RESULTS_DIR/sweep_gpu1.csv"

    for RPS in 0.5 1 2 5 10 20; do
        echo "── GPU 1 @ ${RPS} RPS ──"
        sleep 3

        PRE_POWER=$(nvidia-smi --id=1 --query-gpu=power.draw --format=csv,noheader,nounits)
        python3 "$RESULTS_DIR/send_requests.py" 8001 40 "$RPS" "$RESULTS_DIR/gpu1_rps${RPS}.json" 30

        POST_POWER=$(nvidia-smi --id=1 --query-gpu=power.draw --format=csv,noheader,nounits)
        GPU_UTIL=$(nvidia-smi --id=1 --query-gpu=utilization.gpu --format=csv,noheader,nounits)
        AVG_POWER=$(python3 -c "print(round(($PRE_POWER + $POST_POWER) / 2, 1))")

        TPS=$(python3 -c "import json; print(json.load(open('$RESULTS_DIR/gpu1_rps${RPS}.json'))['tps'])")
        P50=$(python3 -c "import json; print(json.load(open('$RESULTS_DIR/gpu1_rps${RPS}.json'))['p50_ms'])")
        P95=$(python3 -c "import json; print(json.load(open('$RESULTS_DIR/gpu1_rps${RPS}.json'))['p95_ms'])")
        EPT=$(python3 -c "p=$AVG_POWER; t=$TPS; print(round(p/t*1000, 2) if t>0 else 0)")

        echo "${RPS},${TPS},${AVG_POWER},${GPU_UTIL},${P50},${P95},${EPT}" >> "$RESULTS_DIR/sweep_gpu1.csv"
        echo "  Power=${AVG_POWER}W Util=${GPU_UTIL}% TPS=${TPS} EPT=${EPT} mJ/tok"

        sleep 5
    done
fi

# ─── Cleanup ─────────────────────────────────────────────────────────
echo ""
echo "Stopping monitors and servers..."
for gpu_idx in $(seq 0 $((NUM_GPUS - 1))); do
    eval "kill \$MONITOR_PID_GPU${gpu_idx} 2>/dev/null || true"
done
kill $PID_GPU0 2>/dev/null || true
[[ -n "$PID_GPU1" ]] && kill $PID_GPU1 2>/dev/null || true
wait 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  SWEEP COMPLETE"
echo ""
echo "  GPU 0 sweep: $RESULTS_DIR/sweep_gpu0.csv"
[[ -n "$PID_GPU1" ]] && echo "  GPU 1 sweep: $RESULTS_DIR/sweep_gpu1.csv"
echo "  Power logs:  $RESULTS_DIR/power_gpu*.csv"
echo ""
echo "  Next: Generate figures:"
echo "    python3 benchmarks/scripts/frontenac/05-analyze-frontenac.py $RESULTS_DIR"
echo "═══════════════════════════════════════════════════════"
