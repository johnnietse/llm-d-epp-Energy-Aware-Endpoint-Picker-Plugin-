#!/bin/bash
# Stage 2 on a HETEROGENEOUS fleet: two GPU types, one Slurm heterogeneous job.
#
# Submit (component order matters; types come from the gres):
#   sbatch --gres=gpu:a100:4   --nodes=1 --exclusive --mem=0 \
#        : --gres=gpu:rtx6000:4 --nodes=1 --exclusive --mem=0 \
#          stage2_het.sbatch
#
# Why this exists. Stage 2 on a homogeneous fleet returned a clean negative
# result: every policy that consults the energy curve was infeasible, and plain
# round_robin won on SLO-goodput per joule (jobs 12304137/12304138). But the
# fleet was four identical Turing cards, and the per-type curves measured the
# same day show that is the worst possible setting for the idea - RTX 6000 is
# 2.7x worse on J/token than A100, A30 or L4, and efficiency and throughput are
# nearly inverted across types. A router can only arbitrate a trade-off that
# exists between its options.
#
# Why multi-node. Each Frontenac node carries exactly one GPU type, and in-node
# heterogeneity via clock clamping was measured as impossible (job 12304132:
# --power-limit and --lock-gpu-clocks denied; --lock-memory-clocks and -ac
# accept and do nothing). So two types means two nodes.
#
# The hard part is energy. NVML is node-local, so the harness cannot read the
# other node's counters: a local meter would report a subset of the fleet as if
# it were the whole, which is a wrong number that looks merely small. Instead
# node_energy_sampler.py runs on every node writing cumulative counter samples
# to shared storage, and multinode_energy.py stitches them per window. Clock
# skew is measured here and passed through so the resulting figure carries its
# own uncertainty.
#
# Environment knobs: MODEL, RATES, DURATION, SLO, POLICIES, WORKERS, SEED,
#                    SAMPLE_INTERVAL
#SBATCH --job-name=stage2-het
#SBATCH --account=def-hpcg1971_gpu
# 1h15m. The run needs about 40 minutes (5 rates x 5 policies x 80 s plus
# startup), so this leaves headroom without leaving hours of it.
#
# Be precise about what the walltime does and does not do. It does NOT
# prevent a wedge, and it does not shorten one: a process blocked in
# uninterruptible kernel I/O ignores SIGKILL until the I/O returns, which
# is why scancel could not reap job 12303653 and frnt155 sat in COMPLETING
# for hours. The walltime only bounds how long the ALLOCATION is held
# before Slurm reclaims it, and even that waits on the same stuck I/O.
#
# The actual fix is upstream: take the shared filesystem out of every
# server's read path by staging the checkpoint on node-local storage, so a
# GPFS stall cannot block a server at all. See STAGE_LOCAL below. The
# walltime is the last line of defence, not the control.
#SBATCH --time=01:15:00
#SBATCH --output=%x-%j.out

set -uo pipefail

# No profile-source fallback here.
#
# That profile execs a replacement login shell, so everything after it in a
# batch script is discarded: the job exits 1 in zero seconds with an empty log.
# Job 12303347 died that way, and job 12304893 - the first attempt at THIS
# script - died identically, because it was submitted without --export=ALL so
# "module" was undefined and the fallback branch ran. The absolute apptainer
# path needs neither the profile nor an inherited environment, which makes the
# script correct whether or not the submitter remembers the flag.
module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null || true
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"

ROOT="$HOME/energy-epp"
IMG="$ROOT/images/vllm-v0.30.0.sif"
RUN="$ROOT/results/stage2het-$SLURM_JOB_ID"
SAMPLES="$RUN/samples"
mkdir -p "$SAMPLES"

