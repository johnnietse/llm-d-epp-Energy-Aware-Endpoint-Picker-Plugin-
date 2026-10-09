#!/bin/bash
#SBATCH --job-name=router-overhead
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --gres=gpu:rtx6000:1
#SBATCH --cpus-per-task=8
#SBATCH --mem=48G
#SBATCH --time=00:55:00
#SBATCH --output=%x-%j-%N.out
#
# Does Prometheus-style metrics polling, or the router path itself, add
# meaningful latency? Measured, one vLLM server, three arms at the same
# offered load, using vLLM's own benchmark client (`vllm bench serve`) so no
# load generator of ours is involved:
#
#   A  direct      client -> vLLM                         (no router)
#   B  scrape-on   client -> Envoy -> EPP -> vLLM         (EPP polls vLLM /metrics every 50 ms: the default)
#   C  scrape-off  client -> Envoy -> EPP -> vLLM         (dataLayer.injectDefaults: false: no polling at all)
#
# B and C run an identical scheduler (active-request-scorer, which reads the
# EPP's own in-flight count, and max-score-picker); the only difference is
# whether the poller exists, confirmed locally as pollers=1 vs pollers=0.
# So B - C is the cost of polling, and C - A is the cost of the router path.
#
# Order A B C C B A per load level, so slow drift cannot masquerade as an arm
# effect. Each arm's vLLM access log delta proves whether polling happened.
#
# The Envoy config is EXTRACTED from the pinned upstream docs (llm-d-router
# v0.11.0, docs/discovery.md, "### 4. Envoy config") at run time, ports
# substituted, rather than retyped by hand.
set -uo pipefail

module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"

ROOT="$HOME/energy-epp"
VLLM_IMG="$ROOT/images/vllm-v0.30.0.sif"
ENVOY_IMG="$ROOT/images/envoy.sif"
EPP_BIN="${EPP_BIN:-$ROOT/bin/epp-energy-v0.11.0}"
ROUTER_SRC="$ROOT/llm-d-router"
MODEL="${MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"
RATES="${RATES:-10 20}"
NPROMPTS_PER_S="${NPROMPTS_PER_S:-60}"     # prompts = rate * this, i.e. ~60 s per run
SEED="${SEED:-11}"
RUN="$ROOT/results/router-overhead-$SLURM_JOB_ID"
mkdir -p "$RUN"
export HF_HOME="${HF_HOME:-$ROOT/.hf}"

BASE=$(( 30000 + (SLURM_JOB_ID % 2000) * 10 ))
VLLM_PORT=$BASE
EPP_GRPC=$((BASE + 2)); EPP_HEALTH=$((BASE + 3)); EPP_METRICS=$((BASE + 4))
ENVOY_PORT=$((BASE + 5)); ENVOY_ADMIN=$((BASE + 6))

PIDS=(); EPP_PID=""; ENVOY_PID=""
cleanup() {
  for p in "${PIDS[@]}" $EPP_PID $ENVOY_PID; do kill "$p" 2>/dev/null; done
  sleep 3
  for p in "${PIDS[@]}" $EPP_PID $ENVOY_PID; do kill -9 "$p" 2>/dev/null; done
  wait 2>/dev/null
}
trap cleanup EXIT
echo "node=$(hostname) job=$SLURM_JOB_ID base=$BASE gpus=${CUDA_VISIBLE_DEVICES:-unset} rates='$RATES'"

# ------------------------------------------------- provenance and pre-checks
[ -x "$EPP_BIN" ] || { echo "FATAL: no EPP binary"; exit 1; }
echo "epp sha256=$(sha256sum "$EPP_BIN" | cut -d' ' -f1)"
RTAG="$(git -C "$ROUTER_SRC" describe --tags --exact-match 2>/dev/null)"
echo "router source: $(git -C "$ROUTER_SRC" rev-parse --short HEAD) tag=${RTAG:-NONE}"
[ "$RTAG" = "v0.11.0" ] || { echo "FATAL: router clone is not at v0.11.0; configs would describe another version"; exit 1; }
"$APPTAINER" exec "$ENVOY_IMG" envoy --version > "$RUN/envoy-version.txt" 2>&1
echo "envoy: $(grep -m1 -oE '/[0-9]+\.[0-9]+\.[0-9]+/' "$RUN/envoy-version.txt" | tr -d /)"

