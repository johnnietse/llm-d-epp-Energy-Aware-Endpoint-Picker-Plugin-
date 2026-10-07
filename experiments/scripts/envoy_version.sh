#!/usr/bin/env bash
# Reports the Envoy version inside images/envoy.sif. The router's file-discovery
# docs require Envoy v1.31 or later for the ext_proc features the EPP uses, and
# the image was pulled 2026-10-03 without anyone checking what it contains.
# Read-only; runs one `envoy --version` in the container on the login node.
set -u
module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"
IMG="$HOME/energy-epp/images/envoy.sif"
[ -f "$IMG" ] || { echo "no image at $IMG"; exit 1; }
echo "image: $IMG ($(stat -c %s "$IMG") bytes, $(stat -c %y "$IMG" | cut -d. -f1))"
echo "--- labels ---"
"$APPTAINER" inspect --labels "$IMG" 2>/dev/null | grep -iE 'version|source|created|org.opencontainers' | head -8
echo "--- envoy --version ---"
"$APPTAINER" exec "$IMG" envoy --version 2>&1 | tail -3