MODEL="${MODEL:-Qwen/Qwen2.5-1.5B-Instruct}"
DURATION="${DURATION:-60}"
SEED="${SEED:-7}"
WORKERS="${WORKERS:-6}"
SAMPLE_INTERVAL="${SAMPLE_INTERVAL:-0.25}"
POLICIES="${POLICIES:-round_robin,least_loaded,slo_packing,energy_greedy,energy_consolidate}"
export HF_HOME="${HF_HOME:-$ROOT/.hf}"

echo "job=$SLURM_JOB_ID het_size=${SLURM_HET_SIZE:-unset}"
if [ -z "${SLURM_HET_SIZE:-}" ] || [ "${SLURM_HET_SIZE}" -lt 2 ]; then
  echo "FATAL: this script needs a heterogeneous allocation with >=2 components."
  echo "Submit with the ':' separator, e.g."
  echo "  sbatch --gres=gpu:a100:4 --nodes=1 --exclusive --mem=0 \\"
  echo "       : --gres=gpu:rtx6000:4 --nodes=1 --exclusive --mem=0 \\"
  echo "         stage2_het.sbatch"
  exit 1
fi

# ------------------------------------------------------- component inventory
# Each component is one node with one GPU type. Ask each node what it has
# rather than parsing the submission line: the gres string is what we asked
# for, nvidia-smi is what we got.
declare -a HOSTS TYPES_PER_HOST NGPU_PER_HOST
for g in $(seq 0 $((SLURM_HET_SIZE - 1))); do
  h="$(srun --het-group="$g" --nodes=1 --ntasks=1 hostname 2>/dev/null | head -1)"
  nm="$(srun --het-group="$g" --nodes=1 --ntasks=1 \
        nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 | tr ' ' '_')"
  ng="$(srun --het-group="$g" --nodes=1 --ntasks=1 \
        nvidia-smi --query-gpu=index --format=csv,noheader 2>/dev/null | wc -l)"
  # --exclusive hands over every GPU on the node regardless of what --gres
  # asked for. The step probe (job 12304889) requested gpu:a100:4 and landed on
  # frnt154, which has 8: without a cap this job would build a lopsided 8+4
  # fleet instead of the balanced 4+4 that makes the comparison legible. The
  # same surprise is why stage2_real.sbatch carries MAX_GPUS.
  HOSTS[$g]="$h"; TYPES_PER_HOST[$g]="$nm"; NGPU_PER_HOST[$g]="$ng"
  echo "  component $g: host=$h type=$nm gpus_present=$ng"
done

# ------------------------------------------------------- balance the fleet
# Unequal replica counts per type confound the measurement: a policy could
# score well merely by preferring whichever type happens to have more
# replicas, and nothing in the result would distinguish that from an energy
# effect.
#
# The first version refused when the components came back unequal, which is
# brittle for no benefit - the condition is routine, not exceptional.
# --exclusive hands over every GPU on a node regardless of --gres, so landing
# on frnt154 (8 A100) beside frnt152 (4 RTX 6000) is the normal case, not a
# misconfiguration. Self-balance to the smaller component instead, and say so.
# MAX_GPUS_PER_NODE, when set, is an additional ceiling rather than the
# mechanism.
BAL="${NGPU_PER_HOST[0]}"
for g in $(seq 1 $((SLURM_HET_SIZE - 1))); do
  [ "${NGPU_PER_HOST[$g]}" -lt "$BAL" ] && BAL="${NGPU_PER_HOST[$g]}"
done
if [ -n "${MAX_GPUS_PER_NODE:-}" ] && [ "${MAX_GPUS_PER_NODE}" -lt "$BAL" ]; then
  BAL="$MAX_GPUS_PER_NODE"
fi
if [ "${BAL:-0}" -lt 1 ]; then
  echo "FATAL: a component reported no GPUs; cannot build a fleet."
  exit 1
fi
for g in $(seq 0 $((SLURM_HET_SIZE - 1))); do
  if [ "${NGPU_PER_HOST[$g]}" -ne "$BAL" ]; then
    echo "  balancing component $g: ${NGPU_PER_HOST[$g]} GPUs present, using $BAL"
  fi
  NGPU_PER_HOST[$g]="$BAL"
