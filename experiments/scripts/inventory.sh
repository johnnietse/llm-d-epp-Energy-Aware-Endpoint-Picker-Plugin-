#!/usr/bin/env bash
# Inventories everything on the cluster that is a measurement record, with
# sizes, so a fetch can be planned rather than guessed at.
set -u
R="$HOME/energy-epp"

echo "=== result directories, size and file count ==="
printf '%-34s %10s %7s %s\n' DIR SIZE FILES NEWEST
for d in "$R"/results/*/; do
  [ -d "$d" ] || continue
  sz="$(du -sh "$d" 2>/dev/null | cut -f1)"
  n="$(find "$d" -type f 2>/dev/null | wc -l)"
  nw="$(find "$d" -type f -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort | tail -1)"
  printf '%-34s %10s %7s %s\n' "$(basename "$d")" "$sz" "$n" "$nw"
done

echo
echo "=== loose result files directly under results/ ==="
find "$R/results" -maxdepth 1 -type f -printf '%f %s\n' 2>/dev/null | head -20

echo
echo "=== slurm job logs in scripts/ ==="
find "$R/scripts" -maxdepth 1 -name '*.out' -printf '%f %s\n' 2>/dev/null \
  | sort | head -40
echo "  total .out files: $(find "$R/scripts" -maxdepth 1 -name '*.out' | wc -l)"
echo "  total .out bytes: $(find "$R/scripts" -maxdepth 1 -name '*.out' -printf '%s\n' 2>/dev/null | awk '{s+=$1} END{print s+0}')"

echo
echo "=== other candidate record directories ==="
for d in "$R"/*/; do
  case "$(basename "$d")" in
    results|scripts|images|.hf|hf) continue ;;
  esac
  printf '  %-26s %10s %6s files\n' "$(basename "$d")" \
    "$(du -sh "$d" 2>/dev/null | cut -f1)" "$(find "$d" -type f | wc -l)"
done

echo
echo "=== grand total, excluding images/ and the HF cache ==="
du -sh --exclude=images --exclude=.hf --exclude=hf "$R" 2>/dev/null | cut -f1

echo
echo "=== biggest individual files, to spot anything over GitHub's limit ==="
find "$R" -path "$R/images" -prune -o -path "$R/.hf" -prune -o \
     -type f -size +20M -printf '%s %p\n' 2>/dev/null \
  | sort -rn | head -10 | awk '{printf "  %6.1f MiB  %s\n", $1/1048576, $2}'
echo "  (nothing listed above means no file exceeds 20 MiB)"
