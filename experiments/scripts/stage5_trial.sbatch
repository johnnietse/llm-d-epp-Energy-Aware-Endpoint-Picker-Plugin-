#!/bin/bash
#SBATCH --job-name=stage5-trial
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --time=02:00:00
#SBATCH --output=%x-%j.out
#
# ONE Stage 5 trial (PREREGISTRATION-STAGE5.md, amendment section 15, and the
# materials addendum). Every arm is routed by the llm-d-router EPP behind
# Envoy; the load generator only offers load (policy_harness.py router mode).
#
#   FLEET=mixed : heterogeneous job, A100 node + RTX 6000 node, 4 + 4 GPUs
#                 (B9: frnt154 + frnt149, pinned by the submitter)
#   FLEET=homog : one node, 8 RTX 6000 (frnt155, pinned by the submitter)
#
# Per trial, per load level (section 4):
#   1. a discarded warm-up run (round_robin through the router, WARMUP_S),
#      because job 12321497 showed a first-at-new-rate transient;
#   2. every arm once, in a random permutation seeded by the trial seed and
#      the level, so slow drift cannot favour an arm that always runs first;
#   3. each arm gets a freshly started EPP and Envoy (no state carried over).
# Each cell: 60 s of Poisson arrivals at the level, prompts and arrivals from
# the trial seed (identical across arms), --energy-window traffic (M4),
# energy from per-node samplers over the SERVING GPUs only (M6).
# A cell whose wall clock stepped (|clock_step_s| > 0.1 s) is re-run with the
# same seed, at most 3 tries; then the job fails as an infrastructure failure
# and is resubmitted with the same seed (M5, section 7).
#
# Output: $ROOT/results/stage5-<fleet>-s<seed>-<job>/policies-rate<r>.json,
# one per level, in the format stage2_analyse.load reads, every arm's record
# carrying trial_seed, arm_order and the permutation.
#
# Required env: FLEET, SEED, EPP_SHA. Optional: ARMS, RATES, DURATION,
# WARMUP_S, WORKERS, CLOCK_STEP_MAX, MAX_CELL_TRIES.
set -uo pipefail

module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null || true
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"

ROOT="$HOME/energy-epp"
IMG="$ROOT/images/vllm-v0.30.0.sif"
ENVOY_IMG="$ROOT/images/envoy.sif"
EPP_BIN="$ROOT/bin/epp-energy-v0.11.0"
: "${FLEET:?FLEET=mixed|homog}" "${SEED:?SEED=trial seed}" "${EPP_SHA:?EPP_SHA=local build hash}"
MODEL="${MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"
DURATION="${DURATION:-60}"
WARMUP_S="${WARMUP_S:-30}"
WORKERS="${WORKERS:-6}"
SLO=2.0
HEADROOM=0
MAX_INFLIGHT=256
CLOCK_STEP_MAX="${CLOCK_STEP_MAX:-0.1}"
MAX_CELL_TRIES="${MAX_CELL_TRIES:-3}"
SAMPLE_INTERVAL=0.25
export MAX_NUM_SEQS=256 MAX_BATCHED=2048
# The registered arms (section 4). llmd_latency_least joins only if B7's
# feasibility check passes and the materials addendum adds it.
ARMS="${ARMS:-energy_consolidate energy_greedy slo_packing round_robin random stock_llmd}"
# RATES may use ':' between levels: sbatch --export splits on commas.
RATES="${RATES:-}"; RATES="${RATES//:/,}"
case "$FLEET" in
  mixed) RATES="${RATES:-200,300,400,500,600}"; EXPECT_TYPES=2 ;;
  homog) RATES="${RATES:-100,150,200,250,300}"; EXPECT_TYPES=1 ;;
  *) echo "FATAL: FLEET must be mixed or homog"; exit 1 ;;
