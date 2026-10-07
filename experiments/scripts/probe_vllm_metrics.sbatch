#!/bin/bash
#SBATCH --job-name=metrics-probe
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --time=00:06:00
#SBATCH --mem=16G
#SBATCH --gres=gpu:1
#SBATCH --output=%x-%j.out

# What are vLLM 0.30.0's actual Prometheus metric names?
#
# The latency cross-check reads "engine 0.0000" for TPOT, which means
# vllm:time_per_output_token_seconds does not exist in this build - I guessed
# the name instead of looking it up, which is the same mistake as every other
# unverified assumption in this project. TTFT works, so that name is right.
#
# Rather than start a server and curl /metrics (minutes, a GPU, and a model
# load), read the names straight out of the installed vllm package. They are
# string literals in its metrics module, so a grep settles it in seconds.
set -uo pipefail
module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null || true
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"
IMG="$HOME/energy-epp/images/vllm-v0.30.0.sif"

echo "node=$(hostname)"
echo
echo "=== every 'vllm:' metric name the package declares ==="
env -u SSL_CERT_FILE "$APPTAINER" exec "$IMG" bash -c '
  python3 - <<PY
import os, re, subprocess, sys, vllm
root = os.path.dirname(vllm.__file__)
print("vllm", vllm.__version__, "at", root)
names = set()
for dirpath, _, files in os.walk(root):
    for fn in files:
        if not fn.endswith(".py"):
            continue
        p = os.path.join(dirpath, fn)
        try:
            text = open(p, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        for m in re.finditer(r"[\"\x27](vllm:[a-zA-Z0-9_]+)[\"\x27]", text):
            names.add(m.group(1))
for n in sorted(names):
    print("  ", n)
print()
print("--- the ones this project needs ---")
for want in ("token", "latency", "e2e", "prefix", "running", "waiting"):
    hits = [n for n in sorted(names) if want in n]
    print("  %-10s %s" % (want, ", ".join(hits) if hits else "(none)"))
PY
' 2>&1 | tail -60
