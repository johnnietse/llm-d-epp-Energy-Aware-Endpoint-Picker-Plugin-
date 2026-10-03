#!/bin/bash
#SBATCH --job-name=dcgm-iso
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --gres=gpu:1
#SBATCH --exclusive
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=00:30:00
#SBATCH --output=%x-%j.out
#
# Resolve a contradiction in the earlier probes:
#
#   job 12302443: dcgm-exporter with the shipped counter file FAILED with
#                 "error watching fields: Host engine is running as non-root"
#   job 12302784: dcgm-exporter with the same shipped counter file SERVED all
#                 80 series including every profiling field
#   both jobs:    dcgmi against a standalone non-root nv-hostengine is refused
#                 for profiling fields with "Result: -29 ... requires the host
#                 engine to be running as root"
#
# The difference between the two exporter runs was the surrounding state: in
# 12302443 the exporter ran AFTER the script had started and killed two
# standalone nv-hostengine processes, and with their library directories
# prepended to LD_LIBRARY_PATH.
#
# Candidate explanations, tested below:
#   A. a clean embedded exporter simply works      -> expect UP
#   B. a previously-started-and-killed standalone
#      host engine poisons the next embedded run   -> C2 fails if true
#   C. a still-running standalone host engine
#      captures the exporter                       -> C3 fails if true
#   D. library path mixing (dcgm3 libs ahead of
#      dcgm4) breaks module loading                -> C4 fails if true
#
# Whatever the outcome, the conclusion to record is about EMBEDDED versus
# STANDALONE host engines, because that is the axis the two tools differ on.

if ! command -v module >/dev/null 2>&1; then
  source /cvmfs/soft.computecanada.ca/config/profile/bash.sh 2>/dev/null \
    || source "${LMOD_PKG:-/cvmfs/soft.computecanada.ca/custom/software/lmod/lmod}/init/bash" 2>/dev/null
fi
set -uo pipefail

OPT="$HOME/energy-epp/opt"
OUT_DIR="$HOME/energy-epp/instruments-probe"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/dcgm-isolate-${SLURM_JOB_ID:-nojob}.txt"
EXPORTER="$OPT/dcgm-exporter/usr/bin/dcgm-exporter"
SHIPPED="$OPT/dcgm-exporter/etc/dcgm-exporter/default-counters.csv"
DCGM4_LIB="$OPT/dcgm4/usr/lib64"
DCGM3_LIB="$OPT/dcgm3/usr/lib64"
DCGMI4="$OPT/dcgm4/usr/bin/dcgmi"
HOSTENG4="$OPT/dcgm4/usr/bin/nv-hostengine"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

: > "$OUT"
say "=== embedded versus standalone DCGM host engine, $(date -Is) ==="
say "node: $(hostname)  job: ${SLURM_JOB_ID:-none}"
say ""

# Returns 0 and prints a summary if the exporter serves profiling fields.
try_exporter() {
  local label="$1" port="$2"
  "$EXPORTER" -f "$SHIPPED" --address ":$port" > "$OUT_DIR/iso-$label.log" 2>&1 &
  local pid=$!
  sleep 16
  if kill -0 "$pid" 2>/dev/null; then
    local body n_all n_prof
    body="$(curl -fsS --max-time 15 "http://127.0.0.1:$port/metrics" 2>/dev/null)"
    n_all="$(printf '%s' "$body" | grep -c '^DCGM_FI' || true)"
    n_prof="$(printf '%s' "$body" | grep -c '^DCGM_FI_PROF' || true)"
    say "  RESULT: exporter UP. total series $n_all, profiling series $n_prof"
    kill "$pid" 2>/dev/null
  else
    say "  RESULT: exporter DIED."
    grep -E 'level=ERROR' "$OUT_DIR/iso-$label.log" 2>/dev/null | head -1 \
      | grep -oE 'error=".*"|err: .*' | cut -c1-200 | sed 's/^/    /' | tee -a "$OUT"
    grep -oE 'Host engine is running as non-root' "$OUT_DIR/iso-$label.log" 2>/dev/null \
      | head -1 | sed 's/^/    matched: /' | tee -a "$OUT"
  fi
  sleep 3
}

say "--- C1: clean embedded exporter, only dcgm4 libs on the path ---"
export LD_LIBRARY_PATH="$DCGM4_LIB"
try_exporter c1-clean 9430
say ""

say "--- C2: after a standalone non-root host engine has been started and killed ---"
export LD_LIBRARY_PATH="$DCGM4_LIB"
"$HOSTENG4" -b 127.0.0.1 --port 5911 -n > "$OUT_DIR/iso-he-c2.log" 2>&1 &
he=$!
sleep 8
say "  host engine pid $he alive: $(kill -0 "$he" 2>/dev/null && echo yes || echo no)"
say "  and for the record, what dcgmi sees through it for a profiling field:"
"$DCGMI4" dmon -e 1005 -c 2 -d 1000 -i 0 --host "127.0.0.1:5911" 2>&1 \
  | grep -E 'Error|DRAMA|GPU ' | head -3 | sed 's/^/    /' | tee -a "$OUT"
kill "$he" 2>/dev/null
wait "$he" 2>/dev/null
sleep 4
try_exporter c2-after-killed-standalone 9431
say ""

say "--- C3: while a standalone non-root host engine is still running ---"
"$HOSTENG4" -b 127.0.0.1 --port 5912 -n > "$OUT_DIR/iso-he-c3.log" 2>&1 &
he=$!
sleep 8
try_exporter c3-with-standalone-running 9432
kill "$he" 2>/dev/null
sleep 3
say ""

say "--- C4: dcgm3 libraries ahead of dcgm4 on the path, as in job 12302443 ---"
export LD_LIBRARY_PATH="$DCGM3_LIB:$DCGM4_LIB"
try_exporter c4-mixed-libs 9433
say ""

say "--- C5: the same profiling field through the embedded path, via dcgmi against"
say "        a host engine we did NOT start (there is none), to confirm dcgmi always"
say "        needs a standalone engine and therefore always hits the root check ---"
export LD_LIBRARY_PATH="$DCGM4_LIB"
"$DCGMI4" dmon -e 1005 -c 2 -d 1000 -i 0 2>&1 | head -6 | sed 's/^/    /' | tee -a "$OUT"
say ""

say "=== how to read this ==="
say "If C1 and C4 both pass and only C2/C3 fail, the earlier failure was caused by"
say "a standalone host engine in the same job, not by privilege. If every exporter"
say "case passes, then the embedded host engine is simply privileged enough and the"
say "root check applies only to the standalone daemon that dcgmi requires."
say ""
say "=== done: $OUT ==="
