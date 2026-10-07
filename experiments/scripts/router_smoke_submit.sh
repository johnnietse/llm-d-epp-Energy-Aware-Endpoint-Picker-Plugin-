#!/usr/bin/env bash
# Cluster-side submitter for router_smoke.sbatch. Pre-flights everything that
# can be checked from the login node, which cannot run containers (user
# namespaces are disabled there), so the Envoy version is checked in-job.
#   EPP_SHA=<sha256> bash router_smoke_submit.sh
set -u
cd "$HOME/energy-epp/scripts" || exit 1
ROOT="$HOME/energy-epp"
BIN="$ROOT/bin/epp-energy-v0.11.0"

EXISTING="$(squeue -h -u "$(id -un)" -n router-smoke -o '%i' 2>/dev/null | tr '\n' ' ')"
[ -z "${EXISTING// /}" ] || { echo "REFUSING: router-smoke already queued: $EXISTING"; exit 1; }

bash -n router_smoke.sbatch || { echo "FATAL: router_smoke.sbatch syntax"; exit 1; }
for f in "$ROOT/images/vllm-v0.30.0.sif" "$ROOT/images/envoy.sif"; do
  [ -f "$f" ] || { echo "FATAL: missing $f"; exit 1; }
done
[ -x "$BIN" ] || { echo "FATAL: $BIN missing or not executable"; exit 1; }
GOT="$(sha256sum "$BIN" | cut -d' ' -f1)"
if [ -n "${EPP_SHA:-}" ] && [ "$GOT" != "$EPP_SHA" ]; then
  echo "FATAL: $BIN sha256 $GOT does not match the local build $EPP_SHA"; exit 1
fi
echo "pre-flight: binary sha256 $GOT matches the local build"
file "$BIN" 2>/dev/null | grep -q 'statically linked' \
  && echo "pre-flight: binary is statically linked" \
  || { echo "FATAL: binary is not statically linked; it may not run on the compute node"; exit 1; }
"$BIN" --help >/dev/null 2>&1 \
  && echo "pre-flight: binary executes on the login node" \
  || echo "WARN: binary did not run on the login node (--help); continuing, compute node may differ"

export EPP_SHA="${EPP_SHA:-$GOT}"
J="$(sbatch --parsable --export=ALL router_smoke.sbatch 2>&1)" || { echo "SUBMIT FAILED: $J"; exit 1; }
echo "SUBMITTED $J"
sleep 3
squeue -h -j "$J" -o '%.12i %.14j %.9T %.9M %R'
