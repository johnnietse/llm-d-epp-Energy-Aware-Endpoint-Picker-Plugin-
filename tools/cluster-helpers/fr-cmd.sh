set -u
J1=12304137; J2=12304138
for i in $(seq 1 220); do
  n="$(squeue -h -j "$J1,$J2" 2>/dev/null | wc -l)"
  [ "$n" -eq 0 ] && { echo "both finished"; break; }
  sleep 30
done
sacct -n -X -j "$J1,$J2" --format=JobID,State,Elapsed,ExitCode,NodeList -P 2>/dev/null
for J in $J1 $J2; do
  L="$(ls -t "$HOME"/energy-epp/scripts/stage2-real-$J-*.out 2>/dev/null | head -1)"
  echo "### $J cells=$(grep -c 'J/req' "$L" 2>/dev/null) client_limited=$(grep -c 'CLIENT LIMITED' "$L" 2>/dev/null) ungrounded=$(grep -c 'UNGROUNDED ROUTING' "$L" 2>/dev/null)"
  grep -m1 -E "curve for Quadro" "$L" 2>/dev/null | sed 's/^/    /'
  grep -A 5 "perturbation check: full telemetry" "$L" 2>/dev/null | grep -E "energy difference|VERDICT" | sed 's/^/    /'
done
echo
echo "############## GATED TWO-TRIAL VERDICT ##############"
python3 "$HOME/energy-epp/scripts/stage2_analyse.py" \
  "$HOME/energy-epp/results/stage2-$J1" "$HOME/energy-epp/results/stage2-$J2"
