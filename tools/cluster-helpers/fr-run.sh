#!/usr/bin/env bash
# Stage 2 across the full load range, routed on the c=256 curve (job 12304133).
#
# The previous two attempts were refused by the gate for the right reason: the
# c=128 curve did not cover the concurrencies the consolidating policies drive.
# At 180 req/s 96.8% of picks were ungrounded; even at 150 req/s it was 37.5%,
# because those policies deliberately push individual endpoints well past the
# fleet average. Extending the curve is the fix, not shrinking the sweep.
#
# The new curve also sharpens the SLO picture: p95 first exceeds 2.0 s at c=96,
# so SLO-feasible per-endpoint concurrency is about 80, and throughput
# saturates (52 req/s at c=128, 67 at c=256).
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }

ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" bash -s <<'REMOTE'
set -u
cd "$HOME/energy-epp/scripts" || exit 1
export POLICIES="round_robin,least_loaded,slo_packing,energy_greedy,energy_consolidate"
export RATES="120,136,150,165,180"
export DURATION=60
export MAX_GPUS=4
export WORKERS=6
export SEED=7
J1=$(sbatch --parsable --gres=gpu:rtx6000:4 --export=ALL stage2_real.sbatch) || exit 1
echo "trial 1 (seed 7):  $J1"
export SEED=11
J2=$(sbatch --parsable --gres=gpu:rtx6000:4 --export=ALL stage2_real.sbatch) || exit 1
echo "trial 2 (seed 11): $J2"
echo "rates: $RATES req/s, routed on the c=256 curve"
sleep 6
squeue -u "$(id -un)" -o '%.10i %.12j %.9T %.10M %.16R'
REMOTE