done
echo "fleet: ${SLURM_HET_SIZE} types x $BAL replicas each"

if [ "${TYPES_PER_HOST[0]}" = "${TYPES_PER_HOST[1]}" ]; then
  echo "FATAL: both components are ${TYPES_PER_HOST[0]}."
  echo "This script exists to test a HETEROGENEOUS fleet; two nodes of the same"
  echo "type would just re-run the homogeneous experiment at twice the size and"
  echo "pay the cross-node energy-stitching cost for nothing."
  exit 1
fi

# --------------------------------------------------------- clock skew, measured
# Window boundaries come from the generator's clock while samples carry each
# node's own. If those disagree, energy lands in the wrong window. Measure the
# spread instead of trusting NTP, and record it so the energy figure can carry
# its own error bar.
echo
echo "=== clock skew across components ==="
SKEW_FILE="$RUN/clock_skew.txt"
: > "$SKEW_FILE"
for rep in 1 2 3; do
  for g in $(seq 0 $((SLURM_HET_SIZE - 1))); do
    ref="$(date +%s.%N)"
    nodet="$(srun --het-group="$g" --nodes=1 --ntasks=1 date +%s.%N 2>/dev/null | head -1)"
    ref2="$(date +%s.%N)"
    echo "$g $ref $nodet $ref2" >> "$SKEW_FILE"
  done
done
SKEW="$(python3 - "$SKEW_FILE" <<'PY'
import sys
# srun has a round trip, so node_time - ref cannot be read as skew directly.
# Bound it: the node's clock was read somewhere between ref and ref2, so the
# skew lies within [nodet - ref2, nodet - ref]. Report the largest magnitude
# any component's interval allows - a conservative bound, not an estimate.
worst = 0.0
for line in open(sys.argv[1]):
    g, ref, nodet, ref2 = line.split()
    lo = float(nodet) - float(ref2)
    hi = float(nodet) - float(ref)
    worst = max(worst, abs(lo), abs(hi))
print("%.6f" % worst)
PY
)"
echo "  conservative skew bound: ${SKEW}s (includes srun round-trip, so it"
echo "  overstates the true clock difference)"
echo "$SKEW" > "$RUN/skew_seconds.txt"