esac
# RUN_TAG=stage5dry marks a materials dry run (a seed outside 501-525 and
# 601-625, shortened cells); its records can never be mistaken for a trial's.
RUN_TAG="${RUN_TAG:-stage5}"
# Registered seeds: 501-525 / 601-625, replacements 526-531 / 626-631
# (section 15, B10: caps of 6 per fleet).
case "$SEED" in *[!0-9]*|"") echo "FATAL: SEED must be an integer"; exit 1 ;; esac
TRIAL_SEED=0
{ [ "$SEED" -ge 501 ] && [ "$SEED" -le 531 ]; } || { [ "$SEED" -ge 601 ] && [ "$SEED" -le 631 ]; } && TRIAL_SEED=1
case "$RUN_TAG" in
  stage5)    [ "$TRIAL_SEED" -eq 1 ] || { echo "FATAL: SEED=$SEED is not a registered trial seed; use RUN_TAG=stage5dry"; exit 1; } ;;
  stage5dry) [ "$TRIAL_SEED" -eq 0 ] || { echo "FATAL: a dry run must not use a trial seed"; exit 1; } ;;
  *) echo "FATAL: RUN_TAG must be stage5 or stage5dry"; exit 1 ;;
esac
RUN="$ROOT/results/${RUN_TAG}-${FLEET}-s${SEED}-${SLURM_JOB_ID}"
SAMPLES="$RUN/samples"
mkdir -p "$SAMPLES" "$RUN/warmup" "$RUN/cells"
export HF_HOME="${HF_HOME:-$ROOT/.hf}"
echo "job=$SLURM_JOB_ID fleet=$FLEET seed=$SEED rates=$RATES arms=[$ARMS] het_size=${SLURM_HET_SIZE:-1}"

# One way to run a step on component g, het or not.
NCOMP="${SLURM_HET_SIZE:-1}"
on() { local g=$1; shift
  if [ "$NCOMP" -gt 1 ]; then srun --het-group="$g" --nodes=1 --ntasks=1 --overlap "$@"
  else srun --nodes=1 --ntasks=1 --overlap "$@"; fi; }
[ "$NCOMP" -eq "$EXPECT_TYPES" ] || { echo "FATAL: FLEET=$FLEET needs $EXPECT_TYPES component(s), got $NCOMP"; exit 1; }

# ------------------------------------------------------------ binary + materials
[ -x "$EPP_BIN" ] || { echo "FATAL: $EPP_BIN missing"; exit 1; }
GOT="$(sha256sum "$EPP_BIN" | cut -d' ' -f1)"
[ "$GOT" = "$EPP_SHA" ] || { echo "FATAL: EPP sha256 $GOT != $EPP_SHA"; exit 1; }
for f in "$ROOT/scripts/epp-config.sh" "$ROOT/scripts/policy_harness.py" \
         "$ROOT/curves/a100.json" "$ROOT/curves/rtx6000.json"; do
  [ -f "$f" ] || { echo "FATAL: missing $f"; exit 1; }
done
grep -q "def apply_energy_window" "$ROOT/scripts/policy_harness.py" \
  || { echo "FATAL: policy_harness.py predates the traffic window"; exit 1; }
cp "$ROOT/curves/"*.json "$RUN/"
{ echo "epp_sha256=$GOT"; sha256sum "$ROOT/scripts/policy_harness.py" "$ROOT/scripts/epp-config.sh" \
    "$ROOT/curves/a100.json" "$ROOT/curves/rtx6000.json"; } > "$RUN/materials.txt"

# ------------------------------------------------------------ components
declare -a HOSTS TYPES NGPU CURVE_TYPE
for g in $(seq 0 $((NCOMP - 1))); do
  HOSTS[$g]="$(on "$g" hostname 2>/dev/null | head -1)"
  TYPES[$g]="$(on "$g" nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | tr ' ' '_')"
  NGPU[$g]="$(on "$g" nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)"
  case "${TYPES[$g]}" in
    *A100*) CURVE_TYPE[$g]=a100 ;;
    *RTX_6000*) CURVE_TYPE[$g]=rtx6000 ;;
    *) echo "FATAL: no curve for GPU type ${TYPES[$g]}"; exit 1 ;;
  esac
  echo "  component $g: ${HOSTS[$g]} ${TYPES[$g]} x${NGPU[$g]} (curve ${CURVE_TYPE[$g]})"
done
# Fleet size: mixed 4 + 4, homog 8 (section 4). frnt154 has 8 A100s; only the
# first 4 serve, and only serving GPUs are metered (M6).
if [ "$FLEET" = mixed ]; then
  WANT=4
  [ "${CURVE_TYPE[0]}" != "${CURVE_TYPE[1]}" ] || { echo "FATAL: both components are ${TYPES[0]}"; exit 1; }
else
  WANT=8
