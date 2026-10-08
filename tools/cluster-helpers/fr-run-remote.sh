#!/usr/bin/env bash
# Generic: push one script from experiments/scripts and run it on the cluster.
#
#   bash fr-run-remote.sh <script-name> [args...]
#
# Exists because multi-line "wsl.exe -- bash -c '...'" is corrupted in transit:
# every newline becomes two double-quote characters, so variable assignments on
# one line merge into the next and read back empty. That produced three
# different mystery failures in this session, the worst of which hung for 110 s
# because ssh silently fell back from the multiplexed socket to a fresh
# connection and waited at an invisible password prompt.
#
# A script file has no argv to mangle. Everything goes through here now.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
[ "$#" -ge 1 ] || { echo "usage: fr-run-remote.sh <script-name> [args...]" >&2; exit 2; }

NAME="$1"; shift
[ -f "$SRC/$NAME" ] || { echo "no such script: $SRC/$NAME" >&2; exit 2; }

scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 \
    "$SRC/$NAME" "$HOST:energy-epp/scripts/" || exit 1

case "$NAME" in
  *.py) ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
          python3 "energy-epp/scripts/$NAME" "$@" ;;
  *)    ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" \
          env HF_HOME="\$HOME/energy-epp/.hf" \
          bash "energy-epp/scripts/$NAME" "$@" ;;
esac
