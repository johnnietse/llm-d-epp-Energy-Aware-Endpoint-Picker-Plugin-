#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# run-cluster-benchmark.sh — Execute benchmark experiments on a real
# GPU cluster with DCGM power telemetry and vLLM inference.
#
# Experiments:
#   B1: Baseline round-robin (no EPP)
#   E1: Energy-aware EPP enabled
#   E3: Power-cap sweep (100W → max TDP)
#   E4: Load sweep (1 → 50 RPS)
#
# Prerequisites:
#   - Cluster set up via setup-benchmark-cluster.sh
#   - vLLM running and healthy
#   - DCGM exporter running
#   - Python 3.8+ with requests (for workload generation)
#
# Usage:
#   ./benchmarks/scripts/run-cluster-benchmark.sh
#   ./benchmarks/scripts/run-cluster-benchmark.sh --experiment E3
#   ./benchmarks/scripts/run-cluster-benchmark.sh --gpu-node <SSH_HOST>
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TIMESTAMP=$(date +"%Y-%m-%d_%H-%M")
RESULTS_DIR="$PROJECT_ROOT/benchmarks/results/$TIMESTAMP"

# Configuration
EXPERIMENT="all"
NUM_PROMPTS=200
WARMUP_PROMPTS=20
GPU_NODE=""       # SSH host for remote nvidia-smi power-cap commands
VLLM_URL=""       # Auto-detected if empty
PROMETHEUS_URL="" # Auto-detected if empty
SCRAPE_INTERVAL=5 # seconds between metric snapshots

# Colors
GREEN='\033[0;32m'; BLUE='\033[0;34m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()    { echo -e "${GREEN}[BENCH]${NC} $*"; }
header() { echo -e "\n${BLUE}══════════════════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}══════════════════════════════════════════════════${NC}"; }

# ─── Parse Arguments ─────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --experiment|-e)  EXPERIMENT="$2"; shift 2 ;;
        --prompts|-n)     NUM_PROMPTS="$2"; shift 2 ;;
        --gpu-node)       GPU_NODE="$2"; shift 2 ;;
        --vllm-url)       VLLM_URL="$2"; shift 2 ;;
        --prometheus-url) PROMETHEUS_URL="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--experiment B1|E1|E3|E4|all] [--prompts N] [--gpu-node HOST]"
            exit 0 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

# ─── Auto-Detect Endpoints ──────────────────────────────────────────
detect_endpoints() {
    if [[ -z "$VLLM_URL" ]]; then
        local node_ip vllm_port
        node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || hostname -I | awk '{print $1}')
        vllm_port=$(kubectl -n inference get svc vllm-server -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo "8000")
        VLLM_URL="http://${node_ip}:${vllm_port}"
    fi
    if [[ -z "$PROMETHEUS_URL" ]]; then
        local node_ip
        node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || hostname -I | awk '{print $1}')
        PROMETHEUS_URL="http://${node_ip}:30900"
    fi
    log "vLLM endpoint:       $VLLM_URL"
    log "Prometheus endpoint: $PROMETHEUS_URL"
}

# ─── Helper: Set GPU Power Cap ───────────────────────────────────────
set_power_cap() {
    local watts=$1
    log "Setting GPU power cap to ${watts}W..."
    if [[ -n "$GPU_NODE" ]]; then
        ssh "$GPU_NODE" "sudo nvidia-smi -pl $watts" 2>/dev/null
    else
        sudo nvidia-smi -pl "$watts" 2>/dev/null || {
            echo "${YELLOW}[WARN]${NC} Cannot set power cap (need sudo or --gpu-node)"
        }
    fi
    sleep 5  # Let GPU stabilize at new power level
}

# ─── Helper: Get Current GPU Power ───────────────────────────────────
get_gpu_power() {
    if [[ -n "$GPU_NODE" ]]; then
        ssh "$GPU_NODE" "nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits" 2>/dev/null | head -1
    else
        nvidia-smi --query-gpu=power.draw --format=csv,noheader,nounits 2>/dev/null | head -1
    fi
}

