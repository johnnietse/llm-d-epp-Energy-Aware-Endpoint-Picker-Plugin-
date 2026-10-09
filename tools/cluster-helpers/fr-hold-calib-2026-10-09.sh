#!/usr/bin/env bash
# hold|release the two calibration jobs. Usage: frhold.sh hold|release
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
case "$1" in hold|release) ;; *) echo "usage: hold|release"; exit 1 ;; esac
timeout 60 ssh -S "$SOCK" -o BatchMode=yes "$HOST" "scontrol $1 12324890 12324891; sleep 2; squeue -u hpc6081 -o '%.12i %.12j %.9T %.9M %.28R'"
