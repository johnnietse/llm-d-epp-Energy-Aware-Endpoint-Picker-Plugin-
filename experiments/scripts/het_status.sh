#!/usr/bin/env bash
# One-shot status of the heterogeneous Stage 2 trials. Returns immediately -
# for waiting, use het_watch.sh, which is bounded.
#
# A file rather than an inline ssh command string because quoting a remote
# `squeue -u $USER` through wsl.exe and ssh mangled it to `Invalid user:
# ohnnie`. Plan section 3.4 lists that family of corruption; a script file has
# no quoting layer to lose.
set -u
cd "$HOME/energy-epp/scripts" 2>/dev/null || true
ME="$(id -un)"

echo "=== queue for $ME ==="
squeue -u "$ME" -o '%.12i %.12j %.9T %.9M %.11l %.6D %R' 2>/dev/null

echo
echo "=== recent stage2-het jobs ==="
sacct -u "$ME" --name=stage2-het --starttime now-1days \
      --format=JobID%20,State%12,ExitCode%8,Elapsed%10,Start%20 -n 2>/dev/null \
  | grep -v '\.batch\|\.extern\|\.[0-9]*  *COMPLETED' | head -20

echo
# One policies-rate<N>.json per load level, each holding every policy's cell
# for that rate - five rates by five policies is the full 25-cell sweep. An
# earlier version of this script globbed cell-*.json, which matches nothing,
# so it reported "0 cell file(s)" for runs that were complete. Same class of
# error as the stale staging check: a status line that is wrong in the
# reassuring direction is worse than no status line.
echo "=== results present (policies-rate*.json per load level) ==="
for d in "$HOME"/energy-epp/results/stage2het-*; do
  [ -d "$d" ] || continue
  n="$(find "$d" -maxdepth 1 -name 'policies-rate*.json' 2>/dev/null | wc -l)"
  g="$(grep -l 'goodput_per_joule' "$d"/policies-rate*.json 2>/dev/null | wc -l)"
  printf '  %-28s %s/5 rate file(s), %s with energy\n' \
         "$(basename "$d")" "$n" "$g"
done