# ------------------------------------------------------------- launch servers
# Bind to 0.0.0.0, not 127.0.0.1: the generator runs on one node and must reach
# the other node's servers over the cluster network.
# ------------------------------- stage the model on NODE-LOCAL storage
# What went wrong on frnt155: eight vLLM processes read the same 2.88 GiB
# checkpoint from GPFS at once, cold. At least one blocked in uninterruptible
# kernel I/O, which ignores SIGKILL until the I/O returns, so scancel could not
# reap the job and the node sat in COMPLETING for hours. Staggering launches and
# warming page cache reduce contention but leave GPFS in every server's read
# path, so the hazard only becomes less likely. Copying to local disk removes
# it: job 12304897 confirmed /tmp and $SLURM_TMPDIR are xfs, node-local, with
# 463 GiB free, and that eight concurrent readers there sustain 3931 MiB/s.
#
# The path must be IDENTICAL on every node, which job 12304926 taught the hard
# way. That run discovered a writable directory per step, which is correct in
# itself, but the two nodes chose differently - frnt154 had a real
# $SLURM_TMPDIR at /lscratch/slurm-job-<id> while frnt163's inherited value did
# not exist so it fell through to /tmp. The script then collapsed both into one
# HF_HOME, the last one written won, and all four A100 servers died with
# huggingface_hub LocalEntryNotFoundError while the four RTX 6000 servers - for
# which the path happened to be right - came up fine. "ready: 4/8".
#
# So: one fixed path under /tmp, suffixed with the job id so concurrent jobs
# cannot collide, created on every node. /tmp is node-local xfs here and the
# allocation is --exclusive, so nothing else is competing for it.
#
# On whether this perturbs the measurement: it cannot. Staging finishes before
# any server starts and every energy window opens after readiness, so no
# staging I/O falls inside a measured interval. The samplers start AFTER this
# block for the same reason - started before, the copy's CPU and disk time
# would land in the RAPL figures. Keep that order.
STAGE_DIR="/tmp/hfstage-$SLURM_JOB_ID"
MODEL_DIR_NAME="models--$(printf '%s' "$MODEL" | sed 's#/#--#g')"
echo
echo "=== staging $MODEL to $STAGE_DIR on every node ==="
for g in $(seq 0 $((SLURM_HET_SIZE - 1))); do
  out="$(srun --het-group="$g" --nodes=1 --ntasks=1 --overlap \
         env SRC_HF="$HF_HOME" MDN="$MODEL_DIR_NAME" DST_ROOT="$STAGE_DIR" \
         bash -c '
    set -u
    src="$SRC_HF/hub/$MDN"
    [ -d "$src" ] || { echo "MISSING:$src"; exit 1; }
    mkdir -p "$DST_ROOT/hub/$MDN" || { echo "MKDIR_FAILED:$DST_ROOT"; exit 1; }
    # refs/ and snapshots/ only, dereferenced. HF keeps real weights in blobs/
    # and exposes snapshots/ as symlinks into them, so "cp -rL" on the whole
    # model directory writes every weight TWICE - that is why an earlier run
    # reported 5910 MiB for a 2944 MiB checkpoint. Reading needs only these.
    for part in refs snapshots; do
      [ -e "$src/$part" ] || continue
      cp -rL "$src/$part" "$DST_ROOT/hub/$MDN/" 2>/dev/null \
        || { echo "COPY_FAILED:$part"; exit 1; }
    done
    # A tree copied with dangling links would pass the copy and fail later at
    # model load, so confirm real weight bytes actually landed.
    wb="$(find "$DST_ROOT/hub/$MDN" -name "*.safetensors" -exec stat -Lc %s {} + \
          2>/dev/null | awk "{t+=\$1} END{print t+0}")"
    [ "${wb:-0}" -ge 1000000000 ] || { echo "THIN_COPY:$wb"; exit 1; }
    echo "OK:$(( wb / 1048576 ))"
  ' 2>/dev/null | tail -1)"
  case "$out" in
    OK:*) echo "  ${HOSTS[$g]}: $(printf '%s' "$out" | cut -d: -f2) MiB of weights staged" ;;
    THIN_COPY:*)
          echo "FATAL: ${HOSTS[$g]} copied the tree but almost no weight bytes ($out)."
          echo "The snapshot links were probably dangling."
          exit 1 ;;
    MISSING:*)
          echo "FATAL: ${HOSTS[$g]} has no $MODEL_DIR_NAME under $HF_HOME/hub"
          exit 1 ;;
    *)    echo "FATAL: staging failed on ${HOSTS[$g]} ($out)"
          echo "Refusing to fall back to GPFS reads: that is the exact path"
          echo "that wedged frnt155, and a silent fallback would hide it."
          exit 1 ;;
  esac
done

export HF_HOME="$STAGE_DIR"
export HF_HUB_OFFLINE=1

