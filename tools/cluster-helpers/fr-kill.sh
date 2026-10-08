#!/usr/bin/env bash
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" "ps -u \$(id -un) -o pid,etime,stat,args | head -40"
