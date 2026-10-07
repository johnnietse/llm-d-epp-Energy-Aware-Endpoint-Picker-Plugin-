#!/usr/bin/env bash
# Prints the outcome of a router_overhead job.
set -u
J="${1:?jobid}"; R="$HOME/energy-epp"
sacct -X -n -j "$J" --format=JobID,State%12,ExitCode,Elapsed,NodeList 2>/dev/null
L="$(ls "$R"/scripts/router-overhead-"$J"-*.out 2>/dev/null | head -1)"
echo "=== job log ==="; [ -n "$L" ] && grep -vE '^\s*$' "$L" | tail -60