# ------------------------------------------- Envoy config from upstream docs
awk '/^### 4\. Envoy config/{f=1} f&&/^```yaml/{y=1;next} y&&/^```/{exit} y' \
    "$ROUTER_SRC/docs/discovery.md" > "$RUN/envoy.upstream.yaml"
[ -s "$RUN/envoy.upstream.yaml" ] || { echo "FATAL: could not extract the Envoy config from upstream docs"; exit 1; }
sed -e "s/address: 0\.0\.0\.0/address: 127.0.0.1/" \
    -e "s/port_value: 19000/port_value: $ENVOY_ADMIN/" \
    -e "s/port_value: 8080/port_value: $ENVOY_PORT/" \
    -e "s/authority: localhost:9002/authority: 127.0.0.1:$EPP_GRPC/" \
    -e "s/port_value: 9002/port_value: $EPP_GRPC/" \
    "$RUN/envoy.upstream.yaml" > "$RUN/envoy.yaml"
if grep -qE '0\.0\.0\.0|: 8080|: 9002|:9002|: 19000' "$RUN/envoy.yaml" \
   || ! grep -q "port_value: $ENVOY_PORT" "$RUN/envoy.yaml" \
   || ! grep -q "port_value: $EPP_GRPC" "$RUN/envoy.yaml"; then
  echo "FATAL: port substitution into the upstream Envoy config did not fully apply"
  diff "$RUN/envoy.upstream.yaml" "$RUN/envoy.yaml"; exit 1
fi
echo "envoy.yaml: upstream v0.11.0 docs block, $(wc -l < "$RUN/envoy.yaml") lines, only ports and bind address changed:"
diff "$RUN/envoy.upstream.yaml" "$RUN/envoy.yaml" | grep '^[<>]' | sed 's/^/    /'

# ------------------------------------------------------- stage model, 1 vLLM
STAGE_DIR="/tmp/hfstage-$SLURM_JOB_ID"
MDN="models--$(printf '%s' "$MODEL" | sed 's#/#--#g')"
mkdir -p "$STAGE_DIR/hub/$MDN" || { echo "FATAL: mkdir $STAGE_DIR"; exit 1; }
for part in refs snapshots; do
  [ -e "$HF_HOME/hub/$MDN/$part" ] || continue
  cp -rL "$HF_HOME/hub/$MDN/$part" "$STAGE_DIR/hub/$MDN/" 2>/dev/null || { echo "FATAL: staging"; exit 1; }
done
export HF_HOME="$STAGE_DIR" HF_HUB_OFFLINE=1
echo "staged $(du -sm "$STAGE_DIR" | cut -f1) MiB"

env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$VLLM_IMG" \
  vllm serve "$MODEL" --served-model-name served --host 127.0.0.1 --port "$VLLM_PORT" \
    --gpu-memory-utilization 0.85 --max-model-len 2048 \
    --max-num-seqs 256 --max-num-batched-tokens 2048 > "$RUN/vllm.log" 2>&1 &
PIDS+=($!)
deadline=$(( $(date +%s) + 900 ))
until curl -fsS --max-time 3 "http://127.0.0.1:$VLLM_PORT/health" >/dev/null 2>&1; do
  [ "$(date +%s)" -ge "$deadline" ] && { echo "FATAL: vLLM not ready"; tail -5 "$RUN/vllm.log"; exit 1; }
  sleep 5
done
echo "vLLM healthy"

# ------------------------------------------------ helpers
metrics_gets() { local n; n="$(grep -c 'GET /metrics' "$RUN/vllm.log" 2>/dev/null)"; echo "${n:-0}"; }

