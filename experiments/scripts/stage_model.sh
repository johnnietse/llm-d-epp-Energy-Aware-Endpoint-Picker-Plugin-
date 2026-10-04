#!/bin/bash
# Pre-stages a HuggingFace model into HF_HOME from the LOGIN node.
#
# Why not inside the job: a 15 GB download would waste an --exclusive node
# reservation, and compute nodes may have no outbound route.
#
# Why not via the container: apptainer cannot start on the login node here -
# "Failed to create user namespace: maximum number of user namespaces exceeded".
# So this uses the login node's own python plus a --user install of
# huggingface_hub, which needs no privileges.
#
# Must run as a CHILD process (bash stage_model.sh ...), never sourced: the
# Compute Canada profile terminates an interactive SSH shell if sourced into it.
#
# Usage: bash stage_model.sh Qwen/Qwen2.5-7B-Instruct

MODEL="${1:-Qwen/Qwen2.5-7B-Instruct}"
ROOT="$HOME/energy-epp"
export HF_HOME="$ROOT/.hf"
mkdir -p "$ROOT/logs" "$HF_HOME"
SLUG="$(echo "$MODEL" | tr '/' '-')"
LOG="$ROOT/logs/hf-stage-$SLUG.log"

# Prefer the newest system python that has a working pip.
PY=""
for cand in /usr/bin/python3.11 /usr/bin/python3; do
  [ -x "$cand" ] || continue
  if "$cand" -m pip --version >/dev/null 2>&1; then
    PY="$cand"
    break
  fi
done
if [ -z "$PY" ]; then
  echo "FATAL: no python with pip on the login node"
  exit 1
fi
echo "python: $PY ($("$PY" -V 2>&1))"

if ! "$PY" -c "import huggingface_hub" >/dev/null 2>&1; then
  echo "installing huggingface_hub --user (no privileges needed)"
  "$PY" -m pip install --user --quiet huggingface_hub 2>&1 | tail -3
fi
"$PY" -c "import huggingface_hub; print('huggingface_hub', huggingface_hub.__version__)" || exit 1

echo "HF_HOME: $HF_HOME"
echo "cache before: $(du -sh "$HF_HOME" 2>/dev/null | cut -f1)"
echo "log: $LOG"

nohup "$PY" - "$MODEL" > "$LOG" 2>&1 <<'PY' &
import sys
from huggingface_hub import snapshot_download
path = snapshot_download(
    sys.argv[1],
    allow_patterns=["*.json", "*.safetensors", "*.txt", "*.model"],
    max_workers=4,
)
print("DOWNLOADED", path, flush=True)
PY
PID=$!
echo "started pid $PID"
sleep 25
if kill -0 "$PID" 2>/dev/null; then
  echo "still running after 25s (expected: ~15 GB)"
  echo "cache now: $(du -sh "$HF_HOME" 2>/dev/null | cut -f1)"
  echo "--- log tail ---"
  tail -3 "$LOG" 2>/dev/null
else
  echo "exited within 25s; log:"
  tail -20 "$LOG" 2>/dev/null
fi
