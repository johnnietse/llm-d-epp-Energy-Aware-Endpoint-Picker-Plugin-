#!/usr/bin/env bash
# Prepares fetched cluster records for committing: compresses the bulky logs,
# leaves every machine-readable result alone.
#
#   bash prepare_records.sh <records-dir>
#
# Why compress rather than exclude. The vLLM server logs are ~90% of the 824 MiB
# and they are the only place a readiness stall, a CUDA arch mismatch or a
# tokenizer warning is recorded; job 12303653 is diagnosable solely because its
# log shows "Loading safetensors checkpoint shards: 0%" and then nothing for two
# hours. Dropping them to save space would discard exactly the evidence that
# made that failure legible. They are also near-identical repeated lines, so
# gzip takes them down by an order of magnitude.
#
# What is NEVER compressed: policies-rate*.json, instruments.txt,
# telemetry.txt, calibration.txt, skew/clock files, and the energy sample
# JSONL. Those are read by scripts and by people auditing a number, and a
# diffable history of them is worth more than the bytes saved.
set -u
DIR="${1:?usage: prepare_records.sh <records-dir>}"
[ -d "$DIR" ] || { echo "no such directory: $DIR" >&2; exit 1; }

THRESH_BYTES=$((1024 * 1024))
n=0
before=0
after=0

echo "compressing logs over 1 MiB under $DIR"
while IFS= read -r f; do
  case "$f" in
    *.gz|*.json|*.jsonl|*.csv) continue ;;
  esac
  sz="$(stat -c %s "$f" 2>/dev/null || echo 0)"
  [ "$sz" -gt "$THRESH_BYTES" ] || continue
  before=$((before + sz))
  gzip -9 -f "$f" || { echo "  FAILED: $f" >&2; continue; }
  asz="$(stat -c %s "$f.gz" 2>/dev/null || echo 0)"
  after=$((after + asz))
  n=$((n + 1))
done < <(find "$DIR" -type f \( -name '*.log' -o -name '*.out' -o -name '*.txt' \))

echo "  compressed $n file(s)"
if [ "$n" -gt 0 ]; then
  echo "  $((before / 1048576)) MiB -> $((after / 1048576)) MiB"
fi

echo
echo "largest remaining uncompressed files:"
find "$DIR" -type f ! -name '*.gz' -printf '%s %p\n' 2>/dev/null \
  | sort -rn | head -8 | awk '{printf "  %7.2f MiB  %s\n", $1/1048576, $2}'

echo
echo "total: $(du -sh "$DIR" 2>/dev/null | cut -f1)"
echo "files over 50 MiB (GitHub warns at 50, rejects at 100):"
find "$DIR" -type f -size +50M -printf '  %p\n' 2>/dev/null
echo "  (nothing listed means all files are under 50 MiB)"
