#!/usr/bin/env bash
# Checks the shared Frontenac SSH connection without ever prompting.
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
ssh -S "$SOCK" -O check "$HOST" 2>&1
timeout 30 ssh -S "$SOCK" -o BatchMode=yes "$HOST" 'hostname; date; squeue -u hpc6081 -h | wc -l | sed "s/^/jobs queued: /"' 2>&1