fi
for g in $(seq 0 $((NCOMP - 1))); do
  [ "${NGPU[$g]}" -ge "$WANT" ] || { echo "FATAL: ${HOSTS[$g]} has ${NGPU[$g]} GPUs, need $WANT"; exit 1; }
  NGPU[$g]=$WANT
done
GPU_LIST="$(seq -s, 0 $((WANT - 1)))"

# ------------------------------------------------------------ clock skew
SKEW_FILE="$RUN/clock_skew.txt"; : > "$SKEW_FILE"
for rep in 1 2 3; do for g in $(seq 0 $((NCOMP - 1))); do
  ref="$(date +%s.%N)"; nodet="$(on "$g" date +%s.%N 2>/dev/null | head -1)"; ref2="$(date +%s.%N)"
  echo "$g $ref $nodet $ref2" >> "$SKEW_FILE"
done; done
SKEW="$(python3 - "$SKEW_FILE" <<'PY'
import sys
w = 0.0
for line in open(sys.argv[1]):
    g, a, n, b = line.split()
    w = max(w, abs(float(n) - float(b)), abs(float(n) - float(a)))
print("%.6f" % w)
PY
)"
echo "clock skew bound ${SKEW}s"; echo "$SKEW" > "$RUN/skew_seconds.txt"

# ------------------------------------------------------------ stage the model
STAGE_DIR="/tmp/hfstage-$SLURM_JOB_ID"
MDN="models--$(printf '%s' "$MODEL" | sed 's#/#--#g')"
for g in $(seq 0 $((NCOMP - 1))); do
  out="$(on "$g" env SRC_HF="$HF_HOME" MDN="$MDN" DST_ROOT="$STAGE_DIR" bash -c '
    set -u; src="$SRC_HF/hub/$MDN"
    [ -d "$src" ] || { echo "MISSING:$src"; exit 1; }
    mkdir -p "$DST_ROOT/hub/$MDN" || { echo MKDIR_FAILED; exit 1; }
    for part in refs snapshots; do [ -e "$src/$part" ] || continue
      cp -rL "$src/$part" "$DST_ROOT/hub/$MDN/" 2>/dev/null || { echo "COPY_FAILED:$part"; exit 1; }; done
    wb="$(find "$DST_ROOT/hub/$MDN" -name "*.safetensors" -exec stat -Lc %s {} + 2>/dev/null | awk "{t+=\$1} END{print t+0}")"
    [ "${wb:-0}" -ge 1000000000 ] || { echo "THIN_COPY:$wb"; exit 1; }
    echo "OK:$(( wb / 1048576 ))"' 2>/dev/null | tail -1)"
  case "$out" in OK:*) echo "  ${HOSTS[$g]}: staged ${out#OK:} MiB" ;;
    *) echo "FATAL: staging on ${HOSTS[$g]}: $out (refusing GPFS reads)"; exit 1 ;; esac
done
export HF_HOME="$STAGE_DIR" HF_HUB_OFFLINE=1

# ------------------------------------------------------------ servers + samplers
PORT_BASE=8100
PORTS=(); EP_TYPES=(); SERVER_PIDS=(); SAMPLER_PIDS=(); OTHER_PIDS=()
for g in $(seq 0 $((NCOMP - 1))); do
  for ((i=0; i<WANT; i++)); do
    port=$((PORT_BASE + g * 100 + i))
    # PCI_BUS_ID: CUDA's device i is NVML's index i, so the sampler meters
    # exactly the GPUs that serve (M6).
    on "$g" env -u SSL_CERT_FILE CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES="$i" \
      "$APPTAINER" exec --nv "$IMG" vllm serve "$MODEL" --served-model-name served \
        --host 0.0.0.0 --port "$port" --gpu-memory-utilization 0.85 --max-model-len 2048 \
        --max-num-seqs "$MAX_NUM_SEQS" --max-num-batched-tokens "$MAX_BATCHED" \
      > "$RUN/vllm-${HOSTS[$g]}-gpu$i.log" 2>&1 &
    SERVER_PIDS+=($!); PORTS+=("${HOSTS[$g]}:$port"); EP_TYPES+=("${CURVE_TYPE[$g]}")
    sleep 8
  done
