#!/usr/bin/env bash
# Pushes the analysis script and prints the gated verdict for the two runs
# named as arguments (job ids).
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
for f in stage2_analyse.py provisional_report.py policy_harness.py; do
  scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$SRC/$f" "$HOST:energy-epp/scripts/" || exit 1
done

A="$1"; B="$2"
ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" python3 energy-epp/scripts/stage2_analyse.py \
  "energy-epp/results/stage2-$A" "energy-epp/results/stage2-$B"