get_gpu_max_tdp() {
    if [[ -n "$GPU_NODE" ]]; then
        ssh "$GPU_NODE" "nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits" 2>/dev/null | head -1
    else
        nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits 2>/dev/null | head -1
    fi
}

# ─── Helper: Snapshot Prometheus Metrics ─────────────────────────────
snapshot_prometheus() {
    local output_file=$1
    local queries=(
        "DCGM_FI_DEV_POWER_USAGE"
        "DCGM_FI_DEV_GPU_UTIL"
        "DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION"
    )

    echo "{" > "$output_file"
    echo "  \"timestamp\": \"$(date -Iseconds)\"," >> "$output_file"

    for q in "${queries[@]}"; do
        local result
        result=$(curl -s "${PROMETHEUS_URL}/api/v1/query?query=${q}" 2>/dev/null || echo '{"data":{"result":[]}}')
        echo "  \"${q}\": ${result}," >> "$output_file"
    done

    # EPP metrics
    local epp_metrics
    epp_metrics=$(curl -s "http://$(kubectl -n energy-epp get svc energy-epp -o jsonpath='{.spec.clusterIP}' 2>/dev/null || echo 'localhost'):8080/metrics/energy" 2>/dev/null || echo '{}')
    echo "  \"epp_metrics\": ${epp_metrics}" >> "$output_file"
    echo "}" >> "$output_file"
}

# ─── Helper: Background Metric Collector ─────────────────────────────
start_metric_collector() {
    local output_dir=$1
    local pid_file="$output_dir/.collector_pid"
    mkdir -p "$output_dir/timeseries"

    (
        local idx=0
        while true; do
            local ts
            ts=$(date +%s)
            local power
            power=$(get_gpu_power 2>/dev/null || echo "0")
            echo "${ts},${power}" >> "$output_dir/timeseries/power_watts.csv"
            snapshot_prometheus "$output_dir/timeseries/snapshot_${idx}.json" 2>/dev/null || true
            ((idx++))
            sleep "$SCRAPE_INTERVAL"
        done
    ) &
    echo $! > "$pid_file"
    log "Metric collector started (PID=$(cat "$pid_file"), interval=${SCRAPE_INTERVAL}s)"
}

stop_metric_collector() {
    local output_dir=$1
    local pid_file="$output_dir/.collector_pid"
    if [[ -f "$pid_file" ]]; then
        kill "$(cat "$pid_file")" 2>/dev/null || true
        rm -f "$pid_file"
        log "Metric collector stopped"
    fi
}