write_epp_cfg() {  # $1 = on|off
  {
    echo "plugins:"
    echo "  - name: file-disc"
    echo "    type: file-discovery"
    echo "    parameters:"
    echo "      path: $RUN/endpoints.yaml"
    echo "      watchFile: false"
    echo "  - name: active"
    echo "    type: active-request-scorer"
    echo "  - name: picker"
    echo "    type: max-score-picker"
    echo "  - name: single-profile"
    echo "    type: single-profile-handler"
    echo "schedulingProfiles:"
    echo "  - name: default"
    echo "    plugins:"
    echo "      - pluginRef: active"
    echo "      - pluginRef: picker"
    echo "dataLayer:"
    [ "$1" = off ] && echo "  injectDefaults: false"
    echo "  discovery:"
    echo "    endpoints:"
    echo "      pluginRef: file-disc"
  } > "$RUN/epp-$1.yaml"
}
printf 'endpoints:\n  - name: vllm-0\n    address: "127.0.0.1"\n    port: "%s"\n' "$VLLM_PORT" > "$RUN/endpoints.yaml"
write_epp_cfg on; write_epp_cfg off

start_router() {  # $1 = on|off
  "$EPP_BIN" --pool-name epp --config-file "$RUN/epp-$1.yaml" \
    --secure-serving=false --metrics-endpoint-auth=false --tracing=false \
    --grpc-port "$EPP_GRPC" --grpc-health-port "$EPP_HEALTH" --metrics-port "$EPP_METRICS" \
    > "$RUN/epp-$1-$2.log" 2>&1 &
  EPP_PID=$!
  "$APPTAINER" exec "$ENVOY_IMG" envoy -c "$RUN/envoy.yaml" --disable-hot-restart --log-level warn \
    > "$RUN/envoy-$1-$2.log" 2>&1 &
  ENVOY_PID=$!
  local d=$(( $(date +%s) + 90 ))
  until [ "$(curl -s --max-time 2 "http://127.0.0.1:$ENVOY_ADMIN/ready")" = "LIVE" ] \
        && curl -s --max-time 2 "http://127.0.0.1:$EPP_METRICS/metrics" >/dev/null; do
    [ "$(date +%s)" -ge "$d" ] && { echo "FATAL: router ($1) not ready"; tail -5 "$RUN/epp-$1-$2.log"; exit 1; }
    sleep 1
  done
  grep -oE '"pollers":[0-9]+' "$RUN/epp-$1-$2.log" | head -1 | sed "s/^/    EPP $1: /"
  sleep 3   # let the poller, if any, settle into its steady 50 ms cadence
}
stop_router() {
  curl -s --max-time 3 "http://127.0.0.1:$EPP_METRICS/metrics" > "$RUN/epp-metrics-$1.txt" 2>/dev/null
  kill $EPP_PID $ENVOY_PID 2>/dev/null; sleep 2; kill -9 $EPP_PID $ENVOY_PID 2>/dev/null
  wait $EPP_PID $ENVOY_PID 2>/dev/null; EPP_PID=""; ENVOY_PID=""
  sleep 2
}

bench() {  # $1 = port  $2 = rate  $3 = result name
  local n=$(( $2 * NPROMPTS_PER_S ))
  env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$VLLM_IMG" vllm bench serve \
    --backend openai --base-url "http://127.0.0.1:$1" --endpoint /v1/completions \
    --model "$MODEL" --served-model-name served \
    --dataset-name random --random-input-len 256 --random-output-len 128 \
    --random-range-ratio 0 --ignore-eos \
    --num-prompts "$n" --request-rate "$2" --seed "$SEED" \
    --percentile-metrics ttft,tpot,itl,e2el --metric-percentiles 50,90,99 \
    --save-result --result-dir "$RUN" --result-filename "$3.json" \
    > "$RUN/$3.bench.log" 2>&1 || { echo "FATAL: bench $3 failed"; tail -15 "$RUN/$3.bench.log"; exit 1; }
}

# ------------------------------------------------------- /metrics endpoint cost
# What one poll costs vLLM to answer, idle. The EPP does this 20 times a second
# per endpoint in arm B.
python3 - "$VLLM_PORT" > "$RUN/metrics-endpoint-cost.txt" <<'PY'
import sys, time, urllib.request
port = sys.argv[1]; url = "http://127.0.0.1:%s/metrics" % port
ts = []; size = 0
for _ in range(300):
    t = time.perf_counter(); body = urllib.request.urlopen(url, timeout=5).read(); ts.append(time.perf_counter() - t); size = len(body)
ts.sort()
q = lambda p: ts[min(len(ts) - 1, int(p * len(ts)))] * 1000
print("metrics_endpoint_idle n=%d bytes=%d p50_ms=%.2f p90_ms=%.2f p99_ms=%.2f max_ms=%.2f" % (len(ts), size, q(.5), q(.9), q(.99), ts[-1] * 1000))
PY
cat "$RUN/metrics-endpoint-cost.txt"

# ------------------------------------------------------------------ warm-up
echo "warm-up (discarded)"
NPROMPTS_PER_S_SAVED=$NPROMPTS_PER_S; NPROMPTS_PER_S=10
bench "$VLLM_PORT" 5 warmup
NPROMPTS_PER_S=$NPROMPTS_PER_S_SAVED

# ------------------------------------------------------------------ the arms
: > "$RUN/runs.tsv"
for rate in $RATES; do
  rep=0
  for arm in A B C C B A; do
    rep=$((rep + 1))
    name="r${rate}-${rep}-${arm}"
    g0="$(metrics_gets)"
    case "$arm" in
      A) bench "$VLLM_PORT" "$rate" "$name" ;;
      B) start_router on "$name";  bench "$ENVOY_PORT" "$rate" "$name"; stop_router "$name" ;;
      C) start_router off "$name"; bench "$ENVOY_PORT" "$rate" "$name"; stop_router "$name" ;;
    esac
    g1="$(metrics_gets)"
    printf '%s\t%s\t%s\t%s\n' "$rate" "$arm" "$name" "$((g1 - g0))" >> "$RUN/runs.tsv"
    echo "  $name done, vLLM served $((g1 - g0)) GET /metrics during it"
  done
