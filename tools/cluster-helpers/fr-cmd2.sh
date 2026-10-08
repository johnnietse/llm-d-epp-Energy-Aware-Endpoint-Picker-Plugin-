set -u
J="12304125 12304126 12304127 12304128"
echo "waiting for the four curve sweeps"
for i in $(seq 1 200); do
  n="$(squeue -h -j "$(echo $J | tr ' ' ',')" 2>/dev/null | wc -l)"
  [ "$n" -eq 0 ] && { echo "all curve sweeps finished"; break; }
  sleep 30
done
sacct -n -X -j "$(echo $J | tr ' ' ',')" --format=JobID,State,Elapsed,ExitCode,NodeList -P 2>/dev/null
echo
for j in $J; do
  L="$HOME/energy-epp/scripts/h1-sweep-$j.out"
  echo "### $j: $(grep -m1 -oE 'energy-counter python: .*' "$L" 2>/dev/null | cut -c1-60)"
  grep -E "FATAL|no host python" "$L" 2>/dev/null | head -2
done
echo
python3 "$HOME/energy-epp/scripts/curve_report.py" "$HOME/energy-epp/results" \
  --jobs 12304125 12304126 12304127 12304128