# Verify the model is readable at the FINAL HF_HOME on every node, which is the
# check that would have caught job 12304926 in seconds instead of after a
# 20-minute readiness timeout. Staging reporting success per node is not the
# same as one shared HF_HOME resolving on all of them.
echo "  verifying $HF_HOME resolves on every node"
for g in $(seq 0 $((SLURM_HET_SIZE - 1))); do
  v="$(srun --het-group="$g" --nodes=1 --ntasks=1 --overlap \
       env HF="$HF_HOME" MDN="$MODEL_DIR_NAME" bash -c '
    set -u
    d="$HF/hub/$MDN"
    [ -d "$d" ] || { echo NO_DIR; exit 0; }
    find "$d" -name "*.safetensors" -exec stat -Lc %s {} + 2>/dev/null \
      | awk "{t+=\$1} END{if (t>=1000000000) print \"OK\"; else print \"THIN\"}"
  ' 2>/dev/null | tail -1)"
  if [ "$v" = "OK" ]; then
    echo "    ${HOSTS[$g]}: OK"
  else
    echo "FATAL: ${HOSTS[$g]} cannot read the model at $HF_HOME ($v)."
    echo "Every node must see the checkpoint at the SAME path, because one"
    echo "HF_HOME is exported to all of them. Job 12304926 failed exactly here:"
    echo "two nodes staged to different directories and half the servers died"
    echo "with LocalEntryNotFoundError."
    exit 1
  fi
done
echo "  HF_HOME=$HF_HOME verified on all ${SLURM_HET_SIZE} nodes; HF_HUB_OFFLINE=1"

PORT_BASE=8100
PORTS=()
EP_TYPES=()
# Tracked so cleanup can signal exactly what it started,
# rather than pattern-matching and risking a self-kill.
SERVER_PIDS=()
SAMPLER_PIDS=()
for g in $(seq 0 $((SLURM_HET_SIZE - 1))); do
  ng="${NGPU_PER_HOST[$g]}"
  for ((i=0; i<ng; i++)); do
    port=$((PORT_BASE + g * 100 + i))
    echo "launching vLLM on ${HOSTS[$g]} gpu $i port $port"
    srun --het-group="$g" --nodes=1 --ntasks=1 --overlap \
      env -u SSL_CERT_FILE CUDA_VISIBLE_DEVICES="$i" \
      "$APPTAINER" exec --nv "$IMG" \
        vllm serve "$MODEL" --served-model-name served \
          --host 0.0.0.0 --port "$port" \
          --gpu-memory-utilization 0.85 --max-model-len 2048 \
          > "$RUN/vllm-${HOSTS[$g]}-gpu$i.log" 2>&1 &
    SERVER_PIDS+=($!)
    PORTS+=("${HOSTS[$g]}:$port")
    EP_TYPES+=("${TYPES_PER_HOST[$g]}")
    sleep "${LAUNCH_STAGGER_S:-8}"
  done
done

# --------------------------------------------------------- launch the samplers
# One per node, covering every GPU on it. These must outlive every cell, so
# they start before the first and are killed after the last.
declare -a SAMPLER_HOSTS
for g in $(seq 0 $((SLURM_HET_SIZE - 1))); do
  out="$SAMPLES/energy-${HOSTS[$g]}.jsonl"
  echo "starting energy sampler on ${HOSTS[$g]} -> $(basename "$out")"
  srun --het-group="$g" --nodes=1 --ntasks=1 --overlap \
    env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" \
      python3 "$ROOT/scripts/node_energy_sampler.py" \
        --out "$out" --interval "$SAMPLE_INTERVAL" \
    > "$RUN/sampler-${HOSTS[$g]}.log" 2>&1 &
  SAMPLER_PIDS+=($!)
  SAMPLER_HOSTS+=("${HOSTS[$g]}")
done