done

# ------------------------------------------------------------------ summary
python3 - "$RUN" <<'PY' | tee "$RUN/summary.txt"
import json, os, re, sys
run = sys.argv[1]
rows = [l.rstrip("\n").split("\t") for l in open(os.path.join(run, "runs.tsv"))]
keys = ["p50_ttft_ms", "p99_ttft_ms", "p50_itl_ms", "p99_itl_ms", "p50_e2el_ms", "p99_e2el_ms"]
def epp_mean(name, metric):
    p = os.path.join(run, "epp-metrics-%s.txt" % name)
    if not os.path.exists(p): return None
    s = c = 0.0
    for line in open(p):
        if metric in line and not line.startswith("#"):
            if re.search(r"_sum(\{| )", line): s += float(line.split()[-1])
            elif re.search(r"_count(\{| )", line): c += float(line.split()[-1])
    return (s / c * 1000) if c else None
print("%-14s %-4s %8s %6s " % ("run", "arm", "done", "polls") + " ".join("%12s" % k for k in keys) + " %14s" % "epp_proc_ms")
agg = {}
for rate, arm, name, polls in rows:
    d = json.load(open(os.path.join(run, name + ".json")))
    vals = [d.get(k) for k in keys]
    ep = epp_mean(name, "request_processing_duration_seconds")
    print("%-14s %-4s %8s %6s " % (name, arm, "%d/%d" % (d.get("completed", 0), d.get("num_prompts", 0)), polls)
          + " ".join("%12.2f" % v if v is not None else "%12s" % "-" for v in vals)
          + " %14s" % ("%.3f" % ep if ep is not None else "-"))
    agg.setdefault((rate, arm), []).append(vals)
print()
print("MEAN OF REPS")
for (rate, arm), vs in sorted(agg.items()):
    m = [sum(v[i] for v in vs if v[i] is not None) / len(vs) for i in range(len(keys))]
    print("rate %-4s arm %s  " % (rate, arm) + "  ".join("%s=%.2f" % (k, x) for k, x in zip(keys, m)))
PY

echo "results in $RUN"
exit 0
