#!/bin/bash
#SBATCH --job-name=router-smoke
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --gres=gpu:rtx6000:2
#SBATCH --cpus-per-task=8
#SBATCH --mem=48G
#SBATCH --time=00:40:00
#SBATCH --output=%x-%j-%N.out
#
# End-to-end proof that the llm-d-router EPP, with this project's out-of-tree
# plugin, routes real requests on Frontenac with no Kubernetes:
#
#   curl -> Envoy (ext_proc) -> EPP (file discovery, our probe scorer)
#        -> x-gateway-destination-endpoint -> one of two vLLM servers
#
# Not a measurement. No energy is recorded, the allocation is not exclusive,
# and the scorer is the inert probe that gives every endpoint 1.0. It answers
# three questions that were, until this job, asserted from documentation only:
#   1. is the Envoy in images/envoy.sif new enough (the docs require >= 1.31)?
#   2. does a statically cross-compiled EPP run on a compute node?
#   3. does the router invoke our plugin and route to every endpoint?
#
# Evidence is counted, not logged: the probe's Prometheus counter, and each
# vLLM server's own access log. A request routed through the EPP shows up in
# both; a request that bypassed it shows up in only one.
set -uo pipefail

module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"

ROOT="$HOME/energy-epp"
VLLM_IMG="$ROOT/images/vllm-v0.30.0.sif"
ENVOY_IMG="$ROOT/images/envoy.sif"
EPP_BIN="${EPP_BIN:-$ROOT/bin/epp-energy-v0.11.0}"
EPP_SHA_EXPECTED="${EPP_SHA:-}"
MODEL="${MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"
N_REQ="${N_REQ:-40}"
RUN="$ROOT/results/router-smoke-$SLURM_JOB_ID"
mkdir -p "$RUN"
export HF_HOME="${HF_HOME:-$ROOT/.hf}"

# The allocation is shared, so fixed ports could collide with another user's
# job on the same node. Derive a private block from the job id.
BASE=$(( 30000 + (SLURM_JOB_ID % 2000) * 10 ))
VLLM_PORT0=$BASE; VLLM_PORT1=$((BASE + 1))
EPP_GRPC=$((BASE + 2)); EPP_HEALTH=$((BASE + 3)); EPP_METRICS=$((BASE + 4))
ENVOY_PORT=$((BASE + 5)); ENVOY_ADMIN=$((BASE + 6))

PIDS=()
FAILS=()
fail() { FAILS+=("$1"); echo "FAIL: $1"; }
cleanup() {
  for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
  sleep 3
  for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null; done
  # Reap before exit; children outliving the script make Slurm record CANCELLED.
  wait 2>/dev/null
}
trap cleanup EXIT

echo "node=$(hostname) job=$SLURM_JOB_ID ports base=$BASE gpus=${CUDA_VISIBLE_DEVICES:-unset}"

# ------------------------------------------------------------ 1. Envoy version
# Keep the whole output and search it. The first version of this line took
# `tail -1`, which is a blank line when Envoy ends its output with a newline,
# so job 12321493 refused to run on an empty string (correctly, in 4 s).
"$APPTAINER" exec "$ENVOY_IMG" envoy --version > "$RUN/envoy-version.txt" 2>&1
echo "--- envoy --version, raw ---"; cat "$RUN/envoy-version.txt"; echo "---"
ENVOY_RAW="$(grep -m1 -i 'version' "$RUN/envoy-version.txt")"
ENVOY_VER="$(printf '%s' "$ENVOY_RAW" | grep -oE '/[0-9]+\.[0-9]+\.[0-9]+/' | head -1 | tr -d /)"
echo "envoy: ${ENVOY_VER:-UNPARSED} (raw: $ENVOY_RAW)"
if [ -z "$ENVOY_VER" ]; then
  echo "FATAL: could not read the Envoy version from $ENVOY_IMG"; exit 1
