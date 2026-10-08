#!/usr/bin/env bash
# Submits the GPU-count-matched homogeneous control on the 8x RTX 6000 node.
# SUBMIT ONLY: returns as soon as the job id is known.
#
#   bash fr-realsubmit.sh [seed] [node] [rates]
#
# rates overrides real_submit.sh's default ladder (the heterogeneous one,
# 200-600 req/s). That default is right for matched offered load but
# saturates 8x RTX 6000 above ~300 req/s, where goodput per joule fell to
# ~0.0001 in job 12319815 and the cells carried no information.
#
# Defaults to seed 11, which matches heterogeneous replication trial one, and
# node frnt155, the cluster's only 8x RTX 6000. real_submit.sh does the
# pre-flight: node state and GPU count, staging present, weights resolve, and
# load levels inside the generator's proven range.
#
# Values travel as a single-line VAR=value prefix. Never as a multi-line
# `wsl.exe -- bash -c`: that form turns newlines into double-quote pairs and has
# broken this project five times, most recently reading $USER back as "ohnnie".
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }

SEED="${1:-11}"
NODE="${2:-frnt155}"
RATES="${3:-}"
case "$RATES" in *[!0-9,.]*) echo "rates must be a comma list of numbers, got '$RATES'" >&2; exit 2 ;; esac
case "$SEED" in '' | *[!0-9]*) echo "seed must be numeric, got '$SEED'" >&2; exit 2 ;; esac

for f in stage2_real.sbatch policy_harness.py real_submit.sh; do
  scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 \
      "$SRC/$f" "$HOST:energy-epp/scripts/" || exit 1
done

ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
  "SEED=$SEED NODE=$NODE ${RATES:+RATES=$RATES} bash energy-epp/scripts/real_submit.sh"
