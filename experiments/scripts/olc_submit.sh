#!/usr/bin/env bash
# Cluster-side. Submits the open-loop curves (approach A, author's choice,
# 2026-10-09): A100 on frnt154 and RTX 6000 on frnt149, pinned as before.
#
#   bash olc_submit.sh        # via: bash fr-sync.sh run olc_submit.sh
#
# Rates are fractions {0.02, 0.05, 0.1 ... 1.0, 1.1} of each type's capacity
# at vLLM's 256-request batch limit, measured by the closed-loop curves:
#   A100     23,460 tok/s at c=256 (h1-12325153) -> 183 req/s
#   RTX 6000  8,627 tok/s at c=256 (h1-12325154) ->  67 req/s
# The top rates are expected to overload. The loader ends each curve at the
# first rate that fails to keep up, so they mark the edge rather than feed
# the curve. Six trials per rate; trial 1 is dropped as warm-up.
set -u
cd "$HOME/energy-epp/scripts" || exit 1
bash -n openloop_curve.sbatch || { echo "openloop_curve.sbatch syntax error"; exit 1; }
for f in policy_harness.py openloop_build.py select_openloop_curves.py; do
  python3 -c "import ast;ast.parse(open('$f').read())" || { echo "FATAL: $f syntax"; exit 1; }
done
export TRIALS=6 DURATION=60 WORKERS=6 SEED=701

submit() {  # $1 label, $2 gres, $3 node, $4 rates
  J=$(RATES="$4" sbatch --parsable --gres="gpu:$2:1" -w "$3" --export=ALL \
        openloop_curve.sbatch 2>&1) || { echo "  $1: SUBMIT FAILED: $J"; return 1; }
  echo "  $1 on $3: job $J  rates=$4"
}
submit a100    a100    frnt154 "4,9,18,37,55,73,92,110,128,147,156,165,174,183,202"
submit rtx6000 rtx6000 frnt149 "1,3,7,13,20,27,34,40,47,54,57,61,64,67,74"
sleep 5
squeue -u "$(id -un)" -o '%.12i %.12j %.9T %.9M %.28R'