fi
EMAJ="${ENVOY_VER%%.*}"; EREST="${ENVOY_VER#*.}"; EMIN="${EREST%%.*}"
if [ "$EMAJ" -lt 1 ] || { [ "$EMAJ" -eq 1 ] && [ "$EMIN" -lt 31 ]; }; then
  echo "FATAL: Envoy $ENVOY_VER is older than the 1.31 the router's file-discovery docs require."
  exit 1
fi

# ------------------------------------------------------------ 2. EPP binary
[ -x "$EPP_BIN" ] || { echo "FATAL: $EPP_BIN missing or not executable"; exit 1; }
EPP_SHA="$(sha256sum "$EPP_BIN" | cut -d' ' -f1)"
echo "epp: $EPP_BIN sha256=$EPP_SHA"
if [ -n "$EPP_SHA_EXPECTED" ] && [ "$EPP_SHA" != "$EPP_SHA_EXPECTED" ]; then
  echo "FATAL: EPP binary hash does not match the one built locally ($EPP_SHA_EXPECTED)."
  exit 1
fi

# ------------------------------------------------------- 3. stage model locally
# Same pattern as stage2_*.sbatch: GPFS out of the read path, refs/ and
# snapshots/ only so weights are not copied twice, refuse a thin copy.
STAGE_DIR="/tmp/hfstage-$SLURM_JOB_ID"
MDN="models--$(printf '%s' "$MODEL" | sed 's#/#--#g')"
src="$HF_HOME/hub/$MDN"
[ -d "$src" ] || { echo "FATAL: no $MDN under $HF_HOME/hub"; exit 1; }
mkdir -p "$STAGE_DIR/hub/$MDN" || { echo "FATAL: cannot create $STAGE_DIR"; exit 1; }
for part in refs snapshots; do
  [ -e "$src/$part" ] || continue
  cp -rL "$src/$part" "$STAGE_DIR/hub/$MDN/" 2>/dev/null \
    || { echo "FATAL: staging $part failed; refusing GPFS reads"; exit 1; }
done
MB="$(find "$STAGE_DIR/hub/$MDN" -name '*.safetensors' -exec stat -Lc %s {} + 2>/dev/null \
      | awk '{t+=$1} END{printf "%d", (t+0)/1048576}')"
[ "${MB:-0}" -ge 1000 ] || { echo "FATAL: thin copy, ${MB:-0} MiB"; exit 1; }
echo "staged $MB MiB to $STAGE_DIR"
export HF_HOME="$STAGE_DIR"
export HF_HUB_OFFLINE=1

# ------------------------------------------------------------ 4. two vLLM servers
# Slurm's CUDA_VISIBLE_DEVICES names the GPUs this allocation owns; give each
# server one entry of it rather than assuming indices 0 and 1.
IFS=',' read -r -a GPUS <<< "${CUDA_VISIBLE_DEVICES:-0,1}"
[ "${#GPUS[@]}" -ge 2 ] || { echo "FATAL: need 2 GPUs, have '${CUDA_VISIBLE_DEVICES:-}'"; exit 1; }
i=0
for port in "$VLLM_PORT0" "$VLLM_PORT1"; do
  CUDA_VISIBLE_DEVICES="${GPUS[$i]}" env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$VLLM_IMG" \
    vllm serve "$MODEL" --served-model-name served \
      --host 127.0.0.1 --port "$port" \
      --gpu-memory-utilization 0.85 --max-model-len 2048 \
      --max-num-seqs 256 --max-num-batched-tokens 2048 \
      > "$RUN/vllm-$i.log" 2>&1 &
  PIDS+=($!)
  i=$((i + 1))
  sleep 8
done

