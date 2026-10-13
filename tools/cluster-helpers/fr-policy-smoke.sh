#!/usr/bin/env bash
# Ships what the Stage 4 policy smoke test needs, then submits it. SUBMIT ONLY.
#   bash fr-policy-smoke.sh
# Sends: the locally built EPP (its sha256 travels with it and the job refuses
# any other), policy_harness.py (router mode, traffic window), the arm config
# generator, the exported curves, and policy_smoke.sbatch.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"; HOST="hpc6081@login.cac.queensu.ca"
REPO="/mnt/c/Users/Johnnie/llm-d-epp-energy"
BIN="$REPO/router-plugin/bin/epp-linux-amd64"
[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
[ -f "$BIN" ] || { echo "build first: bash router-plugin/build.sh" >&2; exit 2; }
SHA="$(sha256sum "$BIN" | cut -d' ' -f1)"
echo "local EPP sha256 $SHA"
bash -n "$REPO/experiments/scripts/policy_smoke.sbatch" || { echo "syntax error in policy_smoke.sbatch"; exit 1; }
CP="scp -q -o ControlPath=$SOCK -o BatchMode=yes -o ConnectTimeout=10"
RUNR="ssh -S $SOCK -o BatchMode=yes -o ConnectTimeout=10 $HOST"
$RUNR "mkdir -p energy-epp/bin energy-epp/curves energy-epp/scripts" || exit 1
$CP "$BIN" "$HOST:energy-epp/bin/epp-energy-v0.11.0" || exit 1
$CP "$REPO/experiments/scripts/policy_harness.py" "$REPO/experiments/scripts/policy_smoke.sbatch" \
    "$REPO/router-plugin/configs/epp-config.sh" "$HOST:energy-epp/scripts/" || exit 1
$CP "$REPO/router-plugin/curves/a100.json" "$REPO/router-plugin/curves/rtx6000.json" \
    "$HOST:energy-epp/curves/" || exit 1
$RUNR "cd energy-epp && chmod 750 bin/epp-energy-v0.11.0 && \
  echo cluster sha256 \$(sha256sum bin/epp-energy-v0.11.0 | cut -d' ' -f1) && \
  grep -c 'def apply_energy_window' scripts/policy_harness.py && \
  test -z \"\$(squeue -h -u \$(id -un) -n policy-smoke -o %i)\" || { echo REFUSING: policy-smoke already queued; exit 1; }; \
  cd scripts && sbatch --parsable --export=ALL,EPP_SHA=$SHA policy_smoke.sbatch"