# ─── Helper: Send Inference Requests ─────────────────────────────────
send_requests() {
    local num_requests=$1
    local rps=${2:-5}
    local output_file=$3
    local delay
    delay=$(echo "scale=3; 1.0 / $rps" | bc 2>/dev/null || echo "0.2")

    log "Sending $num_requests requests at ${rps} RPS to $VLLM_URL..."

    python3 - "$VLLM_URL" "$num_requests" "$delay" "$output_file" <<'PYSCRIPT'
import sys, json, time, urllib.request, statistics

url = sys.argv[1] + "/v1/chat/completions"
num = int(sys.argv[2])
delay = float(sys.argv[3])
out = sys.argv[4]

prompts = [
    "Explain quantum computing in simple terms.",
    "Write a short poem about the ocean.",
    "What are the benefits of renewable energy?",
    "Describe the process of photosynthesis.",
    "How does a neural network learn?",
    "Summarize the history of the internet.",
    "What is the greenhouse effect?",
    "Explain how batteries work.",
]

results = []
ttfts = []
total_tokens = 0
start_all = time.time()

for i in range(num):
    prompt = prompts[i % len(prompts)]
    payload = json.dumps({
        "model": "default",
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 100,
        "temperature": 0.7,
    }).encode()

    req = urllib.request.Request(url, data=payload,
        headers={"Content-Type": "application/json"})
    try:
        t0 = time.time()
        resp = urllib.request.urlopen(req, timeout=30)
        t1 = time.time()
        data = json.loads(resp.read())
        latency_ms = (t1 - t0) * 1000
        tokens = data.get("usage", {}).get("completion_tokens", 0)
        ttfts.append(latency_ms)
        total_tokens += tokens
        results.append({"latency_ms": latency_ms, "tokens": tokens, "ok": True})
    except Exception as e:
        results.append({"latency_ms": 0, "tokens": 0, "ok": False, "error": str(e)})

    if i < num - 1:
        time.sleep(delay)

    if (i + 1) % 50 == 0:
        print(f"  Progress: {i+1}/{num} requests sent")

elapsed = time.time() - start_all
ok_results = [r for r in results if r["ok"]]

summary = {
    "total_requests": num,
    "successful": len(ok_results),
    "failed": num - len(ok_results),
    "total_tokens": total_tokens,
    "elapsed_seconds": round(elapsed, 2),
    "throughput_rps": round(len(ok_results) / elapsed, 2) if elapsed > 0 else 0,
    "throughput_tps": round(total_tokens / elapsed, 2) if elapsed > 0 else 0,
    "latency_p50_ms": round(statistics.median(ttfts), 2) if ttfts else 0,
    "latency_p95_ms": round(sorted(ttfts)[int(len(ttfts)*0.95)] if ttfts else 0, 2),
    "latency_p99_ms": round(sorted(ttfts)[int(len(ttfts)*0.99)] if ttfts else 0, 2),
    "latency_mean_ms": round(statistics.mean(ttfts), 2) if ttfts else 0,
    "results": results,
}

with open(out, "w") as f:
    json.dump(summary, f, indent=2)

print(f"  Done: {len(ok_results)}/{num} OK, {total_tokens} tokens, "
      f"p50={summary['latency_p50_ms']}ms, p95={summary['latency_p95_ms']}ms")
PYSCRIPT
}

# ─── Experiment B1: Baseline (No EPP) ───────────────────────────────

run_b1() {
    header "B1: Baseline — Round-Robin (No EPP)"
    local dir="$RESULTS_DIR/B1_baseline"
    mkdir -p "$dir"

    # Disable EPP (scale to 0)
    kubectl -n energy-epp scale deployment --all --replicas=0 2>/dev/null || true
    sleep 5

    start_metric_collector "$dir"

    # Warmup
    log "Warmup: $WARMUP_PROMPTS requests..."
    send_requests "$WARMUP_PROMPTS" 2 "$dir/warmup.json"

    # Main run
    send_requests "$NUM_PROMPTS" 5 "$dir/results.json"
    snapshot_prometheus "$dir/final_metrics.json"

    stop_metric_collector "$dir"

    # Re-enable EPP
    kubectl -n energy-epp scale deployment --all --replicas=1 2>/dev/null || true
    log "B1 complete → $dir/"
}

# ─── Experiment E1: Energy-Aware EPP ────────────────────────────────

run_e1() {
    header "E1: Energy-Aware EPP Routing"
    local dir="$RESULTS_DIR/E1_energy_aware"
    mkdir -p "$dir"

    # Ensure EPP is running
    kubectl -n energy-epp scale deployment --all --replicas=1 2>/dev/null || true
    kubectl apply -f "$PROJECT_ROOT/deploy/manifests/energy-epp-config.yaml" 2>/dev/null || true
    sleep 10

    start_metric_collector "$dir"

    log "Warmup: $WARMUP_PROMPTS requests..."
    send_requests "$WARMUP_PROMPTS" 2 "$dir/warmup.json"

    send_requests "$NUM_PROMPTS" 5 "$dir/results.json"
    snapshot_prometheus "$dir/final_metrics.json"

    # Capture EPP scoring decisions
    kubectl -n energy-epp logs deployment/epp-gpu-h100 --tail=200 > "$dir/epp_logs.txt" 2>/dev/null || true

    stop_metric_collector "$dir"
    log "E1 complete → $dir/"
}

