set -u
J="${1:?jobid}"
R="$HOME/energy-epp/results/stage2het-$J"
echo "=== samples directory ==="
ls -la "$R/samples/" 2>/dev/null || echo "(no samples dir)"
echo
echo "=== sampler launch lines from the job log ==="
grep -nE "starting energy sampler|sampler .*line|FATAL: sampler" \
  "$HOME/energy-epp/scripts/stage2-het-$J.out" 2>/dev/null | sed 's/^/  /'
echo
echo "=== sampler stderr logs (size and content) ==="
for f in "$R"/sampler-*.log; do
  [ -f "$f" ] || continue
  echo "  $(basename "$f"): $(stat -c%s "$f") bytes"
  head -5 "$f" 2>/dev/null | sed 's/^/     /'
done
echo
echo "=== how many concurrent steps did Slurm actually allow? ==="
sacct -j "$J" --format=JobID,JobName,State,Elapsed,ExitCode -P 2>/dev/null \
  | awk -F'|' 'NR>1 && $1 ~ /\./ {print "  " $0}' | tail -14
echo
echo "=== does the sampler even run here? direct test on the login node ==="
echo "(expected to fail - no GPU on login - but shows whether the script is callable)"
python3 "$HOME/energy-epp/scripts/node_energy_sampler.py" --help 2>&1 | head -5
