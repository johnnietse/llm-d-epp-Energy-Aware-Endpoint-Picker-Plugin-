#!/usr/bin/env bash
# Submits the real heterogeneous Stage 2 run and watches startup closely for
# the frnt155 wedge signature: servers not reaching ready while no server log
# grows. The job aborts itself on that via STALL_S, but we want to see it.
set -u
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"
HOST="hpc6081@login.cac.queensu.ca"
SRC="/mnt/c/Users/Johnnie/llm-d-epp-energy/experiments/scripts"

[ -S "$SOCK" ] || { echo "NO CONTROL SOCKET" >&2; exit 2; }
for f in stage2_het.sbatch node_energy_sampler.py multinode_energy.py \
         policy_harness.py; do
  scp -o ControlPath="$SOCK" -o BatchMode=yes -o ConnectTimeout=10 \
      "$SRC/$f" "$HOST:energy-epp/scripts/" || exit 1
done

ssh -S "$SOCK" -o BatchMode=yes -o ConnectTimeout=10 "$HOST" bash -s <<'REMOTE'
set -u
cd "$HOME/energy-epp/scripts" || exit 1
bash -n stage2_het.sbatch || exit 1

export MAX_GPUS_PER_NODE=4
export DURATION=60
# 16 workers, not 6. The generator's measured ceiling is 512 req/s achieved
# with 12 workers (job 12303354); 6 would top out near 250. frnt154, which
# hosts the generator, has 128 CPUs, so there is room. The client_limited
# guard still backstops this - it is a safety net, not a substitute for
# sizing the generator to the load.
export WORKERS=16
# Explicit rates rather than fractions of capacity. PEAK_RPS for 4 A100 plus
# 4 RTX 6000 is 854 req/s (584 + 270), and the 0.3-0.9 fractions would ask for
# 256 to 769 req/s - past the generator's proven range at the top. These stay
# within it while still spanning the region where the mixed fleet's SLO should
# start to bind.
export RATES="200,300,400,500,600"
export SEED=7

echo "=== heterogeneous Stage 2: 4x A100 + 4x RTX 6000 ==="
echo "the widest measured energy gap in the fleet: 0.0132 vs 0.0353 J/gen-token"
J=$(sbatch --parsable --export=ALL \
      --gres=gpu:a100:4   --nodes=1 --exclusive --mem=0 \
    : --gres=gpu:rtx6000:4 --nodes=1 --exclusive --mem=0 \
      stage2_het.sbatch 2>&1) || { echo "SUBMIT FAILED: $J"; exit 1; }
JID="${J%%+*}"
echo "submitted $JID"
sleep 5
squeue -u "$(id -un)" -o '%.12i %.12j %.9T %.9M %.18R' | head -6

# Watch startup. The wedge signature is: not ready, and the server logs are not
# growing. Report it rather than waiting the full walltime.
L=""
prev_sizes=""
stuck=0
for i in $(seq 1 100); do
  sleep 15
  [ -z "$L" ] && L="$(ls -t stage2-het-"$JID".out 2>/dev/null | head -1)"
  [ -z "$L" ] && continue
  if grep -q "^ready: " "$L" 2>/dev/null; then
    echo
    echo "STARTUP OK after ~$((i * 15))s"
    grep -E "component [0-9]:|capping|unequal|warming|read .* bytes|clock skew|ready: |SLO =|PEAK_RPS|load levels|curve for" "$L" | head -22
    break
  fi
  if grep -q "FATAL" "$L" 2>/dev/null; then
    echo
    echo "ABORTED EARLY - the guard fired instead of hanging:"
    grep -B3 -A14 "FATAL" "$L" | head -22
    break
  fi
  R="$HOME/energy-epp/results/stage2het-$JID"
  sizes="$(stat -c%s "$R"/vllm-*.log 2>/dev/null | tr '\n' ' ')"
  if [ -n "$sizes" ] && [ "$sizes" = "$prev_sizes" ]; then
    stuck=$((stuck + 1))
    if [ "$stuck" -eq 8 ]; then
      echo
      echo "*** WEDGE SIGNATURE: ~120s with no server log growth and not ready."
      echo "    This is how frnt155 behaved. Last line per server:"
      for f in "$R"/vllm-*.log; do
        printf '      %s: ' "$(basename "$f")"; tail -1 "$f" | cut -c1-110
      done
      echo "    The job's own stall detector aborts at STALL_S=300."
    fi
  else
    stuck=0
  fi
  prev_sizes="$sizes"
done

echo
squeue -h -j "$JID" -o '%.12i %.9T %.9M %.18R' 2>/dev/null || echo "(not queued)"
echo "job id for follow-up: $JID"
REMOTE
