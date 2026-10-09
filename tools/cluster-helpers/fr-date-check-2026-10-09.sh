#!/usr/bin/env bash
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
timeout 60 ssh -S "$SOCK" -o BatchMode=yes "$HOST" 'sacct -X -n -j 12302427,12302428 -S 2026-01-01 -o JobID,Start,End,State; ls -ld --time-style=long-iso energy-epp/results/12302427 energy-epp/results/h1-12302437; squeue -u hpc6081 -o "%.10i %.12j %.8T %.10M %.22R"'
