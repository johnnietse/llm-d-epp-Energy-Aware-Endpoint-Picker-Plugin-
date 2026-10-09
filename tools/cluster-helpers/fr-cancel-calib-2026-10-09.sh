#!/usr/bin/env bash
# Cancels the two held one-seed calibration jobs (never ran, no records).
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
timeout 60 ssh -S "$SOCK" -o BatchMode=yes "$HOST" "scancel 12324890 12324891; sleep 3; sacct -X -n -j 12324890,12324891 -o JobID,JobName,State,Elapsed"