cleanup() {
  # No pkill by pattern here.
  #
  # The preflight's first run cancelled its own allocation 21 seconds in
  # because "srun ... pkill -f node_energy_sampler.py" puts the pattern into
  # the srun process's own command line: pkill matched its own wrapper, killed
  # it, and Slurm reported
  #   JOB 12304883 CANCELLED DUE to SIGNAL Terminated
  # A cleanup routine that can kill the job it is cleaning up after is worse
  # than no cleanup, and in a trap on EXIT it fires exactly when the run is
  # finishing normally.
  #
  # Instead: signal the PIDs we launched, which is unambiguous. Both the
  # samplers and the vLLM servers are background children of this script, and
  # anything missed dies with the allocation anyway - srun steps do not outlive
  # their job.
  echo "stopping samplers and servers"
  # Remove the staged copy; /tmp is node-local so each node clears its own.
  if [ -n "${STAGE_DIR:-}" ]; then
    for g in $(seq 0 $((SLURM_HET_SIZE - 1))); do
      srun --het-group="$g" --nodes=1 --ntasks=1 --overlap \
        rm -rf "$STAGE_DIR" 2>/dev/null
    done
  fi
  for pid in "${SAMPLER_PIDS[@]:-}" "${SERVER_PIDS[@]:-}"; do
    [ -n "$pid" ] && kill "$pid" 2>/dev/null
  done
  # Wait for the srun steps to actually go away before the batch script exits.
  #
  # Without this, job 12305232 completed all 25 cells and was still recorded as
  # "CANCELLED by 6081": background srun steps were alive when the script
  # returned, so Slurm tore them down and attributed the cancellation to the
  # user. The measurements were fine but the job state said otherwise, which is
  # exactly the kind of misleading signal that wastes time later.
  wait 2>/dev/null || true
  # Give the samplers a moment to take SIGTERM and close their files cleanly;
  # node_energy_sampler.py handles it so the last JSONL line is not truncated.
  sleep 2
}
trap cleanup EXIT

# ------------------------------------------------- wait for cross-node readiness
# Bounded by wall clock and by progress, for the reason job 12303653 taught:
# an iteration-count bound is not a time bound, and a wedged model load writes
# nothing for hours while holding the allocation.
READY_TIMEOUT_S="${READY_TIMEOUT_S:-1200}"
STALL_S="${STALL_S:-300}"
NEP="${#PORTS[@]}"
echo
echo "waiting for all $NEP servers across ${SLURM_HET_SIZE} nodes"
echo "  deadline ${READY_TIMEOUT_S}s; abort if no server log grows for ${STALL_S}s"
log_sizes() { stat -c%s "$RUN"/vllm-*.log 2>/dev/null | tr "\n" " "; }
deadline=$(( $(date +%s) + READY_TIMEOUT_S ))
last="$(log_sizes)"; last_change=$(date +%s)
ready=0
while [ "$(date +%s)" -lt "$deadline" ]; do
  ready=0
  for ep in "${PORTS[@]}"; do
    curl -fsS --max-time 3 "http://$ep/health" >/dev/null 2>&1 && ready=$((ready+1))
  done
  [ "$ready" -eq "$NEP" ] && break
  now="$(log_sizes)"
  if [ "$now" != "$last" ]; then
    last="$now"; last_change=$(date +%s)
  elif [ $(( $(date +%s) - last_change )) -ge "$STALL_S" ]; then
    echo "FATAL: no server log has grown in ${STALL_S}s, only $ready/$NEP up."
    for f in "$RUN"/vllm-*.log; do
      printf '  %s: ' "$(basename "$f")"; tail -1 "$f" | cut -c1-120
    done
    exit 1
  fi
  sleep 5
done
echo "ready: $ready/$NEP"
if [ "$ready" -ne "$NEP" ]; then
  echo "FATAL: not all servers reachable within ${READY_TIMEOUT_S}s."
  echo "If the local ones are up and the remote ones are not, suspect"
  echo "cross-node HTTP rather than vLLM: check that 0.0.0.0 binding took and"
  echo "that the compute network permits the port range."
  for f in "$RUN"/vllm-*.log; do
    printf '  %s: ' "$(basename "$f")"; tail -1 "$f" | cut -c1-120
  done
  exit 1
fi

