#!/usr/bin/env bash
# Lists every result directory and Slurm log on the cluster, one name per line,
# so a local copy can be diffed against it.
set -u
R="$HOME/energy-epp"
for d in "$R"/results/*/; do echo "results/$(basename "$d")"; done
for f in "$R"/scripts/*.out; do [ -f "$f" ] && echo "slurm-logs/$(basename "$f")"; done
