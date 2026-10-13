#!/bin/bash
#SBATCH --job-name=policy-smoke
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --gres=gpu:rtx6000:2
#SBATCH --cpus-per-task=12
#SBATCH --mem=64G
#SBATCH --time=01:30:00
#SBATCH --output=%x-%j-%N.out
#
# Stage 4 cluster smoke test of the energy-epp policy plugins (materials
# addendum, "still to come"). Not a measurement: two GPUs, shared node, short
# cells. It answers, with counters rather than logs:
#   1. does each generated arm config load and route real requests through
#      Envoy -> EPP -> vLLM (router mode of policy_harness.py)?
#   2. does energy-epp-policy-scorer decide once per request
#      (energy_epp_policy_picks_total == completed), and with what outcomes?
#   3. does the policy behave as its rule says on real servers:
#      energy_consolidate packs onto one endpoint at a load one RTX 6000 can
#      carry (about 27 req/s at p95 2 s), round_robin splits evenly?
#   4. how far does the EPP's own in-flight count (llm_d_epp_inflight_requests)
#      sit from vLLM's running + waiting? The EPP snapshots per scheduling
#      cycle and increments after the pick; the Python Router held a lock
#      across both, so concurrent cycles can differ. Measured, not assumed.
set -uo pipefail

module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"

ROOT="$HOME/energy-epp"
VLLM_IMG="$ROOT/images/vllm-v0.30.0.sif"
ENVOY_IMG="$ROOT/images/envoy.sif"
EPP_BIN="$ROOT/bin/epp-energy-v0.11.0"
EPP_SHA_EXPECTED="${EPP_SHA:?set EPP_SHA to the local build hash}"
MODEL="${MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"
ARMS="${ARMS:-energy_consolidate energy_greedy slo_packing round_robin least_loaded random stock_llmd}"
RATE="${RATE:-20}"
N_REQ="${N_REQ:-600}"
SEED="${SEED:-501}"
RUN="$ROOT/results/policy-smoke-$SLURM_JOB_ID"
mkdir -p "$RUN"
export HF_HOME="${HF_HOME:-$ROOT/.hf}"

BASE=$(( 30000 + (SLURM_JOB_ID % 2000) * 10 ))
VLLM_PORT0=$BASE; VLLM_PORT1=$((BASE + 1))
EPP_GRPC=$((BASE + 2)); EPP_HEALTH=$((BASE + 3)); EPP_METRICS=$((BASE + 4))
ENVOY_PORT=$((BASE + 5)); ENVOY_ADMIN=$((BASE + 6))

PIDS=(); FAILS=()
fail() { FAILS+=("$1"); echo "FAIL: $1"; }
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  sleep 3
  for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null; done
  wait 2>/dev/null
}
trap cleanup EXIT
echo "node=$(hostname) job=$SLURM_JOB_ID base=$BASE gpus=${CUDA_VISIBLE_DEVICES:-unset} arms=[$ARMS] rate=$RATE n=$N_REQ"

# ------------------------------------------------------------ binary
[ -x "$EPP_BIN" ] || { echo "FATAL: $EPP_BIN missing"; exit 1; }
EPP_SHA="$(sha256sum "$EPP_BIN" | cut -d' ' -f1)"
[ "$EPP_SHA" = "$EPP_SHA_EXPECTED" ] || { echo "FATAL: EPP sha256 $EPP_SHA != local build $EPP_SHA_EXPECTED"; exit 1; }
echo "epp sha256=$EPP_SHA"
for f in "$ROOT/scripts/epp-config.sh" "$ROOT/curves/a100.json" "$ROOT/curves/rtx6000.json"; do
  [ -f "$f" ] || { echo "FATAL: missing $f"; exit 1; }
done

