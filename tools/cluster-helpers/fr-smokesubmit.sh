#!/usr/bin/env bash
# Ships the locally cross-compiled EPP binary and the smoke-test scripts to the
# cluster, then submits router_smoke.sbatch. SUBMIT ONLY.
#
# The binary is built here, not on the cluster, because the login node has no
# Go toolchain and cannot run containers. Its sha256 travels with it and the
# job refuses to run a binary that does not match.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
REPO="/mnt/c/Users/Johnnie/llm-d-epp-energy"
SRC="$REPO/experiments/scripts"
BIN="$REPO/router-plugin/bin/epp-linux-amd64"

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
[ -f "$BIN" ] || { echo "no local binary at $BIN; build it first" >&2; exit 2; }
SHA="$(sha256sum "$BIN" | cut -d' ' -f1)"
echo "local binary sha256 $SHA"

ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "mkdir -p energy-epp/bin" || exit 1
scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 \
    "$BIN" "$HOST:energy-epp/bin/epp-energy-v0.11.0" || exit 1
ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "chmod 750 energy-epp/bin/epp-energy-v0.11.0" || exit 1
for f in router_smoke.sbatch router_smoke_submit.sh; do
  scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 \
      "$SRC/$f" "$HOST:energy-epp/scripts/" || exit 1
done

ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
  "EPP_SHA=$SHA bash energy-epp/scripts/router_smoke_submit.sh"
