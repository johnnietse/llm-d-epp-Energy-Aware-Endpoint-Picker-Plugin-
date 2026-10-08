#!/usr/bin/env bash
# Pushes and runs the het step-concurrency probe: can a heterogeneous job run
# four concurrent srun --overlap steps per component, which is what the real
# job needs for 4+4 vLLM servers.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
for f in probe_het_steps.sbatch stage2_het.sbatch; do
  scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 \
      "$SRC/$f" "$HOST:energy-epp/scripts/" || exit 1
done

ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" bash -s <<'REMOTE'
set -u
cd "$HOME/energy-epp/scripts" || exit 1
bash -n probe_het_steps.sbatch && echo "probe sbatch ok" || exit 1
bash -n stage2_het.sbatch && echo "het sbatch ok" || exit 1

J=$(sbatch --parsable \
      --gres=gpu:a100:4   --nodes=1 --exclusive --mem=0 \
    : --gres=gpu:rtx6000:4 --nodes=1 --exclusive --mem=0 \
      probe_het_steps.sbatch 2>&1) || { echo "SUBMIT FAILED: $J"; exit 1; }
echo "step probe: $J"
for i in $(seq 1 60); do
  [ -z "$(squeue -h -j "$J" 2>/dev/null)" ] && break
  sleep 10
done
sacct -n -X -j "$J" --format=JobID,State,Elapsed,ExitCode,NodeList -P
echo "--------------------------------------------"
cat "het-steps-${J%%+*}.out" 2>/dev/null || cat "het-steps-$J.out" 2>/dev/null \
  || ls -1t het-steps-*.out 2>/dev/null | head -2
REMOTE
