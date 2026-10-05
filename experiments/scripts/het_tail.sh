set -u
J="${1:?jobid}"
L="$HOME/energy-epp/scripts/stage2-het-$J.out"
echo "=== last 45 lines of the job log ==="
tail -45 "$L" 2>/dev/null
echo
echo "=== sacct detail incl. reason ==="
sacct -j "$J" --format=JobID,State,ExitCode,Reason,Elapsed,NodeList,DerivedExitCode -P 2>/dev/null | head -8
echo
echo "=== harness log, if Pass A started ==="
tail -20 "$HOME/energy-epp/results/stage2het-$J/harness.log" 2>/dev/null || echo "(no harness.log - Pass A never produced output)"
