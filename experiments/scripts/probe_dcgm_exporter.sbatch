#!/bin/bash
#SBATCH --job-name=dcgm-exp
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --gres=gpu:1
#SBATCH --exclusive
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=00:20:00
#SBATCH --output=%x-%j.out
#
# Hypothesis under test: dcgm-exporter fails for an unprivileged user not
# because DCGM denies power and energy, but because DCGM watches a field GROUP
# atomically and the shipped counter files include profiling fields
# (dram_active = 1005) that do require root. If so, a counter file containing
# only non-privileged fields should work, and adding 1005 back should break it
# again.
#
# This matters because dcgm-exporter is the path upstream llm-d scrapes
# (dcgm-data-source), so a working unprivileged exporter means we can use the
# same integration surface upstream uses.

if ! command -v module >/dev/null 2>&1; then
  source /cvmfs/soft.computecanada.ca/config/profile/bash.sh 2>/dev/null \
    || source "${LMOD_PKG:-/cvmfs/soft.computecanada.ca/custom/software/lmod/lmod}/init/bash" 2>/dev/null
fi
set -uo pipefail

OPT="$HOME/energy-epp/opt"
OUT_DIR="$HOME/energy-epp/instruments-probe"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/dcgm-exporter-${SLURM_JOB_ID:-nojob}.txt"
EXPORTER="$OPT/dcgm-exporter/usr/bin/dcgm-exporter"
export LD_LIBRARY_PATH="$OPT/dcgm4/usr/lib64:${LD_LIBRARY_PATH:-}"

MINIMAL="$OUT_DIR/counters-unprivileged.csv"
PLUS_DCP="$OUT_DIR/counters-plus-dram.csv"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

: > "$OUT"
say "=== dcgm-exporter under an unprivileged host engine, $(date -Is) ==="
say "node: $(hostname)  job: ${SLURM_JOB_ID:-none}"
say ""

# Derive the minimal file FROM the shipped one rather than typing field names,
# because an invented name (DCGM_FI_DEV_MEMORY_CLOCK, which does not exist)
# aborts the exporter before it ever reaches the privilege question.
SHIPPED="$OPT/dcgm-exporter/etc/dcgm-exporter/default-counters.csv"
grep -v '^\s*#' "$SHIPPED" | grep -v '^\s*$' | grep -v 'DCGM_FI_PROF_' > "$MINIMAL"
say "shipped counter file: $SHIPPED"
say "minimal file keeps $(wc -l < "$MINIMAL") non-profiling fields; dropped:"
grep -v '^\s*#' "$SHIPPED" | grep 'DCGM_FI_PROF_' | sed 's/^/  /' | tee -a "$OUT"
say ""

# Same list plus the one profiling field, to test the atomicity explanation.
cp "$MINIMAL" "$PLUS_DCP"
grep -v '^\s*#' "$SHIPPED" | grep 'DCGM_FI_PROF_DRAM_ACTIVE' >> "$PLUS_DCP"

run_exporter() {
  local label="$1" csv="$2" port="$3"
  say "--- $label ($(grep -c . "$csv") fields) ---"
  "$EXPORTER" -f "$csv" --address ":$port" > "$OUT_DIR/exp-$label.log" 2>&1 &
  local pid=$!
  sleep 18
  if kill -0 "$pid" 2>/dev/null; then
    say "exporter ALIVE; scraping /metrics"
    curl -fsS --max-time 20 "http://127.0.0.1:$port/metrics" 2>&1 \
      | grep -E '^DCGM_FI_(DEV|PROF)' | head -20 | tee -a "$OUT"
    say ""
    say "# does the energy counter actually carry a value?"
    curl -fsS --max-time 20 "http://127.0.0.1:$port/metrics" 2>&1 \
      | grep -E 'TOTAL_ENERGY|POWER_USAGE' | head -10 | tee -a "$OUT"
    kill "$pid" 2>/dev/null
    sleep 3
  else
    say "exporter EXITED. decisive lines from its log:"
    grep -E 'level=(ERROR|FATAL)' "$OUT_DIR/exp-$label.log" 2>/dev/null \
      | head -4 | cut -c1-400 | tee -a "$OUT"
  fi
  say ""
}

run_exporter "unprivileged-only" "$MINIMAL" 9414
run_exporter "plus-dram-active"  "$PLUS_DCP" 9415

say "=== interpretation ==="
say "If 'unprivileged-only' served metrics and 'plus-dram-active' did not, then"
say "DCGM's field-group watch is atomic and the exporter is usable without root"
say "as long as the counter file excludes profiling fields."
say ""
say "=== done: $OUT ==="