# ─── Experiment E3: Power-Cap Sweep ─────────────────────────────────

run_e3() {
    header "E3: Power-Cap Sweep"
    local dir="$RESULTS_DIR/E3_power_sweep"
    mkdir -p "$dir"

    local max_tdp
    max_tdp=$(get_gpu_max_tdp | xargs)
    max_tdp=${max_tdp%.*}  # Remove decimal
    log "GPU max TDP: ${max_tdp}W"

    # Generate power cap steps: 100W increments from 100 to max
    local caps=()
    local cap=100
    while [[ $cap -le $max_tdp ]]; do
        caps+=("$cap")
        cap=$((cap + 50))
    done
    # Always include max
    if [[ "${caps[-1]}" != "$max_tdp" ]]; then
        caps+=("$max_tdp")
    fi

    log "Power caps to test: ${caps[*]}"

    # Summary CSV header
    echo "power_cap_w,actual_power_w,throughput_tps,latency_p50_ms,latency_p95_ms,energy_per_token_mj" \
        > "$dir/sweep_summary.csv"

    for cap_w in "${caps[@]}"; do
        log "── Testing power cap: ${cap_w}W ──"
        set_power_cap "$cap_w"

        local cap_dir="$dir/cap_${cap_w}w"
        mkdir -p "$cap_dir"

        start_metric_collector "$cap_dir"

        # Warmup
        send_requests 10 2 "$cap_dir/warmup.json"

        # Main run
        send_requests "$((NUM_PROMPTS / 2))" 5 "$cap_dir/results.json"

        local actual_power
        actual_power=$(get_gpu_power | xargs)
        snapshot_prometheus "$cap_dir/final_metrics.json"

        stop_metric_collector "$cap_dir"

        # Extract throughput from results
        local tps latency_p50 latency_p95
        tps=$(python3 -c "import json; d=json.load(open('$cap_dir/results.json')); print(d.get('throughput_tps',0))" 2>/dev/null || echo "0")
        latency_p50=$(python3 -c "import json; d=json.load(open('$cap_dir/results.json')); print(d.get('latency_p50_ms',0))" 2>/dev/null || echo "0")
        latency_p95=$(python3 -c "import json; d=json.load(open('$cap_dir/results.json')); print(d.get('latency_p95_ms',0))" 2>/dev/null || echo "0")

        # Energy per token = power (W) / throughput (tok/s) * 1000 (mJ)
        local ept
        ept=$(python3 -c "p=${actual_power:-0}; t=${tps:-0}; print(round(p/t*1000,2) if t>0 else 0)" 2>/dev/null || echo "0")

        echo "${cap_w},${actual_power},${tps},${latency_p50},${latency_p95},${ept}" >> "$dir/sweep_summary.csv"
        log "  Cap=${cap_w}W → Actual=${actual_power}W, TPS=${tps}, EPT=${ept} mJ/tok"
    done

    # Restore max power
    set_power_cap "$max_tdp"
    log "E3 complete → $dir/"
    log "Summary: $dir/sweep_summary.csv"
}

# ─── Experiment E4: Load Sweep ──────────────────────────────────────

