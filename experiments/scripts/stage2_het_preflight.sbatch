#!/bin/bash
# Three-minute preflight for the heterogeneous multi-node experiment.
#
# Submit exactly as the real job, two components with different GPU types:
#   sbatch --gres=gpu:a100:1   --nodes=1 --mem=16G \
#        : --gres=gpu:rtx6000:1 --nodes=1 --mem=16G \
#          stage2_het_preflight.sbatch
#
# stage2_het.sbatch rests on four assumptions that have never been tested here,
# and it holds two nodes for up to five hours. Every one of them is cheap to
# check and expensive to discover late:
#
#   1. a Slurm heterogeneous allocation reports SLURM_HET_SIZE and lets
#      srun --het-group=N --overlap place work on each component;
#   2. the two components really carry different GPU types;
#   3. a process on one node can reach an HTTP port on the other - the whole
#      design depends on the generator driving remote vLLM servers, and
#      0.0.0.0 binding plus an open compute network are assumptions, not facts;
#   4. node_energy_sampler.py runs inside the container on both nodes and
#      produces readable cumulative counters.
#
# This is the lesson of job 12303653 applied in advance: that job held an
# 8-GPU node for 2h07m and produced nothing because a thing nobody had checked
# did not work. Checking costs three minutes.
#SBATCH --job-name=het-preflight
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --time=00:10:00
#SBATCH --output=%x-%j.out

set -uo pipefail
module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null || true
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"
ROOT="$HOME/energy-epp"
IMG="$ROOT/images/vllm-v0.30.0.sif"
RUN="$ROOT/results/hetpre-$SLURM_JOB_ID"
mkdir -p "$RUN"

FAIL=0
step() { printf '\n=== %s ===\n' "$1"; }
ok()   { echo "  [OK]   $1"; }
bad()  { echo "  [FAIL] $1"; FAIL=1; }

step "1. heterogeneous allocation"
echo "  SLURM_HET_SIZE=${SLURM_HET_SIZE:-unset}"
if [ -z "${SLURM_HET_SIZE:-}" ] || [ "${SLURM_HET_SIZE}" -lt 2 ]; then
  bad "not a heterogeneous allocation with >=2 components; submit with ':'"
  exit 1
fi
ok "het size ${SLURM_HET_SIZE}"

declare -a HOSTS TYPES
for g in $(seq 0 $((SLURM_HET_SIZE - 1))); do
  h="$(srun --het-group="$g" --nodes=1 --ntasks=1 hostname 2>/dev/null | head -1)"
  t="$(srun --het-group="$g" --nodes=1 --ntasks=1 \
       nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
  HOSTS[$g]="$h"; TYPES[$g]="$t"
  if [ -n "$h" ]; then ok "component $g: $h / ${t:-no-gpu-name}"
  else bad "component $g: srun --het-group=$g returned no hostname"; fi
done

step "2. the two components differ"
if [ "${TYPES[0]}" = "${TYPES[1]}" ]; then
  bad "both components are '${TYPES[0]}' - that is the homogeneous experiment"
else
  ok "'${TYPES[0]}' vs '${TYPES[1]}'"
fi

step "3. cross-node HTTP, which the whole design depends on"
# Plain python HTTP server on component 1, curled from component 0. Using the
# stdlib rather than vLLM keeps this fast and isolates networking from model
# loading - if this fails, nothing about vLLM is worth debugging yet.
PROBE_PORT=8399
srun --het-group=1 --nodes=1 --ntasks=1 --overlap \
  python3 -c "
import http.server, socketserver
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(b'pong')
    def log_message(self, *a): pass
socketserver.TCPServer(('0.0.0.0', $PROBE_PORT), H).serve_forever()
" > "$RUN/probe-server.log" 2>&1 &
SRV_PID=$!
sleep 8

got="$(srun --het-group=0 --nodes=1 --ntasks=1 --overlap \
       curl -fsS --max-time 5 "http://${HOSTS[1]}:$PROBE_PORT/" 2>&1)"
if [ "$got" = "pong" ]; then
  ok "component 0 reached component 1 at ${HOSTS[1]}:$PROBE_PORT"
else
  bad "component 0 could NOT reach ${HOSTS[1]}:$PROBE_PORT (got: ${got:0:80})"
  echo "       Without cross-node HTTP the generator cannot drive remote"
  echo "       servers, and the multi-node design does not work at all."
