#!/usr/bin/env bash
# Lists cluster result dirs and scripts state, never prompting.
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
timeout 60 ssh -S "$SOCK" -o BatchMode=yes "$HOST" 'ls -1 energy-epp/results; echo "--- sbatch scripts"; ls -1 energy-epp/scripts/*.sbatch | xargs -n1 basename; echo "--- quota"; quota -s 2>/dev/null | tail -2; df -h ~ | tail -1'