# ------------------------------------------------------------ stage model locally
STAGE_DIR="/tmp/hfstage-$SLURM_JOB_ID"
MDN="models--$(printf '%s' "$MODEL" | sed 's#/#--#g')"
src="$HF_HOME/hub/$MDN"
[ -d "$src" ] || { echo "FATAL: no $MDN under $HF_HOME/hub"; exit 1; }
mkdir -p "$STAGE_DIR/hub/$MDN" || exit 1
for part in refs snapshots; do
  [ -e "$src/$part" ] || continue
  cp -rL "$src/$part" "$STAGE_DIR/hub/$MDN/" 2>/dev/null || { echo "FATAL: staging $part failed"; exit 1; }
done
export HF_HOME="$STAGE_DIR" HF_HUB_OFFLINE=1

# ------------------------------------------------------------ two vLLM servers
IFS=',' read -r -a GPUS <<< "${CUDA_VISIBLE_DEVICES:-0,1}"
[ "${#GPUS[@]}" -ge 2 ] || { echo "FATAL: need 2 GPUs"; exit 1; }
i=0
for port in "$VLLM_PORT0" "$VLLM_PORT1"; do
  CUDA_VISIBLE_DEVICES="${GPUS[$i]}" env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$VLLM_IMG" \
    vllm serve "$MODEL" --served-model-name served --host 127.0.0.1 --port "$port" \
      --gpu-memory-utilization 0.85 --max-model-len 2048 \
      --max-num-seqs 256 --max-num-batched-tokens 2048 > "$RUN/vllm-$i.log" 2>&1 &
  PIDS+=($!); i=$((i + 1)); sleep 8
