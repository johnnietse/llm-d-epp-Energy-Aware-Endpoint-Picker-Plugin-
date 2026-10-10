#!/usr/bin/env bash
# Starts the built EPP once per generated arm config, with 8 labelled endpoints
# that nothing listens on, and reports whether the router accepted the config
# and what each scheduling profile finally contains after v0.11.0 injects its
# defaults. Linux only (the binary is linux/amd64); runs in WSL. No GPU, no
# network beyond loopback.
#
#   bash router-plugin/configs/check-configs.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="$HERE/../bin/epp-linux-amd64"
[ -x "$BIN" ] || { echo "build first: bash router-plugin/build.sh"; exit 2; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cp "$HERE/../curves/"*.json "$T/"
{
  echo "endpoints:"
  for i in 0 1 2 3 4 5 6 7; do
    gpu=a100; [ "$i" -ge 4 ] && gpu=rtx6000
    printf '  - name: vllm-%d\n    address: "127.0.0.1"\n    port: "%d"\n    labels:\n      energy-epp/index: "%d"\n      energy-epp/gpu-type: "%s"\n' \
      "$i" $((18000 + i)) "$i" "$gpu"
  done
} > "$T/endpoints.yaml"

fail=0
for arm in energy_consolidate energy_greedy slo_packing round_robin least_loaded random; do
  ARM=$arm ENDPOINTS="$T/endpoints.yaml" CURVE_DIR="$T" SEED=501 HEADROOM=0 \
    MAX_INFLIGHT=256 SLO_S=2.0 bash "$HERE/epp-config.sh" > "$T/$arm.yaml" || { fail=1; continue; }
  "$BIN" --pool-name check --config-file "$T/$arm.yaml" --allow-experimental-plugins \
    --secure-serving=false --metrics-endpoint-auth=false --tracing=false \
    --grpc-port 19001 --grpc-health-port 19002 --metrics-port 19003 -v 2 \
    > "$T/$arm.log" 2>&1 &
  pid=$!
  sleep 6
  if kill -0 "$pid" 2>/dev/null; then state=running; else state=EXITED; fail=1; fi
  m="$(curl -s --max-time 2 http://127.0.0.1:19003/metrics | grep -c '^energy_epp_policy_picks_total')"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  prof="$(grep -oE '\{Filters: \[[^]]*\], Scorers: \[[^]]*\], Picker: [^}"]*' "$T/$arm.log" | head -1)"
  err="$(grep -iE '"level":"error"|error loading|failed to' "$T/$arm.log" | grep -v 'connection refused' | head -2 | cut -c1-200)"
  printf '%-20s %-8s picks-series=%s\n  profile: %s\n' "$arm" "$state" "$m" "${prof:-<not logged>}"
  [ -n "$err" ] && { echo "  errors: $err"; }
  [ "$state" = EXITED ] && tail -5 "$T/$arm.log" | cut -c1-240
done
exit $fail
