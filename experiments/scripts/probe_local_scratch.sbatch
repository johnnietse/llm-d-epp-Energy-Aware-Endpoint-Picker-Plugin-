#!/bin/bash
#SBATCH --job-name=scratch-probe
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --time=00:10:00
#SBATCH --mem=0
#SBATCH --gres=gpu:rtx6000:1
#SBATCH --output=%x-%j.out

# Is there NODE-LOCAL storage, and can the model live there?
#
# This is the question that decides whether the frnt155 failure mode can be
# eliminated rather than merely bounded.
#
# What happened to frnt155: eight vLLM processes read the same 2.88 GiB
# checkpoint from GPFS at once, cold. One or more blocked in uninterruptible
# kernel I/O (D state), which ignores SIGKILL until the I/O returns. scancel
# could not reap the job, the node sat in COMPLETING for hours, and nothing in
# user space could fix it. Staggering launches and pre-warming page cache both
# reduce the contention, but they are mitigations: the shared filesystem is
# still in the read path of every server, so the hazard remains.
#
# The real fix is to take GPFS out of that path. If each node has local disk,
# stage the checkpoint there once and point the servers at it. Then eight
# concurrent readers hit a local device that no other node is competing for,
# and a GPFS stall cannot wedge a server at all.
#
# Compute Canada clusters usually expose $SLURM_TMPDIR on local SSD or NVMe,
# but "usually" is exactly the kind of assumption that has cost jobs today, so
# this measures: existence, filesystem type, capacity, and write/read speed on
# a file the size of the checkpoint.
set -uo pipefail

echo "node=$(hostname)"
echo "SLURM_TMPDIR=${SLURM_TMPDIR:-UNSET}"
echo

CANDIDATES=()
[ -n "${SLURM_TMPDIR:-}" ] && CANDIDATES+=("$SLURM_TMPDIR")
CANDIDATES+=("/tmp" "/localscratch/$USER" "/scratch/local" "/var/tmp")

for d in "${CANDIDATES[@]}"; do
  echo "--- $d"
  if [ ! -d "$d" ]; then echo "    does not exist"; continue; fi
  if [ ! -w "$d" ]; then echo "    not writable"; continue; fi
  fstype="$(stat -f -c %T "$d" 2>/dev/null)"
  avail_kb="$(df -Pk "$d" 2>/dev/null | awk 'NR==2{print $4}')"
  echo "    fstype=$fstype  avail=$(( ${avail_kb:-0} / 1024 )) MiB"
  # GPFS and NFS are shared; they do not solve the problem even if writable.
  case "$fstype" in
    gpfs|nfs|lustre|fuseblk)
        echo "    SHARED filesystem - does not remove the contention" ;;
    *)  echo "    looks node-local" ;;
  esac
done

echo
echo "=== where does the model actually live, and how big is it? ==="
MODELDIR="$(find "$HOME/energy-epp/.hf/hub" -maxdepth 1 -type d -name 'models--Qwen*' 2>/dev/null | head -1)"
echo "model dir: ${MODELDIR:-NOT FOUND}"
if [ -n "$MODELDIR" ]; then
  du -sh "$MODELDIR" 2>/dev/null | sed 's/^/  /'
  echo "  filesystem: $(stat -f -c %T "$MODELDIR" 2>/dev/null)"
fi

echo
echo "=== copy the checkpoint to the best local candidate and time it ==="
DEST=""
for d in "${CANDIDATES[@]}"; do
  [ -d "$d" ] && [ -w "$d" ] || continue
  ft="$(stat -f -c %T "$d" 2>/dev/null)"
  case "$ft" in gpfs|nfs|lustre) continue ;; esac
  av="$(df -Pk "$d" 2>/dev/null | awk 'NR==2{print $4}')"
  [ "${av:-0}" -gt 8000000 ] || { echo "  $d: only $(( ${av:-0}/1024 )) MiB free, need ~8 GiB"; continue; }
  DEST="$d"; break
done

if [ -z "$DEST" ] || [ -z "${MODELDIR:-}" ]; then
  echo "NO usable node-local destination found."
  echo "The GPFS read path cannot be removed, so staggering plus page-cache"
  echo "pre-warm remain the only mitigations and the walltime stays the"
  echo "backstop against a wedge."
  exit 1
fi

echo "staging into $DEST/hfstage-$SLURM_JOB_ID"
mkdir -p "$DEST/hfstage-$SLURM_JOB_ID/hub"
t0=$(date +%s.%N)
cp -r "$MODELDIR" "$DEST/hfstage-$SLURM_JOB_ID/hub/" || { echo "COPY FAILED"; exit 1; }
sync
t1=$(date +%s.%N)
bytes="$(du -sb "$DEST/hfstage-$SLURM_JOB_ID" 2>/dev/null | cut -f1)"
python3 -c "
b=$bytes; dt=$t1-$t0
print('  copied %.2f GiB in %.1f s = %.0f MiB/s' % (b/2**30, dt, b/dt/2**20))"

echo
echo "=== read it back, 8 concurrent readers, as the real job would ==="
t0=$(date +%s.%N)
for i in $(seq 1 8); do
  ( find "$DEST/hfstage-$SLURM_JOB_ID" -name '*.safetensors' -type f -print0 \
      | xargs -0 -r cat > /dev/null 2>&1 ) &
done
wait
t1=$(date +%s.%N)
python3 -c "
b=$bytes*8; dt=$t1-$t0
print('  8 readers read %.2f GiB total in %.1f s = %.0f MiB/s aggregate'
      % (b/2**30, dt, b/dt/2**20))"

rm -rf "$DEST/hfstage-$SLURM_JOB_ID"
echo
echo "RESULT: node-local staging is possible at $DEST."
echo "Pointing HF_HOME there removes GPFS from every server's read path, which"
echo "eliminates the frnt155 hazard rather than reducing its probability."