# Prove every sampler is actually producing data before measuring anything.
sleep 3
for g in $(seq 0 $((SLURM_HET_SIZE - 1))); do
  f="$SAMPLES/energy-${HOSTS[$g]}.jsonl"
  n="$(wc -l < "$f" 2>/dev/null || echo 0)"
  echo "  sampler ${HOSTS[$g]}: $n line(s)"
  if [ "${n:-0}" -lt 2 ]; then
    echo "FATAL: sampler on ${HOSTS[$g]} is not producing samples; see"
    echo "  $RUN/sampler-${HOSTS[$g]}.log"
    exit 1
  fi
done

# ------------------------------------------------------------------ SLO and load
echo
echo "calibrating single-request latency on each type"
for g in $(seq 0 $((SLURM_HET_SIZE - 1))); do
  first_port=$((PORT_BASE + g * 100))
  cal="$(env -u SSL_CERT_FILE "$APPTAINER" exec "$IMG" python3 - \
        "${HOSTS[$g]}:$first_port" <<'PY'
import json, sys, time, urllib.request
ep = sys.argv[1]
body = json.dumps({"model": "served", "prompt": "calibrate: explain caching.",
                   "max_tokens": 128, "temperature": 0.0}).encode()
lat = []
for _ in range(5):
    t0 = time.time()
    req = urllib.request.Request("http://" + ep + "/v1/completions", data=body,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        r.read()
    lat.append(time.time() - t0)
lat.sort()
print("%.4f" % lat[len(lat) // 2])
PY
)"
  echo "  ${TYPES_PER_HOST[$g]}: median single-request latency ${cal}s"
  echo "${TYPES_PER_HOST[$g]} $cal" >> "$RUN/calibration.txt"
done
# The SLO must be one number for the whole fleet, and it has to be reachable on
# the SLOWEST type or that type is unusable by construction. Take the slowest
# median and double it, matching the homogeneous protocol.
SLO="${SLO:-$(python3 -c "
import sys
vals=[float(l.split()[-1]) for l in open('$RUN/calibration.txt')]
print('%.1f' % (2.0 * max(vals)))")}"
echo "SLO = ${SLO}s (2x the slowest type's median single-request latency)"

# Capacity, summed over types from their measured curves.
PEAK_RPS="${PEAK_RPS:-$(python3 - "$ROOT" "$MODEL" "${TYPES_PER_HOST[0]}" \
                        "${NGPU_PER_HOST[0]}" "${TYPES_PER_HOST[1]}" \
                        "${NGPU_PER_HOST[1]}" <<'PY'
import csv, glob, os, re, sys
root, model = sys.argv[1], sys.argv[2]
pairs = [(sys.argv[3], int(sys.argv[4])), (sys.argv[5], int(sys.argv[6]))]
TYPES = (r"NVIDIA A100[^,\s]*|NVIDIA L40S|Quadro RTX 8000|Quadro RTX 6000"
         r"|Tesla V100[^,\s]*|NVIDIA A30|NVIDIA L4(?![0-9])")
best = {}
for c in glob.glob(os.path.join(root, "results", "h1-*", "h1.csv")):
    try:
        text = open(os.path.join(os.path.dirname(c), "instruments.txt")).read()
    except OSError:
        continue
    if "model=" + model not in text:
        continue
    m = re.search(TYPES, text)
    lv = re.search(r"levels=([0-9,]+)", text)
    if not m or not lv:
        continue
    name = m.group(0).replace(" ", "_")
    top = max(int(x) for x in lv.group(1).split(",") if x)
    peak = 0.0
    with open(c) as fh:
        for row in csv.DictReader(fh):
            if row.get("note") != "unique_prompts":
                continue
            try:
                peak = max(peak, float(row["throughput_rps"]))
            except (TypeError, ValueError):
                continue
    if peak and (name not in best or top > best[name][0]):
        best[name] = (top, peak)
total = 0.0
for name, n in pairs:
    if name not in best:
        sys.exit(0)        # no curve: print nothing, caller refuses
    total += best[name][1] * n
print("%.1f" % total)
PY
)}"
if [ -z "$PEAK_RPS" ]; then
  echo "FATAL: no measured Stage 1 curve for one of ${TYPES_PER_HOST[0]} /"
  echo "${TYPES_PER_HOST[1]} with model $MODEL. Refusing to invent a capacity"
  echo "figure. Run h1_sweep.sbatch for the missing type first."
  exit 1
