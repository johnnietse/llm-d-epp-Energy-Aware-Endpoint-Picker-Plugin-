#!/usr/bin/env bash
# Cluster-side submitter for the GPU-count-matched homogeneous control: the
# 8x RTX 6000 node, same offered rates as the heterogeneous fleet.
#
# Why this run exists. The heterogeneous fleet is 4 A100 + 4 RTX 6000, eight
# GPUs. The homogeneous arm it is compared against (12304137/12304138) was four
# GPUs, so the claim "energy-aware routing pays under heterogeneity and not
# under homogeneity" currently differs in TWO variables, fleet composition and
# fleet size. frnt155 is the cluster's only 8x RTX 6000 node, which makes it
# the one place that confound can be removed. It also closes plan threat N15,
# because stage2_real.sbatch now stages node-locally like the het script does,
# so both arms share a read path for the first time.
#
# Same structure and the same guards as het_submit.sh, deliberately: every
# pre-flight here is cheap and the allocation it protects is not.
set -u
cd "$HOME/energy-epp/scripts" || exit 1

NODE="${NODE:-frnt155}"

# ---- refuse to duplicate
EXISTING="$(squeue -h -u "$(id -un)" -n stage2-real -o '%i' 2>/dev/null | tr '\n' ' ')"
if [ -n "${EXISTING// /}" ]; then
  echo "REFUSING: stage2-real already queued or running: $EXISTING"
  echo "Cancel it first, or wait."
  exit 1
fi

# ---- pre-flight: the node must exist, be the right GPU, and have 8 of them
#
# Pinned with -w rather than selected by -C, because driver version, profiling
# permission and idle power were all measured to vary between nodes of the same
# GPU model (experiments/instruments-2026-10-03). A control run on an unknown
# node of the right type is not a control.
NSTATE="$(sinfo -h -n "$NODE" -o '%T' 2>/dev/null | head -1)"
NGRES="$(sinfo -h -n "$NODE" -o '%G' 2>/dev/null | head -1)"
echo "pre-flight: $NODE state=${NSTATE:-UNKNOWN} gres=${NGRES:-UNKNOWN}"
case "${NSTATE:-}" in
  idle|mixed|allocated) : ;;
  completing)
    echo "FATAL: $NODE is in COMPLETING. That is the wedge state; submitting now"
    echo "would queue behind processes stuck in uninterruptible I/O."
    exit 1 ;;
  "")
    echo "FATAL: $NODE is not visible to sinfo."
    exit 1 ;;
  *)
    echo "FATAL: $NODE is $NSTATE, not schedulable."
    exit 1 ;;
esac
case "$NGRES" in
  *rtx6000:8*) echo "pre-flight: 8x RTX 6000 confirmed on $NODE" ;;
  *) echo "FATAL: expected 8x rtx6000 on $NODE, sinfo reports '$NGRES'."
     echo "The whole point of this run is the matched GPU count."
     exit 1 ;;
esac

# ---- pre-flight: syntax
bash -n stage2_real.sbatch || { echo "FATAL: stage2_real.sbatch syntax"; exit 1; }
for f in policy_harness.py; do
  python3 -c "import ast,sys;ast.parse(open('$f').read())" \
    || { echo "FATAL: $f syntax"; exit 1; }
done
echo "pre-flight: all scripts parse"

# ---- pre-flight: staging must actually be present in this script
#
# Checked here and not only in verify_fixes.sh because launching the homogeneous
# script WITHOUT staging reintroduces eight cold concurrent GPFS readers on the
# exact node that sat in COMPLETING for hours. This is the one pre-flight whose
# absence has a known, expensive failure mode on this specific node.
if ! grep -q 'STAGE_DIR="/tmp/hfstage-$SLURM_JOB_ID"' stage2_real.sbatch \
   || ! grep -q 'export HF_HOME="$STAGE_DIR"' stage2_real.sbatch \
   || ! grep -q 'HF_HUB_OFFLINE=1' stage2_real.sbatch; then
  echo "FATAL: stage2_real.sbatch has no node-local staging block."
  echo "Refusing to put eight cold readers back onto GPFS on $NODE."
  exit 1
fi
echo "pre-flight: node-local staging present in stage2_real.sbatch"

# ---- pre-flight: the model the job will stage must exist where it looks
MODEL="${MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"
HF="${HF_HOME:-$HOME/energy-epp/.hf}"
MDN="models--$(printf '%s' "$MODEL" | sed 's#/#--#g')"
if [ ! -d "$HF/hub/$MDN" ]; then
  echo "FATAL: $HF/hub/$MDN does not exist, so staging would abort in-job."
  exit 1
fi
WB="$(find "$HF/hub/$MDN" -name '*.safetensors' -exec stat -Lc %s {} + 2>/dev/null \
      | awk '{s+=$1} END{print s+0}')"
echo "pre-flight: $MDN resolves to $(( WB / 1048576 )) MiB of weights"
if [ "${WB:-0}" -lt 1000000000 ]; then
  echo "FATAL: expected a multi-GiB checkpoint; staging would copy nothing useful."
  exit 1
fi

# ---- pre-flight: load levels must be inside the generator's proven range
#
# RATES is pinned to the heterogeneous run's levels rather than derived from
# PEAK_RPS. Matched offered load is the comparison we want: same demand, same
# GPU count, only fleet composition differs. A derived rate ladder would scale
# with this node's own capacity and make the two arms incomparable.
RATES="${RATES:-200,300,400,500,600}"
WORKERS="${WORKERS:-16}"
TOP="$(printf '%s' "$RATES" | tr ',' '\n' | sort -g | tail -1)"
CEIL="$(python3 -c "print(int(512 * $WORKERS / 12))")"
echo "pre-flight: top rate $TOP req/s vs generator ceiling ~$CEIL req/s at $WORKERS workers"
if python3 -c "import sys; sys.exit(0 if $TOP > $CEIL else 1)"; then
  echo "FATAL: top rate $TOP exceeds the generator's scaled ceiling $CEIL."
  echo "Raise WORKERS or lower RATES."
  exit 1
fi

export DURATION="${DURATION:-60}"
export WORKERS RATES
export SEED="${SEED:-11}"
export MODEL

echo
echo "=== homogeneous control: 8x RTX 6000 on $NODE, $DURATION s cells ==="
echo "rates=$RATES workers=$WORKERS seed=$SEED"
if [ "$RATES" = "200,300,400,500,600" ]; then
  echo "matched against the heterogeneous fleet on GPU count and offered load"
else
  # Printing "matched offered load" for an overridden ladder would put a
  # false provenance claim into the job log, which is what gets read later.
  echo "matched on GPU count; offered load is a custom ladder, NOT the het one"
fi
J=$(sbatch --parsable --export=ALL \
      -w "$NODE" --nodes=1 --exclusive --mem=0 --gres=gpu:rtx6000:8 \
      stage2_real.sbatch 2>&1) || { echo "SUBMIT FAILED: $J"; exit 1; }
JID="${J%%+*}"
echo "SUBMITTED $JID"
sleep 4
squeue -h -u "$(id -un)" -o '%.12i %.12j %.9T %.9M %.18R'