done
for g in $(seq 0 $((NCOMP - 1))); do
  on "$g" env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" \
    python3 "$ROOT/scripts/node_energy_sampler.py" --out "$SAMPLES/energy-${HOSTS[$g]}.jsonl" \
      --interval "$SAMPLE_INTERVAL" --gpus "$GPU_LIST" \
    > "$RUN/sampler-${HOSTS[$g]}.log" 2>&1 &
  SAMPLER_PIDS+=($!)
done
cleanup() {
  for pid in "${OTHER_PIDS[@]:-}" "${SAMPLER_PIDS[@]:-}" "${SERVER_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null; done
  for g in $(seq 0 $((NCOMP - 1))); do on "$g" rm -rf "$STAGE_DIR" 2>/dev/null; done
  wait 2>/dev/null || true
  sleep 2
}
trap cleanup EXIT

NEP="${#PORTS[@]}"; deadline=$(( $(date +%s) + 1200 ))
until [ "$(for ep in "${PORTS[@]}"; do curl -fsS --max-time 3 "http://$ep/health" >/dev/null 2>&1 && echo up; done | grep -c up)" -eq "$NEP" ]; do
  [ "$(date +%s)" -ge "$deadline" ] && { echo "FATAL: not all $NEP servers ready"; for f in "$RUN"/vllm-*.log; do printf '  %s: ' "$(basename "$f")"; tail -1 "$f" | cut -c1-120; done; exit 1; }
  sleep 5
done
for f in "$RUN"/vllm-*.log; do
  grep -qE "max_num_seqs.{0,4}${MAX_NUM_SEQS}\b" "$f" && grep -qE "max_num_batched_tokens.{0,4}${MAX_BATCHED}\b" "$f" \
    || { echo "FATAL: $(basename "$f") does not confirm $MAX_NUM_SEQS/$MAX_BATCHED"; exit 1; }
done
sleep 3
for g in $(seq 0 $((NCOMP - 1))); do
  f="$SAMPLES/energy-${HOSTS[$g]}.jsonl"
  [ "$(wc -l < "$f" 2>/dev/null || echo 0)" -ge 2 ] || { echo "FATAL: sampler on ${HOSTS[$g]} silent"; exit 1; }
  n="$(head -1 "$f" | python3 -c "import json,sys;print(len(json.loads(sys.stdin.read()).get('gpus',[])))")"
  [ "$n" -eq "$WANT" ] || { echo "FATAL: sampler on ${HOSTS[$g]} meters $n GPUs, fleet uses $WANT"; exit 1; }
done
echo "ready: $NEP servers, limits confirmed, samplers metering $WANT GPUs per node"

# ------------------------------------------------------------ router plumbing
EPP_HOST="$(hostname)"
BASE=$(( 30000 + (SLURM_JOB_ID % 2000) * 10 ))
EPP_GRPC=$((BASE + 2)); EPP_HEALTH=$((BASE + 3)); EPP_METRICS=$((BASE + 4))
ENVOY_PORT=$((BASE + 5)); ENVOY_ADMIN=$((BASE + 6))
# File discovery at v0.11.0 accepts only IPv4 literals (validateIPv4Address):
# host names are rejected and the EPP comes up with no endpoints. Dry run
# 12335940 failed exactly so, at the first warm-up. Resolve every node now and
# refuse if one does not resolve.
declare -A HOST_IP
for g in $(seq 0 $((NCOMP - 1))); do
  ip="$(getent ahostsv4 "${HOSTS[$g]}" | awk 'NR==1{print $1}')"
  case "$ip" in [0-9]*.[0-9]*.[0-9]*.[0-9]*) HOST_IP[${HOSTS[$g]}]="$ip" ;;
    *) echo "FATAL: ${HOSTS[$g]} does not resolve to an IPv4 address"; exit 1 ;; esac
  echo "  ${HOSTS[$g]} -> $ip"
done
{
  echo "endpoints:"
  for k in "${!PORTS[@]}"; do
    h="${PORTS[$k]%%:*}"
    printf '  - name: vllm-%d\n    address: "%s"\n    port: "%s"\n    labels: { energy-epp/index: "%d", energy-epp/gpu-type: "%s" }\n' \
      "$k" "${HOST_IP[$h]}" "${PORTS[$k]##*:}" "$k" "${EP_TYPES[$k]}"
  done
} > "$RUN/endpoints.yaml"
cat > "$RUN/envoy.yaml" <<EOF
admin:
  address: { socket_address: { address: 127.0.0.1, port_value: $ENVOY_ADMIN } }