deadline=$(( $(date +%s) + 900 ))
while :; do
  up=0
  for port in "$VLLM_PORT0" "$VLLM_PORT1"; do
    curl -fsS --max-time 3 "http://127.0.0.1:$port/health" >/dev/null 2>&1 && up=$((up + 1))
  done
  [ "$up" -eq 2 ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "FATAL: vLLM not ready in 900 s"; tail -5 "$RUN"/vllm-*.log; exit 1
  fi
  sleep 5
done
echo "vLLM: 2/2 healthy"

# Direct request first, bypassing the router entirely. If this fails the
# servers are broken and a routed failure would say nothing about routing.
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 60 \
        -H 'Content-Type: application/json' \
        -d '{"model":"served","prompt":"Hello","max_tokens":4}' \
        "http://127.0.0.1:$VLLM_PORT0/v1/completions")"
echo "direct request to vLLM: HTTP $code"
[ "$code" = "200" ] || { echo "FATAL: vLLM rejects a direct request; routing cannot be judged"; exit 1; }

# ------------------------------------------------------------ 5. configs
cat > "$RUN/endpoints.yaml" <<EOF
endpoints:
  - name: vllm-0
    address: "127.0.0.1"
    port: "$VLLM_PORT0"
  - name: vllm-1
    address: "127.0.0.1"
    port: "$VLLM_PORT1"
EOF

cat > "$RUN/epp-config.yaml" <<EOF
plugins:
  - name: file-disc
    type: file-discovery
    parameters:
      path: $RUN/endpoints.yaml
      watchFile: false
  - name: probe
    type: energy-epp-plumbing-probe
  - name: random-picker
    type: random-picker
  - name: single-profile
    type: single-profile-handler
schedulingProfiles:
  - name: default
    plugins:
      - pluginRef: probe
      - pluginRef: random-picker
dataLayer:
  discovery:
    endpoints:
      pluginRef: file-disc
EOF

# From the router's docs/discovery.md at v0.11.0, with ports substituted. The
# EPP cluster has no transport_socket, i.e. plaintext gRPC, which is why the
# EPP is started with --secure-serving=false below: its default is true, and
# the two would disagree on the first request.
cat > "$RUN/envoy.yaml" <<EOF
admin:
  address:
    socket_address: { address: 127.0.0.1, port_value: $ENVOY_ADMIN }
static_resources:
  listeners:
    - name: inference
      address:
        socket_address: { address: 127.0.0.1, port_value: $ENVOY_PORT }
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
                          route:
                            cluster: original_destination_cluster
                            timeout: 600s
                            idle_timeout: 600s
                http_filters:
                  - name: envoy.filters.http.ext_proc
                    typed_config:
                      "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExternalProcessor
                      grpc_service:
                        envoy_grpc:
                          cluster_name: epp
                          authority: 127.0.0.1:$EPP_GRPC
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
          explicit_http_config:
            http2_protocol_options: {}
      load_assignment:
        cluster_name: epp
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address: { address: 127.0.0.1, port_value: $EPP_GRPC }
    - name: original_destination_cluster
      type: ORIGINAL_DST
      connect_timeout: 600s
      lb_policy: CLUSTER_PROVIDED
      circuit_breakers:
        thresholds:
          - { max_connections: 10000, max_pending_requests: 10000, max_requests: 10000 }
      original_dst_lb_config:
        use_http_header: true
        http_header_name: x-gateway-destination-endpoint
EOF

# ------------------------------------------------------------ 6. EPP + Envoy
# --pool-name is REQUIRED at v0.11.0 even in file-discovery mode, although the
# docs on main call it optional (found by running the binary locally first).
# --metrics-endpoint-auth defaults to true and authenticates through a
# Kubernetes API that does not exist here.
# --tracing defaults to true and exports OpenTelemetry spans to a collector
# that does not exist here; job 12321494 logged the exporter timing out. A
# background exporter retrying is noise on a process Stage 5 will measure.
"$EPP_BIN" --pool-name epp --config-file "$RUN/epp-config.yaml" \
  --secure-serving=false --metrics-endpoint-auth=false --tracing=false \
  --allow-experimental-plugins \
  --grpc-port "$EPP_GRPC" --grpc-health-port "$EPP_HEALTH" --metrics-port "$EPP_METRICS" \
  > "$RUN/epp.log" 2>&1 &