fi
# And the reverse direction, since the generator's placement is a free choice.
got2="$(srun --het-group=1 --nodes=1 --ntasks=1 --overlap \
        curl -fsS --max-time 5 "http://${HOSTS[1]}:$PROBE_PORT/" 2>&1)"
[ "$got2" = "pong" ] && ok "component 1 reached its own port" \
  || bad "component 1 could not reach its own port (got: ${got2:0:60})"
kill "$SRV_PID" 2>/dev/null
# No "srun ... pkill -f serve_forever" either: identical self-match hazard,
# and the probe server dies with the step that launched it.

step "4. per-node energy sampler inside the container"
mkdir -p "$RUN/samples"
for g in $(seq 0 $((SLURM_HET_SIZE - 1))); do
  srun --het-group="$g" --nodes=1 --ntasks=1 --overlap \
    env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" \
      python3 "$ROOT/scripts/node_energy_sampler.py" \
        --out "$RUN/samples/energy-${HOSTS[$g]}.jsonl" --interval 0.25 \
    > "$RUN/sampler-${HOSTS[$g]}.log" 2>&1 &
done
sleep 12
# Deliberately NOT pkill-ing the samplers.
#
# The first version did, and it cancelled its own job 21 seconds in:
#   srun ... pkill -f node_energy_sampler.py
# puts the pattern into the SRUN PROCESS'S OWN command line, so pkill matched
# and killed its own wrapper, which cascaded into
#   JOB 12304883 CANCELLED DUE to SIGNAL Terminated
# immediately after the three checks that had already passed.
#
# It is also unnecessary: the sampler flushes after every sample, so the file
# is complete and readable while the process still runs, and the samplers die
# with the allocation regardless.

for g in $(seq 0 $((SLURM_HET_SIZE - 1))); do
  f="$RUN/samples/energy-${HOSTS[$g]}.jsonl"
  n="$(wc -l < "$f" 2>/dev/null || echo 0)"
  if [ "${n:-0}" -ge 3 ]; then
    ok "sampler on ${HOSTS[$g]}: $n lines"
  else
    bad "sampler on ${HOSTS[$g]}: only ${n:-0} line(s); see $RUN/sampler-${HOSTS[$g]}.log"
    tail -5 "$RUN/sampler-${HOSTS[$g]}.log" 2>/dev/null | sed 's/^/         /'
  fi
done

step "5. stitch a window across both nodes"
python3 - "$RUN/samples" <<'PY'
import glob, importlib.util, json, os, sys
d = sys.argv[1]
spec = importlib.util.spec_from_file_location(
    "mne", os.path.expanduser("~/energy-epp/scripts/multinode_energy.py"))
mne = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mne)
# Use the overlap of all nodes' sample spans, trimmed, so the window is one
# every node genuinely covers.
spans = []
for p in sorted(glob.glob(os.path.join(d, "energy-*.jsonl"))):
    _, samples = mne.load(p)
    if samples:
        spans.append((samples[0]["t"], samples[-1]["t"]))
if len(spans) < 2:
    print("  [FAIL] fewer than two nodes produced samples")
    sys.exit(1)
t0 = max(s[0] for s in spans) + 0.5
t1 = min(s[1] for s in spans) - 0.5
if t1 <= t0:
    print("  [FAIL] node sample spans do not overlap; clocks or start times "
          "are too far apart")
    sys.exit(1)
agg = mne.aggregate(d, t0, t1, skew_s=0.0)
print("  window %.2fs across %d node(s), complete=%s"
      % (t1 - t0, agg["nodes_ok"], agg["complete"]))
for n in agg["nodes"]:
    if "error" in n:
        print("  [FAIL] %s: %s" % (n.get("host"), n["error"]))
    else:
        print("  [OK]   %-10s %7.1f J  %6.1f W  %d gpu(s)"
              % (n["host"], n["total_energy_j"], n["mean_power_w"],
                 len(n["per_gpu"])))
print("  fleet total: %.1f J" % agg["total_energy_j"])
sys.exit(0 if agg["complete"] else 1)
PY
[ $? -eq 0 ] && ok "cross-node energy stitching works" \
  || bad "cross-node energy stitching failed"

printf '\n==================================================\n'
if [ "$FAIL" -eq 0 ]; then
  echo "PREFLIGHT PASSED - stage2_het.sbatch can be submitted."
else
  echo "PREFLIGHT FAILED - fix the [FAIL] items before submitting the real"
  echo "job. It would hold two nodes for hours to rediscover the same thing."
fi
exit "$FAIL"