static_resources:
  listeners:
    - name: inference
      address: { socket_address: { address: 127.0.0.1, port_value: $ENVOY_PORT } }
      filter_chains:
        - filters:
            - name: envoy.filters.network.http_connection_manager
              typed_config:
                "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
                stat_prefix: inference
                route_config:
                  name: inference
                  virtual_hosts:
                    - name: inference
                      domains: ["*"]
                      routes:
                        - match: { prefix: "/" }
                          route: { cluster: original_destination_cluster, timeout: 600s, idle_timeout: 600s }
                http_filters:
                  - name: envoy.filters.http.ext_proc
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExternalProcessor
                      grpc_service:
                        envoy_grpc: { cluster_name: epp, authority: "127.0.0.1:$EPP_GRPC" }
                        timeout: 10s
                      processing_mode:
                        request_header_mode: SEND
                        response_header_mode: SEND
                        request_body_mode: FULL_DUPLEX_STREAMED
                        response_body_mode: FULL_DUPLEX_STREAMED
                        request_trailer_mode: SEND
                        response_trailer_mode: SEND
                      message_timeout: 600s
                  - name: envoy.filters.http.router
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
    - name: epp
      type: STATIC
      connect_timeout: 86400s
      lb_policy: LEAST_REQUEST
      typed_extension_protocol_options:
        envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
          "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
          explicit_http_config: { http2_protocol_options: {} }
      load_assignment:
        cluster_name: epp
        endpoints:
          - lb_endpoints:
              - endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: $EPP_GRPC } } }
    - name: original_destination_cluster
      type: ORIGINAL_DST
      connect_timeout: 600s
      lb_policy: CLUSTER_PROVIDED
      circuit_breakers:
        thresholds: [ { max_connections: 10000, max_pending_requests: 10000, max_requests: 10000 } ]
      original_dst_lb_config: { use_http_header: true, http_header_name: x-gateway-destination-endpoint }
EOF

