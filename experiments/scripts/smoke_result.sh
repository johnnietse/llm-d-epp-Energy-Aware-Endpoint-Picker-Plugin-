#!/usr/bin/env bash
# Prints the outcome of a router smoke job: Slurm state, the job log, the
# verdict file, and the EPP/Envoy log lines that matter if it failed.
set -u
J="${1:?jobid}"
R="$HOME/energy-epp"
echo "=== sacct ==="
sacct -X -n -j "$J" --format=JobID,State%14,ExitCode,Elapsed,NodeList 2>/dev/null
L="$(ls "$R"/scripts/router-smoke-"$J"-*.out 2>/dev/null | head -1)"
echo; echo "=== job log: ${L:-none} ==="
[ -n "$L" ] && grep -vE '^\s*$' "$L" | tail -40
V="$R/results/router-smoke-$J/smoke-verdict.txt"
echo; echo "=== verdict ==="; cat "$V" 2>/dev/null || echo "(no verdict file)"
echo; echo "=== EPP log: errors and key lines ==="
grep -E '"ERROR"|EPP starting|file-discovery mode|panic' "$R/results/router-smoke-$J/epp.log" 2>/dev/null \
  | sed -E 's/"timestamp":"[^"]*",//' | cut -c1-240 | head -8
echo; echo "=== Envoy log tail ==="
tail -6 "$R/results/router-smoke-$J/envoy.log" 2>/dev/null
