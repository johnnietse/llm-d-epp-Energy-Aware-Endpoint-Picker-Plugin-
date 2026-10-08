#!/usr/bin/env bash
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
BASE="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments"

pull() {  # $1 = jobid, $2 = dirname
  local d="$BASE/$2"
  mkdir -p "$d"
  for f in h1.csv fit.txt instruments.txt idle_bare.txt sweep.log; do
    scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST:energy-epp/results/h1-$1/$f" "$d/" 2>/dev/null \
      && echo "  got $2/$f" || echo "  skip $2/$f"
  done
}

echo "L4 (12303303):"; pull 12303303 h1-2026-10-03-frnt201-l4
echo "7B (12303308):"; pull 12303308 h1-2026-10-03-frnt109-7b
