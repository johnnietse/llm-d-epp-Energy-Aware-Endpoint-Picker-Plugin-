#!/usr/bin/env bash
# Submits the heterogeneous Stage 2 run. SUBMIT ONLY - it returns as soon as
# the job id is known.
#
#   bash fr-hetsubmit.sh [seed] [dep-jobid]
#
# Why split from watching: the previous combined script was killed with exit
# 143 because its internal watch loop could run 100 iterations of 15 s (25
# minutes) while the outer `timeout` allowed 590 s. SIGTERM, no result, and the
# job left running untracked. An outer timeout shorter than a script's own wait
# loop is a guaranteed kill, so the wait now lives in fr-hetwatch.sh where its
# duration is the only thing that matters.
#
# het_submit.sh refuses to submit if a het job is already queued or running,
# because two pending duplicates (12304895 and 12304896) happened exactly once
# by having two submitters in flight. Pass dep-jobid to chain behind a queued
# job instead: a job held by --dependency cannot race the one it waits for.
#
# seed and dep travel as a single-line remote command string. Never build this
# as a multi-line `wsl.exe -- bash -c`: that form turns every newline into two
# double-quote characters, which has broken this project four times.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }

SEED="${1:-7}"
DEP="${2:-}"
case "$SEED" in '' | *[!0-9]*) echo "seed must be numeric, got '$SEED'" >&2; exit 2 ;; esac
case "$DEP" in *[!0-9]*) echo "dep must be numeric, got '$DEP'" >&2; exit 2 ;; esac

for f in stage2_het.sbatch node_energy_sampler.py multinode_energy.py \
         policy_harness.py het_submit.sh; do
  scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 \
      "$SRC/$f" "$HOST:energy-epp/scripts/" || exit 1
done

ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
  "SEED=$SEED DEP=$DEP bash energy-epp/scripts/het_submit.sh"
