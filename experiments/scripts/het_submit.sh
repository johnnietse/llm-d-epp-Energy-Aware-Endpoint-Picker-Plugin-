#!/usr/bin/env bash
# Cluster-side submitter for the heterogeneous Stage 2 run.
#
# Lives on the cluster as a file so there is no quoting layer to corrupt, and
# does its own pre-flight before spending an allocation. Everything here is
# cheap; the job it guards is not.
set -u
cd "$HOME/energy-epp/scripts" || exit 1

# ---- refuse to duplicate
EXISTING="$(squeue -h -u "$(id -un)" -n stage2-het -o '%i' 2>/dev/null | tr '\n' ' ')"
if [ -n "${EXISTING// /}" ]; then
  echo "REFUSING: stage2-het already queued or running: $EXISTING"
  echo "Cancel it first, or wait. Two pending duplicates happened once already."
  exit 1
fi

# ---- pre-flight: syntax
bash -n stage2_het.sbatch || { echo "FATAL: stage2_het.sbatch syntax"; exit 1; }
for f in policy_harness.py multinode_energy.py node_energy_sampler.py; do
  python3 -c "import ast,sys;ast.parse(open('$f').read())" \
    || { echo "FATAL: $f syntax"; exit 1; }
done
echo "pre-flight: all scripts parse"

# ---- pre-flight: the model the job will stage must exist where it looks
MODEL="${MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"
HF="${HF_HOME:-$HOME/energy-epp/.hf}"
MDN="models--$(printf '%s' "$MODEL" | sed 's#/#--#g')"
if [ ! -d "$HF/hub/$MDN" ]; then
  echo "FATAL: $HF/hub/$MDN does not exist, so staging would abort in-job."
  exit 1
fi
# Resolve through the symlinks: the snapshot entries point into a
# prefix-sharded blob store, so a du on the model dir reads ~12 MB and tells
# you nothing. This is what made an earlier probe look like the weights were
# missing.
WB="$(find "$HF/hub/$MDN" -name '*.safetensors' -exec stat -Lc %s {} + 2>/dev/null \
      | awk '{s+=$1} END{print s+0}')"
echo "pre-flight: $MDN resolves to $(( WB / 1048576 )) MiB of weights"
if [ "${WB:-0}" -lt 1000000000 ]; then
  echo "FATAL: expected a multi-GiB checkpoint; staging would copy nothing useful."
  exit 1
fi

# ---- pre-flight: load levels must be inside the generator's proven range
#
# The generator's measured ceiling is 512 req/s achieved with 12 workers (job
# 12303354). Asking for more produces client-limited cells that the gate then
# refuses - 40 minutes spent to learn the generator was too small. Checked here
# instead.
RATES="${RATES:-200,300,400,500,600}"
WORKERS="${WORKERS:-16}"
TOP="$(printf '%s' "$RATES" | tr ',' '\n' | sort -g | tail -1)"
CEIL="$(python3 -c "print(int(512 * $WORKERS / 12))")"
echo "pre-flight: top rate $TOP req/s vs generator ceiling ~$CEIL req/s at $WORKERS workers"
if python3 -c "import sys; sys.exit(0 if $TOP > $CEIL else 1)"; then
  echo "FATAL: top rate $TOP exceeds the generator's scaled ceiling $CEIL."
  echo "Raise WORKERS or lower RATES. The client_limited guard would catch"
  echo "this after the run; catching it now costs nothing."
  exit 1
fi

export MAX_GPUS_PER_NODE="${MAX_GPUS_PER_NODE:-4}"
export DURATION="${DURATION:-60}"
export WORKERS RATES
export SEED="${SEED:-7}"
export MODEL

echo
echo "=== heterogeneous Stage 2: A100 + RTX 6000, $DURATION s cells ==="
echo "rates=$RATES workers=$WORKERS seed=$SEED cap=$MAX_GPUS_PER_NODE"
J=$(sbatch --parsable --export=ALL \
      --gres=gpu:a100:4    --nodes=1 --exclusive --mem=0 \
    : --gres=gpu:rtx6000:4 --nodes=1 --exclusive --mem=0 \
      stage2_het.sbatch 2>&1) || { echo "SUBMIT FAILED: $J"; exit 1; }
JID="${J%%+*}"
echo "SUBMITTED $JID"
sleep 4
squeue -h -u "$(id -un)" -o '%.12i %.12j %.9T %.9M %.18R'
echo "watch with: fr-hetwatch.sh $JID"
