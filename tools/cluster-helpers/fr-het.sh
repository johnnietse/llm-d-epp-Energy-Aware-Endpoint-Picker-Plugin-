#!/usr/bin/env bash
# Pushes the multi-node pieces and runs the heterogeneous preflight.
# A100 (frnt154/190/191) paired with RTX 6000 (plentiful 4-GPU nodes): the
# widest measured energy gap in the fleet, 0.0132 vs 0.0353 J/gen-token.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
for f in node_energy_sampler.py multinode_energy.py policy_harness.py \
         stage2_het.sbatch stage2_het_preflight.sbatch; do
  scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$SRC/$f" "$HOST:energy-epp/scripts/" || exit 1
done
echo "pushed"

ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" bash -s <<'REMOTE'
set -u
cd "$HOME/energy-epp/scripts" || exit 1
python3 -c "import ast;ast.parse(open('policy_harness.py').read());print('harness ok')" || exit 1
python3 -c "import ast;ast.parse(open('multinode_energy.py').read());print('aggregator ok')" || exit 1
bash -n stage2_het.sbatch && echo "het sbatch ok" || exit 1
bash -n stage2_het_preflight.sbatch && echo "preflight sbatch ok" || exit 1

J=$(sbatch --parsable \
      --gres=gpu:a100:1 --nodes=1 --mem=16G \
    : --gres=gpu:rtx6000:1 --nodes=1 --mem=16G \
      stage2_het_preflight.sbatch 2>&1) || { echo "SUBMIT FAILED: $J"; exit 1; }
echo "preflight job: $J"
for i in $(seq 1 70); do
  [ -z "$(squeue -h -j "$J" 2>/dev/null)" ] && break
  sleep 10
done
sacct -n -X -j "$J" --format=JobID,State,Elapsed,ExitCode,NodeList -P
echo "--------------------------------------------"
cat het-preflight-"${J%%+*}".out 2>/dev/null \
  || cat het-preflight-"$J".out 2>/dev/null \
  || ls -1 het-preflight-*.out 2>/dev/null | tail -3
REMOTE
