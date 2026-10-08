#!/usr/bin/env bash
# Runs fr-cmd.sh on Frontenac over the shared SSH connection held by
# frontenac-connect-hpc6081.sh. No inline quoting, because passing quoted
# strings through wsl.exe from Windows mangles them.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"

if [ ! -S "$SOCK" ]; then
  echo "NO CONTROL SOCKET at $SOCK - the connect tab is not authenticated" >&2
  exit 2
fi

ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 -O check "$HOST" || { echo "control master not alive" >&2; exit 3; }
exec ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" bash -s < /mnt/c/Users/Johnnie/fr-cmd.sh