PIDS+=($!)

"$APPTAINER" exec "$ENVOY_IMG" envoy -c "$RUN/envoy.yaml" --disable-hot-restart \
  --log-level warn > "$RUN/envoy.log" 2>&1 &
PIDS+=($!)

deadline=$(( $(date +%s) + 120 ))
while :; do
  e="$(curl -s --max-time 2 "http://127.0.0.1:$ENVOY_ADMIN/ready" 2>/dev/null)"
  m="$(curl -s --max-time 2 "http://127.0.0.1:$EPP_METRICS/metrics" 2>/dev/null | grep -c '^energy_epp_probe_score_calls_total')"
  [ "$e" = "LIVE" ] && [ "${m:-0}" -ge 1 ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "FATAL: Envoy ready='$e', EPP probe metric lines=$m after 120 s"
    tail -15 "$RUN/epp.log"; tail -15 "$RUN/envoy.log"; exit 1
  fi
  sleep 2
done
grep -o '"body":"EPP starting[^"]*"' "$RUN/epp.log" | head -1
echo "Envoy LIVE, EPP metrics up"

# ------------------------------------------------------------ 7. routed requests
counter() {
  curl -s --max-time 3 "http://127.0.0.1:$EPP_METRICS/metrics" \
    | awk '/^energy_epp_probe_score_calls_total/ {print $2}' | head -1
}
# grep -c prints 0 AND exits 1 on no match, so "|| echo 0" would print 0 twice
# and break the arithmetic below. Capture, then default.
served() { local n; n="$(grep -c 'POST /v1/completions' "$RUN/vllm-$1.log" 2>/dev/null)"; echo "${n:-0}"; }

c0="$(counter)"; s0a="$(served 0)"; s0b="$(served 1)"
ok=0; bad=0
for n in $(seq 1 "$N_REQ"); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 120 \
          -H 'Content-Type: application/json' \
          -d "{\"model\":\"served\",\"prompt\":\"Request $n says\",\"max_tokens\":8}" \
          "http://127.0.0.1:$ENVOY_PORT/v1/completions")"
  if [ "$code" = "200" ]; then ok=$((ok + 1)); else bad=$((bad + 1)); echo "  request $n: HTTP $code"; fi
done
sleep 2
c1="$(counter)"; s1a="$(served 0)"; s1b="$(served 1)"

calls="$(python3 -c "print(int(float('${c1:-0}') - float('${c0:-0}')))")"
d0=$((s1a - s0a)); d1=$((s1b - s0b))

# ------------------------------------------------------------ 8. verdict
[ "$ok" -eq "$N_REQ" ] || fail "only $ok of $N_REQ routed requests returned 200"
[ "$calls" -ge "$N_REQ" ] || fail "probe Score() called $calls times for $N_REQ requests: the plugin is not on the request path"
[ $((d0 + d1)) -eq "$N_REQ" ] || fail "vLLM access logs show $((d0 + d1)) completions for $N_REQ routed requests"
[ "$d0" -gt 0 ] && [ "$d1" -gt 0 ] || fail "requests did not reach both endpoints (vllm-0=$d0, vllm-1=$d1)"

{
  echo "envoy_version=$ENVOY_VER"
  echo "epp_sha256=$EPP_SHA"
  echo "router=llm-d-router v0.11.0 (static, CGO_ENABLED=0, cross-compiled)"
  echo "requests=$N_REQ ok=$ok bad=$bad"
  echo "probe_score_calls=$calls"
  echo "served_vllm0=$d0 served_vllm1=$d1"
  if [ "${#FAILS[@]}" -eq 0 ]; then echo "VERDICT=PASS"; else
    echo "VERDICT=FAIL"; printf 'reason=%s\n' "${FAILS[@]}"; fi
} | tee "$RUN/smoke-verdict.txt"

[ "${#FAILS[@]}" -eq 0 ] && exit 0 || exit 1
