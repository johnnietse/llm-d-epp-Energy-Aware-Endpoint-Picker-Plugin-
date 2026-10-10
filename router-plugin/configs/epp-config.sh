#!/usr/bin/env bash
# Writes the EPP config for one Stage 5 arm to stdout.
#
#   ARM=energy_consolidate ENDPOINTS=/run/endpoints.yaml CURVE_DIR=/run/curves \
#   SEED=501 HEADROOM=0 MAX_INFLIGHT=256 SLO_S=2.0 bash epp-config.sh
#
# Every rule parameter is required from the caller, so a run cannot inherit a
# value nobody wrote down (pre-registration section 15: h = 0, cap 256,
# SLO 2.0 s, seeds 501-525 / 601-625).
#
# Arms built from this project's plugins (energy_consolidate, energy_greedy,
# slo_packing, round_robin, least_loaded):
#   - energy-epp-policy-scorer decides, energy-epp-seeded-random-picker breaks
#     ties from SEED (amendment B5);
#   - inflight-load-producer supplies the router's own in-flight count, which
#     needs no metrics polling (plan 12.14b), so dataLayer.injectDefaults is
#     false and nothing scrapes vLLM;
#   - the saturation detector is set explicitly to a concurrency detector with
#     limits no endpoint can reach. v0.11.0 injects a saturation detector into
#     every profile as a FILTER whether or not flow control is enabled; its
#     default (utilization-detector) drops endpoints with stale metrics, and
#     with no scraping every endpoint is stale. It is inert today only through
#     its fail-open fallback. This one is inert by construction: it admits an
#     endpoint while in-flight < 1e9.
# random: upstream random-picker, as registered (section 4). It is unseeded.
#
# stock_llmd and llmd_latency_least are NOT generated here. Their configs are
# materials-addendum decisions (section 10 item 5, amendment B7).
set -eu
: "${ARM:?}" "${ENDPOINTS:?}" "${SEED:?}" "${HEADROOM:?}" "${MAX_INFLIGHT:?}" "${SLO_S:?}"

common_head() {
cat <<EOF
plugins:
  - name: file-disc
    type: file-discovery
    parameters:
      path: $ENDPOINTS
      watchFile: false
  - name: inflight
    type: inflight-load-producer
  - name: inert-saturation
    type: concurrency-detector
    parameters:
      maxConcurrency: 1000000000
      maxTokenConcurrency: 1000000000000
  - name: single-profile
    type: single-profile-handler
EOF
}
common_tail() {
cat <<EOF
flowControl:
  saturationDetector:
    pluginRef: inert-saturation
dataLayer:
  injectDefaults: false
  discovery:
    endpoints:
      pluginRef: file-disc
EOF
}

case "$ARM" in
  energy_consolidate|energy_greedy|slo_packing)
    : "${CURVE_DIR:?}"
    CURVES="{\"a100\": \"$CURVE_DIR/a100.json\", \"rtx6000\": \"$CURVE_DIR/rtx6000.json\"}" ;;
  round_robin|least_loaded) CURVES="{}" ;;
  random) CURVES="" ;;
  *) echo "epp-config.sh: no generated config for arm '$ARM'" >&2; exit 2 ;;
esac

common_head
if [ "$ARM" = random ]; then
cat <<EOF
  - name: picker
    type: random-picker
schedulingProfiles:
  - name: default
    plugins:
      - pluginRef: picker
EOF
else
cat <<EOF
  - name: policy
    type: energy-epp-policy-scorer
    parameters:
      policy: $ARM
      curves: $CURVES
      sloSeconds: $SLO_S
      headroom: $HEADROOM
      maxInflight: $MAX_INFLIGHT
  - name: picker
    type: energy-epp-seeded-random-picker
    parameters:
      seed: $SEED
schedulingProfiles:
  - name: default
    plugins:
      - pluginRef: policy
        weight: 1
      - pluginRef: picker
EOF
fi
common_tail