ROUTER_PIDS=()
start_router() {  # $1 arm, $2 log tag
  ARM=$1 ENDPOINTS="$RUN/endpoints.yaml" CURVE_DIR="$RUN" SEED="$SEED" HEADROOM="$HEADROOM" \
    MAX_INFLIGHT="$MAX_INFLIGHT" SLO_S="$SLO" bash "$ROOT/scripts/epp-config.sh" > "$RUN/epp-$2.yaml" || return 1
  "$EPP_BIN" --pool-name epp --config-file "$RUN/epp-$2.yaml" \
    --secure-serving=false --metrics-endpoint-auth=false --tracing=false --allow-experimental-plugins \
    --grpc-port "$EPP_GRPC" --grpc-health-port "$EPP_HEALTH" --metrics-port "$EPP_METRICS" \
    > "$RUN/epp-$2.log" 2>&1 &
  ROUTER_PIDS=($!)
  "$APPTAINER" exec "$ENVOY_IMG" envoy -c "$RUN/envoy.yaml" --disable-hot-restart --log-level warn \
    > "$RUN/envoy-$2.log" 2>&1 &
  ROUTER_PIDS+=($!); OTHER_PIDS=("${ROUTER_PIDS[@]}")
  local d=$(( $(date +%s) + 120 ))
  until [ "$(curl -s --max-time 2 "http://127.0.0.1:$ENVOY_ADMIN/ready")" = "LIVE" ] \
        && curl -s --max-time 2 "http://127.0.0.1:$EPP_METRICS/metrics" >/dev/null; do
    [ "$(date +%s)" -ge "$d" ] && { echo "router for $1 not ready"; tail -5 "$RUN/epp-$2.log"; return 1; }
    sleep 2
  done
  # The in-flight wiring the smoke test found fragile: every endpoint must
  # carry the default producer's count before any request is offered.
  if [ "$1" != stock_llmd ]; then
    local w; w=$(grep '"Injected dynamic attribute' "$RUN/epp-$2.log" | grep -c '"key":"InFlightLoadDataKey/inflight-load-producer"')
    [ "$w" -eq "$NEP" ] || { echo "in-flight count on $w of $NEP endpoints for $1"; return 1; }
  fi
}
stop_router() {
  kill "${ROUTER_PIDS[@]}" 2>/dev/null; sleep 3; kill -9 "${ROUTER_PIDS[@]}" 2>/dev/null
  wait "${ROUTER_PIDS[@]}" 2>/dev/null; ROUTER_PIDS=(); OTHER_PIDS=(); sleep 2
}
harness() {  # $1 arm label, $2 rate, $3 n requests, $4 out path
  env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3 "$ROOT/scripts/policy_harness.py" \
    --endpoints "$(IFS=,; echo "${PORTS[*]}")" --gpus 0 --endpoint-types "$(IFS=,; echo "${EP_TYPES[*]}")" \
    --policies "$1" --router "127.0.0.1:$ENVOY_PORT" --epp-metrics "127.0.0.1:$EPP_METRICS" \
    --energy-window traffic --energy-mode multinode --sample-dir "$SAMPLES" --clock-skew "$SKEW" \
    --rate "$2" --requests "$3" --slo "$SLO" --workers "$WORKERS" --scratch "$RUN" --seed "$SEED" \
    --out "$4" 2>&1 | tee -a "$RUN/harness.log"
}

# ------------------------------------------------------------ the trial
IFS=',' read -ra RATE_ARR <<< "$RATES"
for rate in "${RATE_ARR[@]}"; do
  ORDER="$(python3 -c "
import random, sys
a = '$ARMS'.split()
random.Random('$SEED-$rate').shuffle(a)   # str seed: deterministic across runs and Python versions
print(' '.join(a))")"
  echo "$rate $ORDER" >> "$RUN/arm_order.txt"
  echo; echo "=========== level $rate req/s; arm order: $ORDER ==========="

  # 1. warm-up, discarded (kept as a record under warmup/)
  wn="$(python3 -c "import math;print(max(50, math.ceil($rate * $WARMUP_S)))")"
  start_router round_robin "warmup-rate$rate" || { echo "FATAL: warm-up router"; exit 2; }
  harness warmup "$rate" "$wn" "$RUN/warmup/warmup-rate$rate.json" >/dev/null
  stop_router

  # 2. every arm, freshly routed
  n_req="$(python3 -c "import math;print(max(100, math.ceil($rate * $DURATION)))")"
  pos=0
  for arm in $ORDER; do
    pos=$((pos + 1)); ok=0
    for try in $(seq 1 "$MAX_CELL_TRIES"); do
      cell="$RUN/cells/$arm-rate$rate-try$try.json"
      start_router "$arm" "$arm-rate$rate-try$try" || { echo "FATAL: router for $arm at $rate"; exit 2; }
      harness "$arm" "$rate" "$n_req" "$cell" || true
      stop_router
      step="$(python3 -c "
import json, sys
try:
    r = json.load(open('$cell')); r = r['results'][0]
    print(abs(r.get('clock_step_s') or 0.0))
except Exception:
    print('nan')")"
      if python3 -c "import sys; s='$step'; sys.exit(0 if s != 'nan' and float(s) <= $CLOCK_STEP_MAX else 1)"; then
        ok=1; break
      fi
      echo "cell $arm at $rate, try $try: clock step $step s (or no record); re-running with the same seed" \
        | tee -a "$RUN/infrastructure-events.txt"
    done
    [ "$ok" -eq 1 ] || { echo "FATAL: $arm at $rate failed $MAX_CELL_TRIES tries; infrastructure failure, resubmit with SEED=$SEED" \
      | tee -a "$RUN/infrastructure-events.txt"; exit 3; }
    python3 - "$cell" "$RUN/policies-rate$rate.json" "$SEED" "$pos" "$ORDER" "$try" <<'PY'
import json, os, sys
cell, out, seed, pos, order, tries = sys.argv[1:7]
rec = json.load(open(cell))["results"][0]
rec.update({"trial_seed": int(seed), "arm_order": int(pos), "arm_permutation": order.split(),
            "cell_tries": int(tries), "cell_file": os.path.basename(cell)})
doc = json.load(open(out)) if os.path.exists(out) else {"results": []}
doc["results"].append(rec)
tmp = out + ".tmp"
json.dump(doc, open(tmp, "w"), indent=1)
os.replace(tmp, out)
PY
  done
done

echo; echo "trial complete: $RUN"
ls "$RUN"/policies-rate*.json
exit 0
