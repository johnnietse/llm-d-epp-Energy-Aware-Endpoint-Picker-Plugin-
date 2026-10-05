#!/usr/bin/env bash
# Where do the model weights actually live?
#
# The scratch probe reported the HF cache directory as 12 MB while vLLM's own
# log says "Checkpoint size: 2.88 GiB". One of those is wrong about the path,
# and the answer matters twice: the pre-warm check in stage2_het.sbatch would
# abort the job if it looks in the wrong place, and node-local staging needs
# the real source directory.
#
# HF's cache keeps real files in blobs/ and exposes snapshots/ as symlinks into
# them, so a du that does not resolve links, or a find for *.safetensors that
# only matches the symlink names, can both mislead.
set -u
echo "HF_HOME=${HF_HOME:-UNSET}"
echo "HOME=$HOME"
echo

for base in "$HOME/energy-epp/.hf" "$HOME/.cache/huggingface" "${HF_HOME:-}"; do
  [ -n "$base" ] && [ -d "$base" ] || continue
  echo "=== $base"
  echo "  apparent size (du -sh):        $(du -sh "$base" 2>/dev/null | cut -f1)"
  echo "  dereferenced size (du -shL):   $(du -shL "$base" 2>/dev/null | cut -f1)"
  echo "  safetensors by name:"
  find "$base" -name '*.safetensors' 2>/dev/null | head -8 | sed 's/^/    /'
  echo "  largest 6 regular files, following links:"
  find "$base" -type f -size +10M 2>/dev/null | head -40 \
    | xargs -r -I{} stat -c '%s %n' {} 2>/dev/null | sort -rn | head -6 \
    | awk '{printf "    %8.2f MiB  %s\n", $1/1048576, $2}'
  echo "  blobs dir:"
  find "$base" -type d -name blobs 2>/dev/null | head -3 | sed 's/^/    /'
  echo
done

echo "=== every file over 100 MiB anywhere under \$HOME (the weights must be one) ==="
find "$HOME" -xdev -type f -size +100M 2>/dev/null | head -20 \
  | xargs -r -I{} stat -c '%s %n' {} 2>/dev/null | sort -rn \
  | awk '{printf "  %8.2f MiB  %s\n", $1/1048576, $2}'