fi
echo "PEAK_RPS ${PEAK_RPS} req/s, summed from each type's measured curve"
RATES="${RATES:-$(python3 -c "
p=$PEAK_RPS
print(','.join(f'{p*f:.1f}' for f in (0.3,0.45,0.6,0.75,0.9)))")}"
echo "load levels: $RATES req/s"

CURVE_ARGS="$(python3 - "$ROOT" "$MODEL" <<'PYSEL'
import glob, os, re, sys
root, model = sys.argv[1], sys.argv[2]
TYPES = (r"NVIDIA A100[^,\s]*|NVIDIA L40S|Quadro RTX 8000|Quadro RTX 6000"
         r"|Tesla V100[^,\s]*|NVIDIA A30|NVIDIA L4(?![0-9])")
best = {}
for csv_path in glob.glob(os.path.join(root, "results", "h1-*", "h1.csv")):
    d = os.path.dirname(csv_path)
    try:
        text = open(os.path.join(d, "instruments.txt")).read()
    except OSError:
        continue
    if "model=" + model not in text:
        continue
    g = re.search(TYPES, text)
    lv = re.search(r"levels=([0-9,]+)", text)
    if not g or not lv:
        continue
    top = max(int(x) for x in lv.group(1).split(",") if x)
    jid = re.search(r"h1-(\d+)", d)
    key = (top, int(jid.group(1)) if jid else 0)
    name = g.group(0).replace(" ", "_")
    if name not in best or key > best[name][0]:
        best[name] = (key, csv_path, lv.group(1))
args = []
for name in sorted(best):
    (top, _), path, levels = best[name]
    print("  curve for %s: %s (levels=%s, top %d)" % (name, path, levels, top),
          file=sys.stderr)
    args.append("%s=%s" % (path, name))
if args:
    print("--curves " + " ".join(args))
PYSEL
)"
echo "curves: $CURVE_ARGS"

# ----------------------------------------------------------------- Pass A
EP_CSV="$(IFS=,; echo "${PORTS[*]}")"
TY_CSV="$(IFS=,; echo "${EP_TYPES[*]}")"
echo
echo "endpoints: $EP_CSV"
echo "types:     $TY_CSV"

IFS=',' read -ra RATE_ARR <<< "$RATES"
for rate in "${RATE_ARR[@]}"; do
  n_req="$(python3 -c "import math;print(max(100, math.ceil($rate * $DURATION)))")"
  echo
  echo "=========== offered load ${rate} req/s, ${DURATION}s, ${n_req} requests ==========="
  env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3 \
    "$ROOT/scripts/policy_harness.py" \
      --endpoints "$EP_CSV" \
      --gpus "0" \
      --endpoint-types "$TY_CSV" \
      $CURVE_ARGS \
      --policies "$POLICIES" \
      --rate "$rate" --requests "$n_req" --slo "$SLO" \
      --workers "$WORKERS" --scratch "$RUN" --seed "$SEED" \
      --energy-mode multinode --sample-dir "$SAMPLES" --clock-skew "$SKEW" \
      --out "$RUN/policies-rate${rate}.json" 2>&1 | tee -a "$RUN/harness.log"
done

echo
echo "results in $RUN"
echo "  per-node energy samples: $SAMPLES/energy-*.jsonl"
echo "  measured clock skew:     $(cat "$RUN/skew_seconds.txt")s"
ls -l "$RUN"

# Explicit success. The EXIT trap runs after this, and an explicit 0 is
# what distinguishes "the sweep finished" from "something killed us".
exit 0
