#!/bin/bash
# Discovery pass for alternative GPU instrumentation on Frontenac.
# Runs on the LOGIN node (needs outbound network; compute nodes may not have it).
# Writes everything it learns to ~/energy-epp/instruments-probe/login.txt
#
# Nothing here installs into a system path. Everything lands under
# ~/energy-epp/opt so it can be deleted with one rm -rf.

OUT_DIR="$HOME/energy-epp/instruments-probe"
OPT_DIR="$HOME/energy-epp/opt"
mkdir -p "$OUT_DIR" "$OPT_DIR"
OUT="$OUT_DIR/login.txt"

# Lmod bootstrap must happen before set -u: the CC profile reads unset vars.
if [ -f /opt/software/cc-wrapper/profile.sh ]; then
  . /opt/software/cc-wrapper/profile.sh
elif [ -f /etc/profile.d/z-01-cc-modules.sh ]; then
  . /etc/profile.d/z-01-cc-modules.sh
fi
set -uo pipefail

say() { printf '%s\n' "$*" | tee -a "$OUT"; }
run() { say "\$ $*"; "$@" 2>&1 | tee -a "$OUT"; say ""; }

: > "$OUT"
say "=== instrumentation discovery, login node, $(date -Is) ==="
say "host: $(hostname)"
say ""

say "--- 1. what the module system offers ---"
for pkg in dcgm nsight nsight-systems nsight-compute cuda ipmitool papi likwid; do
  say "# module spider $pkg"
  module spider "$pkg" 2>&1 | head -40 | tee -a "$OUT"
  say ""
done

say "--- 2. binaries already on PATH ---"
for b in dcgmi nv-hostengine nsys ncu ipmitool nvidia-smi apptainer singularity podman docker; do
  p="$(command -v "$b" 2>/dev/null || true)"
  say "$b: ${p:-MISSING}"
done
say ""

say "--- 3. CUPTI shipped with the stack ---"
say "# any libcupti on the filesystem we can see"
{ ls -l /usr/local/cuda*/extras/CUPTI/lib64/libcupti.so* 2>/dev/null; \
  find "$HOME" -maxdepth 6 -name 'libcupti.so*' 2>/dev/null | head; } | tee -a "$OUT"
say ""

say "--- 4. profiling permission (decides CUPTI / Nsight / DCGM-DCP) ---"
say "# RmProfilingAdminOnly=1 means non-root profiling counters are denied"
if [ -r /proc/driver/nvidia/params ]; then
  grep -E 'RmProfilingAdminOnly|RmEnableUnifiedMemory' /proc/driver/nvidia/params | tee -a "$OUT"
else
  say "/proc/driver/nvidia/params not readable on this node (expected on a login node)"
fi
say ""

say "--- 5. IPMI device nodes ---"
run ls -l /dev/ipmi0 /dev/ipmi/0 /dev/ipmidev/0

say "--- 6. what NVIDIA's apt repo actually publishes (no guessed versions) ---"
REPO="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64"
say "# datacenter-gpu-manager packages in $REPO"
curl -fsSL --max-time 60 "$REPO/" 2>/dev/null \
  | grep -oE 'datacenter-gpu-manager[^"]*\.deb' | sort -u | tail -20 | tee -a "$OUT"
say ""
say "# nsight-systems packages in the same repo"
curl -fsSL --max-time 60 "$REPO/" 2>/dev/null \
  | grep -oE 'nsight-systems[^"]*\.deb' | sort -u | tail -10 | tee -a "$OUT"
say ""
say "# cuda-cupti packages in the same repo"
curl -fsSL --max-time 60 "$REPO/" 2>/dev/null \
  | grep -oE 'cuda-cupti[^"]*\.deb' | sort -u | tail -10 | tee -a "$OUT"
say ""

say "--- 7. pip wheels (CUPTI is a torch dependency, so this should exist) ---"
PY="$(command -v python3 || true)"
if [ -n "$PY" ]; then
  run "$PY" -m pip index versions nvidia-cuda-cupti-cu12
  run "$PY" -m pip index versions nvidia-dcgm
else
  say "no python3 on PATH before module load"
fi

say "=== done. Next: read $OUT, then pick the download targets. ==="
