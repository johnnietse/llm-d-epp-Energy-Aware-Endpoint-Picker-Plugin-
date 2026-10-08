#!/usr/bin/env bash
# Pulls every measurement record off the cluster into the repo working tree.
#
#   bash fr-fetchall.sh
#
# What counts as a record: anything a result or a provenance claim could be
# traced back to. Result directories, the Slurm job logs that say which node and
# driver produced them, the instrument probes, and the config. NOT the software:
# opt/ is 5.3 GiB of DCGM and Nsight packages, images/ holds the 7.6 GiB
# apptainer layers, .hf is the model cache, and llm-d-router is a git checkout.
# Those are all re-fetchable from upstream; the measurements are not.
#
# rsync, not scp: 824 MiB of mostly vLLM server logs compresses hard on the
# wire, and a resumed transfer after a dropped control socket should not restart
# from zero. This socket has died mid-session repeatedly.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
DST="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/cluster-records"

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
RSH="ssh -S $SOCK -o BatchMode=yes -o ConnectTimeout=10"

mkdir -p "$DST/results" "$DST/slurm-logs" || exit 1

# With arguments, fetch only those result directories, plus the Slurm logs. A
# full re-fetch re-downloads every log that prepare_records.sh already gzipped
# locally, because rsync sees the uncompressed name as missing: 365 MiB of
# transfer to recover nothing new.
if [ "$#" -gt 0 ]; then
  for d in "$@"; do
    echo "=== results/$d ==="
    rsync -a -z --info=stats2 -e "$RSH" \
          "$HOST:energy-epp/results/$d/" "$DST/results/$d/" || exit 1
  done
  rsync -a -z -e "$RSH" --include='*.out' --exclude='*' \
        "$HOST:energy-epp/scripts/" "$DST/slurm-logs/" || exit 1
  for d in "$@"; do du -sh "$DST/results/$d" 2>/dev/null; done
  exit 0
fi

echo "=== results/ ==="
rsync -a -z --info=stats2 -e "$RSH" \
      "$HOST:energy-epp/results/" "$DST/results/" || exit 1

echo
echo "=== Slurm job logs ==="
rsync -a -z --info=stats2 -e "$RSH" --include='*.out' --exclude='*' \
      "$HOST:energy-epp/scripts/" "$DST/slurm-logs/" || exit 1

echo
echo "=== instrument probes, logs, config ==="
for d in instruments-probe logs config; do
  rsync -a -z --info=stats2 -e "$RSH" \
        "$HOST:energy-epp/$d/" "$DST/$d/" 2>/dev/null \
    && echo "  $d ok" || echo "  $d absent or unreadable, skipped"
done

echo
echo "=== fetched, local totals ==="
du -sh "$DST"/* 2>/dev/null
echo "total: $(du -sh "$DST" 2>/dev/null | cut -f1)"