done
deadline=$(( $(date +%s) + 900 ))
until [ "$(for p in "$VLLM_PORT0" "$VLLM_PORT1"; do curl -fsS --max-time 3 "http://127.0.0.1:$p/health" >/dev/null 2>&1 && echo up; done | grep -c up)" -eq 2 ]; do
  [ "$(date +%s)" -ge "$deadline" ] && { echo "FATAL: vLLM not ready"; tail -5 "$RUN"/vllm-*.log; exit 1; }
  sleep 5
done
for f in "$RUN"/vllm-*.log; do
  grep -qE "max_num_seqs.{0,4}256\b" "$f" && grep -qE "max_num_batched_tokens.{0,4}2048\b" "$f" \
    || { echo "FATAL: $(basename "$f") does not confirm 256/2048"; exit 1; }
done
echo "vLLM 2/2 healthy, limits 256/2048 confirmed in both logs"

cat > "$RUN/endpoints.yaml" <<EOF
endpoints:
  - name: vllm-0
    address: "127.0.0.1"
    port: "$VLLM_PORT0"
    labels: { energy-epp/index: "0", energy-epp/gpu-type: "rtx6000" }
  - name: vllm-1
    address: "127.0.0.1"
    port: "$VLLM_PORT1"
    labels: { energy-epp/index: "1", energy-epp/gpu-type: "rtx6000" }
EOF
cp "$ROOT/curves/"*.json "$RUN/"

# Envoy config: as router_smoke.sbatch (ext_proc to the EPP, ORIGINAL_DST on
# x-gateway-destination-endpoint).
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

served() { local n; n="$(grep -c 'POST /v1/completions' "$RUN/vllm-$1.log" 2>/dev/null)"; echo "${n:-0}"; }

# Samples, every 0.5 s: the EPP's in-flight gauge per endpoint and vLLM's own
# running + waiting per server. Written to a CSV the verdict reads. Only the
# default producer's series: job 12335751 summed two producers and doubled it.
sampler() {  # $1 = output csv
  echo "t,epp_inflight_0,epp_inflight_1,vllm_rw_0,vllm_rw_1" > "$1"
  while :; do
    m="$(curl -s --max-time 1 "http://127.0.0.1:$EPP_METRICS/metrics")"
    e0="$(printf '%s\n' "$m" | awk '/^llm_d_epp_inflight_requests\{/ && /endpoint_name="vllm-0"/ && /producer_name="inflight-load-producer"/ {s+=$NF} END{print s+0}')"
    e1="$(printf '%s\n' "$m" | awk '/^llm_d_epp_inflight_requests\{/ && /endpoint_name="vllm-1"/ && /producer_name="inflight-load-producer"/ {s+=$NF} END{print s+0}')"
    v=()
    for p in "$VLLM_PORT0" "$VLLM_PORT1"; do
      v+=("$(curl -s --max-time 1 "http://127.0.0.1:$p/metrics" \
        | awk '/^vllm:num_requests_(running|waiting)\{/ {s+=$NF} END{print s+0}')")
    done
    echo "$(date +%s.%N),$e0,$e1,${v[0]},${v[1]}" >> "$1"
    sleep 0.5
  done
}

# ------------------------------------------------------------ per arm
for arm in $ARMS; do
  echo; echo "================ arm $arm ================"
  ARM=$arm ENDPOINTS="$RUN/endpoints.yaml" CURVE_DIR="$RUN" SEED="$SEED" HEADROOM=0 \
    MAX_INFLIGHT=256 SLO_S=2.0 bash "$ROOT/scripts/epp-config.sh" > "$RUN/epp-$arm.yaml" \
    || { fail "$arm: config generation failed"; continue; }
  "$EPP_BIN" --pool-name epp --config-file "$RUN/epp-$arm.yaml" \
    --secure-serving=false --metrics-endpoint-auth=false --tracing=false --allow-experimental-plugins \
    --grpc-port "$EPP_GRPC" --grpc-health-port "$EPP_HEALTH" --metrics-port "$EPP_METRICS" \
    > "$RUN/epp-$arm.log" 2>&1 &
  EPP_PID=$!
  "$APPTAINER" exec "$ENVOY_IMG" envoy -c "$RUN/envoy.yaml" --disable-hot-restart --log-level warn \
    > "$RUN/envoy-$arm.log" 2>&1 &
  ENVOY_PID=$!
  PIDS+=("$EPP_PID" "$ENVOY_PID")
  deadline=$(( $(date +%s) + 120 ))
  until [ "$(curl -s --max-time 2 "http://127.0.0.1:$ENVOY_ADMIN/ready")" = "LIVE" ] \
        && curl -s --max-time 2 "http://127.0.0.1:$EPP_METRICS/metrics" >/dev/null; do
    [ "$(date +%s)" -ge "$deadline" ] && { fail "$arm: router not ready"; tail -8 "$RUN/epp-$arm.log"; break; }
    sleep 2
  done
  grep -oE '\{Filters: \[[^]]*\], Scorers: \[[^]]*\], Picker: [^}"]*' "$RUN/epp-$arm.log" | head -1 \
    | sed "s/^/  profile: /"

  s0a="$(served 0)"; s0b="$(served 1)"
  sampler "$RUN/inflight-$arm.csv" & SAMPLER=$!
  env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$VLLM_IMG" python3 "$ROOT/scripts/policy_harness.py" \
    --endpoints "127.0.0.1:$VLLM_PORT0,127.0.0.1:$VLLM_PORT1" --gpus 0,1 \
    --endpoint-types rtx6000,rtx6000 --policies "$arm" \
    --router "127.0.0.1:$ENVOY_PORT" --epp-metrics "127.0.0.1:$EPP_METRICS" \
    --energy-window traffic --rate "$RATE" --requests "$N_REQ" --slo 2.0 \
    --workers 2 --scratch "$RUN" --seed "$SEED" --out "$RUN/cell-$arm.json" 2>&1 \
    | tee -a "$RUN/harness.log" | grep -vE '^\s*$'
  kill "$SAMPLER" 2>/dev/null; wait "$SAMPLER" 2>/dev/null
  sleep 2
  d0=$(( $(served 0) - s0a )); d1=$(( $(served 1) - s0b ))
  curl -s --max-time 3 "http://127.0.0.1:$EPP_METRICS/metrics" > "$RUN/epp-metrics-$arm.txt"

  # verdict for this arm, from the harness record, the vLLM logs and the CSV
  python3 - "$arm" "$RUN/cell-$arm.json" "$RUN/inflight-$arm.csv" "$d0" "$d1" "$N_REQ" <<'PY' \
    | tee -a "$RUN/arm-verdicts.txt"
import csv, json, sys
arm, cell, csvp, d0, d1, n = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), int(sys.argv[6])
try:
    r = json.load(open(cell)); r = r["results"][0] if "results" in r else r
except Exception as e:
    print("ARM %s FAIL no harness record (%s)" % (arm, e)); sys.exit(0)
fails = []
if r.get("completed") != n or r.get("errors"):
    fails.append("completed %s errors %s of %d" % (r.get("completed"), r.get("errors"), n))
if r.get("routing") != "router":
    fails.append("routing=%s" % r.get("routing"))
if d0 + d1 != r.get("completed"):
    fails.append("vLLM logs show %d+%d=%d completions" % (d0, d1, d0 + d1))
picks = r.get("epp_picks")
ours = arm in ("energy_consolidate", "energy_greedy", "slo_packing", "round_robin", "least_loaded")
if ours:
    tot = sum((picks or {}).values())
    if picks is None or abs(tot - r["completed"]) > 0:
        fails.append("EPP decisions %s for %s completed" % (tot if picks is not None else None, r["completed"]))
    if (picks or {}).get("misconfigured", 0) or (picks or {}).get("ungrounded", 0):
        fails.append("misconfigured/ungrounded picks %s" % picks)
share = max(d0, d1) / max(1, d0 + d1)
if arm == "energy_consolidate" and share < 0.8:
    fails.append("consolidate put only %.0f%% on one endpoint at a load one GPU carries" % (100 * share))
if arm == "round_robin" and abs(d0 - d1) > 2:
    fails.append("round_robin split %d/%d" % (d0, d1))
rows = list(csv.DictReader(open(csvp)))
busy = [x for x in rows if float(x["vllm_rw_0"]) + float(x["vllm_rw_1"]) > 0]
diffs = [abs((float(x["epp_inflight_0"]) + float(x["epp_inflight_1"]))
             - (float(x["vllm_rw_0"]) + float(x["vllm_rw_1"]))) for x in busy]
vl = [float(x["vllm_rw_0"]) + float(x["vllm_rw_1"]) for x in busy]
gap = (sum(diffs) / len(diffs)) if diffs else None
lvl = (sum(vl) / len(vl)) if vl else None
print("ARM %s %s | completed=%s errors=%s split vllm-0/vllm-1=%d/%d (top %.0f%%) | epp_picks=%s | "
      "p95=%.2fs slo=%.3f keepup=%.3f clock_step=%.4f gpj=%s | inflight: vLLM mean %.1f, |EPP-vLLM| mean %s over %d samples"
      % (arm, "PASS" if not fails else "FAIL", r.get("completed"), r.get("errors"), d0, d1, 100 * share,
         picks, r.get("latency_p95") or -1, r.get("slo_rate") or -1, r.get("keepup") or -1,
         r.get("clock_step_s") or 0, r.get("goodput_per_joule"), lvl or 0,
         "%.2f" % gap if gap is not None else "n/a", len(busy)))
for f in fails:
    print("   reason: " + f)
PY

  kill "$EPP_PID" "$ENVOY_PID" 2>/dev/null; sleep 3; kill -9 "$EPP_PID" "$ENVOY_PID" 2>/dev/null
  wait "$EPP_PID" "$ENVOY_PID" 2>/dev/null
  sleep 5
done

echo
echo "================ verdict ================"
cat "$RUN/arm-verdicts.txt"
if grep -q "FAIL" "$RUN/arm-verdicts.txt" || [ "${#FAILS[@]}" -gt 0 ]; then
  printf 'reason=%s\n' "${FAILS[@]}"
  echo "VERDICT=FAIL" | tee -a "$RUN/arm-verdicts.txt"; exit 1
fi
echo "VERDICT=PASS" | tee -a "$RUN/arm-verdicts.txt"
exit 0
