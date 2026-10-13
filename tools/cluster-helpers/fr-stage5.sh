#!/usr/bin/env bash
# Ships the Stage 5 materials and submits ONE trial (or a dry run). SUBMIT ONLY.
#
#   bash fr-stage5.sh <mixed|homog> <seed> [RUN_TAG] [VAR=value ...]
#   bash fr-stage5.sh mixed 990 stage5dry RATES=200:600 DURATION=30 WARMUP_S=15
# (separate levels with ":", since sbatch --export splits on commas)
#
# Nodes are pinned (amendment B9): mixed = frnt154 (A100) + frnt149 (RTX 6000),
# homog = frnt155. If a pinned node is unavailable the job waits; substituting
# a node is a deviation (D6). The EPP's sha256 travels with it and the job
# refuses any other binary.
set -u
FLEET="${1:?mixed|homog}"; SEED="${2:?seed}"; TAG="${3:-stage5}"; shift 3 2>/dev/null || shift $#
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"; HOST="hpc6081@login.cac.queensu.ca"
REPO="/mnt/c/Users/Johnnie/llm-d-epp-energy"
BIN="$REPO/router-plugin/bin/epp-linux-amd64"
[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
SHA="$(sha256sum "$BIN" | cut -d' ' -f1)"
bash -n "$REPO/experiments/scripts/stage5_trial.sbatch" || exit 1
EXTRA=""; for kv in "$@"; do case "$kv" in *=*) EXTRA="$EXTRA,$kv" ;; esac; done
CP="scp -q -o ControlPath=$SOCK -o BatchMode=yes -o ConnectTimeout=10"
RUNR="ssh -S $SOCK -o BatchMode=yes -o ConnectTimeout=10 $HOST"
$RUNR "mkdir -p energy-epp/bin energy-epp/curves energy-epp/scripts" || exit 1
$CP "$BIN" "$HOST:energy-epp/bin/epp-energy-v0.11.0" || exit 1
$CP "$REPO/experiments/scripts/policy_harness.py" "$REPO/experiments/scripts/multinode_energy.py" \
    "$REPO/experiments/scripts/node_energy_sampler.py" "$REPO/experiments/scripts/stage5_trial.sbatch" \
    "$REPO/router-plugin/configs/epp-config.sh" "$HOST:energy-epp/scripts/" || exit 1
$CP "$REPO/router-plugin/curves/a100.json" "$REPO/router-plugin/curves/rtx6000.json" "$HOST:energy-epp/curves/" || exit 1
case "$FLEET" in
  mixed) RES="-w frnt154 --nodes=1 --exclusive --mem=0 --gres=gpu:a100:4 : -w frnt149 --nodes=1 --exclusive --mem=0 --gres=gpu:rtx6000:4" ;;
  homog) RES="-w frnt155 --nodes=1 --exclusive --mem=0 --gres=gpu:rtx6000:8" ;;
  *) echo "FLEET must be mixed or homog"; exit 1 ;;
esac
$RUNR "cd energy-epp && echo cluster sha256 \$(sha256sum bin/epp-energy-v0.11.0 | cut -d' ' -f1) && cd scripts && \
  sbatch --parsable --export=ALL,EPP_SHA=$SHA,FLEET=$FLEET,SEED=$SEED,RUN_TAG=$TAG$EXTRA $RES stage5_trial.sbatch"
