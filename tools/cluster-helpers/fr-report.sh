#!/usr/bin/env bash
# Pushes the analysis scripts and prints the provisional view of the two
# completed 4-GPU trials. File-by-path; stdin-fed and inline-quoted remote
# scripts both failed silently earlier in this session.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
for f in provisional_report.py stage2_analyse.py policy_harness.py; do
  scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$SRC/$f" "$HOST:energy-epp/scripts/" || exit 1
done

ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" python3 energy-epp/scripts/provisional_report.py \
  energy-epp/results/stage2-12304118 energy-epp/results/stage2-12304119
