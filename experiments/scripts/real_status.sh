#!/usr/bin/env bash
# Status of the homogeneous control runs. het_status.sh only knows about
# stage2-het jobs and stage2het-* result directories, so the frnt155 control
# was invisible to it and to the watcher built on it.
set -u
ME="$(id -un)"
R="$HOME/energy-epp"

echo "=== recent stage2-real jobs ==="
sacct -u "$ME" --name=stage2-real --starttime now-2days \
      --format=JobID%14,State%18,ExitCode%8,Elapsed%10,NodeList%12,Start%20 -n 2>/dev/null \
  | grep -v '\.batch\|\.extern\|\.[0-9]* ' | head -10

echo
echo "=== stage2-* result directories ==="
for d in "$R"/results/stage2-*; do
  [ -d "$d" ] || continue
  n="$(find "$d" -maxdepth 1 -name 'policies-rate*.json' 2>/dev/null | wc -l)"
  g="$(grep -l 'goodput_per_joule' "$d"/policies-rate*.json 2>/dev/null | wc -l)"
  printf '  %-24s %s rate file(s), %s with energy\n' "$(basename "$d")" "$n" "$g"
done | tail -12

echo
echo "=== tail of the newest stage2-real log ==="
L="$(ls -t "$R"/scripts/stage2-real-*.out 2>/dev/null | head -1)"
if [ -n "$L" ]; then
  echo "  $(basename "$L")"
  tail -18 "$L" | sed 's/^/    /'
else
  echo "  no stage2-real log found"
fi
