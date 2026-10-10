#!/usr/bin/env bash
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"; HOST="hpc6081@login.cac.queensu.ca"
timeout 60 ssh -S "$SOCK" -o BatchMode=yes "$HOST" 'scontrol show reservation 2>&1 | grep -E "ReservationName|StartTime|Nodes=" | head -20; echo ---; squeue -u hpc6081 -o "%.12i %.12j %.9T %.9M %.40R"; echo ---; sinfo -n frnt149,frnt154,frnt155 -o "%N %T %E"'