run_e4() {
    header "E4: Load Sweep (Throughput vs Energy)"
    local dir="$RESULTS_DIR/E4_load_sweep"
    mkdir -p "$dir"

    local rps_levels=(1 2 5 10 20 50)
    echo "target_rps,actual_rps,throughput_tps,power_w,latency_p50_ms,energy_per_token_mj" \
        > "$dir/load_summary.csv"

    for rps in "${rps_levels[@]}"; do
        log "── Testing load: ${rps} RPS ──"
        local rps_dir="$dir/rps_${rps}"
        mkdir -p "$rps_dir"

        start_metric_collector "$rps_dir"
        send_requests "$((NUM_PROMPTS / 2))" "$rps" "$rps_dir/results.json"

        local power tps latency_p50 ept actual_rps
        power=$(get_gpu_power | xargs)
        tps=$(python3 -c "import json; d=json.load(open('$rps_dir/results.json')); print(d.get('throughput_tps',0))" 2>/dev/null || echo "0")
        actual_rps=$(python3 -c "import json; d=json.load(open('$rps_dir/results.json')); print(d.get('throughput_rps',0))" 2>/dev/null || echo "0")
        latency_p50=$(python3 -c "import json; d=json.load(open('$rps_dir/results.json')); print(d.get('latency_p50_ms',0))" 2>/dev/null || echo "0")
        ept=$(python3 -c "p=${power:-0}; t=${tps:-0}; print(round(p/t*1000,2) if t>0 else 0)" 2>/dev/null || echo "0")

        echo "${rps},${actual_rps},${tps},${power},${latency_p50},${ept}" >> "$dir/load_summary.csv"
        stop_metric_collector "$rps_dir"

        log "  RPS=${rps} → Power=${power}W, TPS=${tps}, EPT=${ept} mJ/tok"
    done

    log "E4 complete → $dir/"
}

# ─── Summary Report ─────────────────────────────────────────────────

generate_report() {
    header "Generating Summary Report"

    cat > "$RESULTS_DIR/README.md" <<REPORT
# Energy-Aware EPP Benchmark Results
**Date:** $TIMESTAMP
**Node:** $(hostname)
**GPU:** $(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)

## Experiments Run
$(ls -d "$RESULTS_DIR"/*/ 2>/dev/null | while read d; do echo "- $(basename "$d")"; done)

## Quick Results
$(if [[ -f "$RESULTS_DIR/E3_power_sweep/sweep_summary.csv" ]]; then
    echo "### E3: Power-Cap Sweep"
    echo '```'
    cat "$RESULTS_DIR/E3_power_sweep/sweep_summary.csv"
    echo '```'
fi)
$(if [[ -f "$RESULTS_DIR/E4_load_sweep/load_summary.csv" ]]; then
    echo "### E4: Load Sweep"
    echo '```'
    cat "$RESULTS_DIR/E4_load_sweep/load_summary.csv"
    echo '```'
fi)
REPORT

    # Run Python analyzer if available
    if command -v python3 &>/dev/null && [[ -f "$SCRIPT_DIR/analyze_results.py" ]]; then
        python3 "$SCRIPT_DIR/analyze_results.py" --output "$RESULTS_DIR" 2>&1 | tee "$RESULTS_DIR/analysis.txt"
    fi

    log "Report: $RESULTS_DIR/README.md"
}

# ─── Main ────────────────────────────────────────────────────────────

main() {
    header "Energy-Aware EPP — Cluster Benchmark Suite"
    log "Timestamp: $TIMESTAMP"
    mkdir -p "$RESULTS_DIR"

    detect_endpoints

    # Check vLLM is reachable
    if ! curl -s "${VLLM_URL}/health" >/dev/null 2>&1; then
        echo "${YELLOW}[WARN]${NC} vLLM not reachable at $VLLM_URL — some experiments may fail"
    fi

    case "$EXPERIMENT" in
        all)  run_b1; run_e1; run_e3; run_e4 ;;
        B1)   run_b1 ;;
        E1)   run_e1 ;;
        E3)   run_e3 ;;
        E4)   run_e4 ;;
        *)    echo "Unknown experiment: $EXPERIMENT"; exit 1 ;;
    esac

    generate_report

    header "BENCHMARK COMPLETE"
    log "Results: $RESULTS_DIR/"
    log "Files:"
    find "$RESULTS_DIR" -type f | head -20
}

main "$@"
