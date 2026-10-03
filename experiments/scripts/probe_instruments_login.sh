#!/bin/bash
# Discovery pass for alternative GPU instrumentation on Frontenac.
# Runs on the LOGIN node (needs outbound network; compute nodes may not have it).
# Writes everything it learns to ~/energy-epp/instruments-probe/login.txt
#
# Facts this script relies on, measured on 2026-10-03 rather than assumed:
#   - nodes are Rocky Linux 8.10, glibc 2.28  => RHEL8 RPMs, not Ubuntu debs
#   - the Compute Canada stack is bootstrapped from
#     /cvmfs/soft.computecanada.ca/config/profile/bash.sh
#   - the cluster pip is too old for "pip index", so PyPI is queried over HTTP
#
# Nothing here installs into a system path.

OUT_DIR="$HOME/energy-epp/instruments-probe"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/login.txt"

# Lmod bootstrap must happen before set -u: the CC profile reads unset vars.
if ! command -v module >/dev/null 2>&1; then
  source /cvmfs/soft.computecanada.ca/config/profile/bash.sh 2>/dev/null \
    || source "${LMOD_PKG:-/cvmfs/soft.computecanada.ca/custom/software/lmod/lmod}/init/bash" 2>/dev/null
fi
set -uo pipefail

REPO="https://developer.download.nvidia.com/compute/cuda/repos/rhel8/x86_64"

say() { printf '%s\n' "$*" | tee -a "$OUT"; }

: > "$OUT"
say "=== instrumentation discovery, login node, $(date -Is) ==="
say "host: $(hostname)"
say "os: $(grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2-)"
say "glibc: $(ldd --version | head -1)"
say "module: $(type -t module 2>/dev/null || echo MISSING)"
say ""

say "--- 1. does the module system already carry any of these? ---"
for pkg in dcgm nsight cuda ipmi papi likwid; do
  say "# module spider $pkg"
  module spider "$pkg" 2>&1 | grep -v -E '^\s*$' | head -15 | tee -a "$OUT"
  say ""
done

say "--- 2. binaries in a module-enabled shell ---"
for b in dcgmi nv-hostengine nsys ncu ipmitool nvidia-smi apptainer rpm2cpio cpio curl; do
  p="$(command -v "$b" 2>/dev/null || true)"
  say "$b: ${p:-MISSING}"
done
say ""

say "--- 3. driver version we must stay compatible with ---"
say "# from the instruments.txt recorded by an earlier GPU job"
grep -h -i -m 4 -E 'driver|cuda|gpu' "$HOME"/energy-epp/results/*/instruments.txt 2>/dev/null \
  | head -8 | tee -a "$OUT"
say ""

say "--- 4. DCGM packages published for RHEL8 ---"
curl -fsSL --max-time 90 "$REPO/" 2>/dev/null \
  | grep -oE '[a-z0-9._+-]*datacenter-gpu-manager[a-z0-9._+-]*\.rpm' \
  | sort -u -V | tee -a "$OUT"
say ""

say "--- 5. Nsight Systems packages for RHEL8 (glibc 2.28 may refuse the new ones) ---"
curl -fsSL --max-time 90 "$REPO/" 2>/dev/null \
  | grep -oE 'nsight-systems-[a-z0-9._+-]*\.rpm' \
  | sort -u -V | tail -12 | tee -a "$OUT"
say ""

say "--- 6. CUPTI packages for RHEL8 (the container already has one via torch) ---"
curl -fsSL --max-time 90 "$REPO/" 2>/dev/null \
  | grep -oE 'cuda-cupti-[0-9a-z._+-]*\.rpm' \
  | sort -u -V | tail -8 | tee -a "$OUT"
say ""

say "--- 7. PyPI, queried over HTTP since this pip has no 'index' subcommand ---"
for proj in nvidia-dcgm nvidia-ml-py nvidia-cuda-cupti-cu12; do
  say "# $proj"
  curl -fsSL --max-time 60 "https://pypi.org/pypi/$proj/json" 2>/dev/null \
    | python3 -c "import json,sys
try:
    d = json.load(sys.stdin)
    print('  latest:', d['info']['version'])
    print('  summary:', (d['info']['summary'] or '')[:90])
except Exception as e:
    print('  not on PyPI or query failed:', e)" | tee -a "$OUT"
done
say ""

say "--- 8. IPMI device node on this host ---"
ls -l /dev/ipmi0 /dev/ipmi/0 /dev/ipmidev/0 2>&1 | tee -a "$OUT"
say ""

say "=== done: $OUT ==="
