#!/bin/bash
#SBATCH --job-name=dcgm-fields
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --gres=gpu:1
#SBATCH --exclusive
#SBATCH --cpus-per-task=4
#SBATCH --mem=16G
#SBATCH --time=00:30:00
#SBATCH --output=%x-%j.out
#
# Two questions left open by job 12302781:
#
# 1. WHICH profiling field breaks dcgm-exporter for an unprivileged user?
#    The full shipped counter file fails, but minimal+DRAM_ACTIVE survived,
#    so "any profiling field breaks it" is wrong. Bisect one field at a time
#    and record, for each, whether the exporter stays up AND whether that
#    field actually appears in /metrics with a value. A field can be accepted
#    at watch time and still report nothing.
#
# 2. Does DCGM's energy field agree with NVML's counter on the same die?
#    If it does, DCGM is a usable second reader of the same counter, which is
#    worth stating in the methods section. It is not an independent sensor.

if ! command -v module >/dev/null 2>&1; then
  source /cvmfs/soft.computecanada.ca/config/profile/bash.sh 2>/dev/null \
    || source "${LMOD_PKG:-/cvmfs/soft.computecanada.ca/custom/software/lmod/lmod}/init/bash" 2>/dev/null
fi
set -uo pipefail

module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"

OPT="$HOME/energy-epp/opt"
OUT_DIR="$HOME/energy-epp/instruments-probe"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/dcgm-fields-${SLURM_JOB_ID:-nojob}.txt"
EXPORTER="$OPT/dcgm-exporter/usr/bin/dcgm-exporter"
SHIPPED="$OPT/dcgm-exporter/etc/dcgm-exporter/default-counters.csv"
IMG="$HOME/energy-epp/images/vllm-v0.30.0.sif"
export LD_LIBRARY_PATH="$OPT/dcgm4/usr/lib64:${LD_LIBRARY_PATH:-}"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

: > "$OUT"
say "=== which profiling field breaks the exporter? $(date -Is) ==="
say "node: $(hostname)  job: ${SLURM_JOB_ID:-none}"
say ""

BASE="$OUT_DIR/base-counters.csv"
grep -v '^\s*#' "$SHIPPED" | grep -v '^\s*$' | grep -v 'DCGM_FI_PROF_' > "$BASE"
say "baseline: $(wc -l < "$BASE") non-profiling fields (known good)"
say ""

PROF_FIELDS=$(grep -v '^\s*#' "$SHIPPED" | grep -oE 'DCGM_FI_PROF_[A-Z_]+' | sort -u)
say "profiling fields in the shipped file:"
printf '%s\n' "$PROF_FIELDS" | sed 's/^/  /' | tee -a "$OUT"
say ""

port=9420
for f in $PROF_FIELDS; do
  port=$((port + 1))
  csv="$OUT_DIR/bisect-$f.csv"
  cp "$BASE" "$csv"
  grep -v '^\s*#' "$SHIPPED" | grep "$f," >> "$csv"
  say "--- baseline + $f ---"
  "$EXPORTER" -f "$csv" --address ":$port" > "$OUT_DIR/bisect-$f.log" 2>&1 &
  pid=$!
  sleep 16
  if kill -0 "$pid" 2>/dev/null; then
    body="$(curl -fsS --max-time 15 "http://127.0.0.1:$port/metrics" 2>/dev/null)"
    n_energy="$(printf '%s' "$body" | grep -c '^DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION{' || true)"
    n_field="$(printf '%s' "$body" | grep -c "^$f{" || true)"
    say "exporter UP. energy series: $n_energy. $f series: $n_field"
    if [ "$n_field" -gt 0 ]; then
      printf '%s' "$body" | grep "^$f{" | head -2 \
        | sed -E 's/\{[^}]*gpu="([0-9]+)"[^}]*\}/ gpu=\1 =>/' | sed 's/^/    /' | tee -a "$OUT"
    fi
    kill "$pid" 2>/dev/null
  else
    say "exporter DIED. decisive line:"
    grep -E 'level=ERROR' "$OUT_DIR/bisect-$f.log" 2>/dev/null | head -2 | cut -c1-320 \
      | sed 's/^/    /' | tee -a "$OUT"
  fi
  sleep 2
  say ""
done

say "--- control: the full shipped file, all profiling fields together ---"
port=$((port + 1))
"$EXPORTER" -f "$SHIPPED" --address ":$port" > "$OUT_DIR/bisect-full.log" 2>&1 &
pid=$!
sleep 16
if kill -0 "$pid" 2>/dev/null; then
  say "exporter UP (unexpected, given job 12302781)"
  curl -fsS --max-time 15 "http://127.0.0.1:$port/metrics" 2>/dev/null \
    | grep -c '^DCGM_FI' | sed 's/^/    total series: /' | tee -a "$OUT"
  kill "$pid" 2>/dev/null
else
  say "exporter DIED, as in 12302781. decisive line:"
  grep -E 'level=ERROR' "$OUT_DIR/bisect-full.log" 2>/dev/null | head -1 | cut -c1-320 \
    | sed 's/^/    /' | tee -a "$OUT"
fi
say ""

say "=== DCGM energy versus NVML energy, same die, close in time ==="
say "# NVML first, then DCGM, then NVML again, so drift is visible"
env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3 -c '
import pynvml as n
n.nvmlInit()
h = n.nvmlDeviceGetHandleByIndex(0)
print("NVML_UUID", n.nvmlDeviceGetUUID(h))
print("NVML_ENERGY_mJ", n.nvmlDeviceGetTotalEnergyConsumption(h))
print("NVML_POWER_mW", n.nvmlDeviceGetPowerUsage(h))
' 2>&1 | grep -E '^NVML' | tee -a "$OUT"

DCGMI="$OPT/dcgm4/usr/bin/dcgmi"
HOSTENG="$OPT/dcgm4/usr/bin/nv-hostengine"
hport=5901
"$HOSTENG" -b 127.0.0.1 --port "$hport" -n > "$OUT_DIR/he-xcheck.log" 2>&1 &
hpid=$!
sleep 8
if kill -0 "$hpid" 2>/dev/null; then
  say "# DCGM reading of fields 156 (mJ) and 155 (W), GPU 0 only"
  "$DCGMI" dmon -e 156,155 -c 2 -d 1000 -i 0 --host "127.0.0.1:$hport" 2>&1 \
    | grep -E 'GPU|TOTEC' | tee -a "$OUT"
  kill "$hpid" 2>/dev/null
else
  say "host engine died during cross-check"
fi

env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3 -c '
import pynvml as n
n.nvmlInit()
h = n.nvmlDeviceGetHandleByIndex(0)
print("NVML_ENERGY_mJ_after", n.nvmlDeviceGetTotalEnergyConsumption(h))
' 2>&1 | grep -E '^NVML' | tee -a "$OUT"

say ""
say "=== done: $OUT ==="
