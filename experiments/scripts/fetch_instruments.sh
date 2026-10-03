#!/bin/bash
# Downloads the alternative telemetry tools into user space on Frontenac and
# extracts them without root. Run on the LOGIN node (compute nodes may have no
# outbound network).
#
# Everything lands under ~/energy-epp/opt and is removable with one rm -rf.
# Nothing is installed system-wide and no privileges are requested.
#
# Package choices come from the repo listing made by probe_instruments_login.sh
# on 2026-10-03, not from memory:
#   - DCGM 3.3.9    : last 3.x, ships dcgmi + nv-hostengine + libdcgm in ONE rpm
#   - DCGM 4.7.0    : current major, split into -core and CUDA-specific parts
#   - DCGM exporter : the Prometheus exporter upstream llm-d scrapes
#   - Nsight 2025.6.3 : deliberately not the newest, for glibc odds (CVMFS=2.37)
# RHEL8 artifacts, because these nodes are Rocky Linux 8.10.

if ! command -v module >/dev/null 2>&1; then
  source /cvmfs/soft.computecanada.ca/config/profile/bash.sh 2>/dev/null \
    || source "${LMOD_PKG:-/cvmfs/soft.computecanada.ca/custom/software/lmod/lmod}/init/bash" 2>/dev/null
fi
set -uo pipefail

REPO="https://developer.download.nvidia.com/compute/cuda/repos/rhel8/x86_64"
OPT="$HOME/energy-epp/opt"
DL="$OPT/downloads"
LOG="$HOME/energy-epp/instruments-probe/fetch.txt"
mkdir -p "$DL" "$(dirname "$LOG")"

say() { printf '%s\n' "$*" | tee -a "$LOG"; }

: > "$LOG"
say "=== fetch instrumentation into user space, $(date -Is) ==="
say ""

say "--- disk space before ---"
( quota -s 2>/dev/null || diskusage_report 2>/dev/null || du -sh "$HOME" 2>/dev/null ) | head -10 | tee -a "$LOG"
say ""

# name:destination pairs
PKGS="
datacenter-gpu-manager-3.3.9-1-x86_64.rpm:dcgm3
datacenter-gpu-manager-4-core-4.7.0-1.x86_64.rpm:dcgm4
datacenter-gpu-manager-4-cuda12-4.7.0-1.x86_64.rpm:dcgm4
datacenter-gpu-manager-exporter-4.8.4.3955-1.x86_64.rpm:dcgm-exporter
nsight-systems-2025.6.3-2025.6.3.541_3773601-0.x86_64.rpm:nsight
"

for entry in $PKGS; do
  rpmname="${entry%%:*}"
  dest="${entry##*:}"
  say "--- $rpmname -> $OPT/$dest ---"
  if [ -f "$DL/$rpmname" ]; then
    say "already downloaded"
  else
    curl -fL --retry 2 --max-time 1800 -o "$DL/$rpmname" "$REPO/$rpmname" \
      || { say "DOWNLOAD FAILED: $rpmname"; continue; }
  fi
  say "size: $(du -h "$DL/$rpmname" | cut -f1)"
  say "sha256: $(sha256sum "$DL/$rpmname" | cut -d' ' -f1)"
  mkdir -p "$OPT/$dest"
  ( cd "$OPT/$dest" && rpm2cpio "$DL/$rpmname" | cpio -idm --quiet ) \
    && say "extracted ok" || say "EXTRACT FAILED"
  say ""
done

say "--- what we got: binaries ---"
find "$OPT" -type f \( -name 'dcgmi' -o -name 'nv-hostengine' -o -name 'nsys' \
  -o -name 'dcgm-exporter' -o -name 'ncu' \) 2>/dev/null \
  | while read -r f; do say "$f ($(file -b "$f" | cut -c1-40))"; done
say ""

say "--- what we got: libraries ---"
find "$OPT" -name 'libdcgm*.so*' 2>/dev/null | head | tee -a "$LOG"
say ""

say "--- does dcgmi even start here? (login node has no GPU, so expect a clean refusal, not a crash) ---"
for v in dcgm3 dcgm4; do
  DBIN="$(find "$OPT/$v" -type f -name dcgmi 2>/dev/null | head -1)"
  DLIB="$(dirname "$(find "$OPT/$v" -name 'libdcgm.so*' 2>/dev/null | head -1)" 2>/dev/null)"
  if [ -n "$DBIN" ]; then
    say "# $v: $DBIN (libs: ${DLIB:-none found})"
    LD_LIBRARY_PATH="${DLIB:-}:${LD_LIBRARY_PATH:-}" "$DBIN" --version 2>&1 | head -5 | tee -a "$LOG"
    say ""
  fi
done

say "--- does nsys start here? (this is the glibc test) ---"
NSYS="$(find "$OPT/nsight" -type f -name nsys 2>/dev/null | head -1)"
if [ -n "$NSYS" ]; then
  say "# $NSYS"
  "$NSYS" --version 2>&1 | head -5 | tee -a "$LOG"
else
  say "nsys binary not found in the extracted tree"
fi
say ""

say "--- disk space after ---"
du -sh "$OPT" 2>/dev/null | tee -a "$LOG"
say ""
say "=== done: $LOG ==="
say "Remove everything with: rm -rf $OPT"
