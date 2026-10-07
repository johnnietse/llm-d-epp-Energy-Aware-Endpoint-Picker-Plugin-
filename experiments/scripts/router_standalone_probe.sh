#!/usr/bin/env bash
# Read-only: does the llm-d-router checkout document a way to run the EPP
# without Kubernetes? Frontenac is Slurm with no Kubernetes and no privileges,
# so Stage 5's "stock llm-d" arm depends on the answer.
set -u
D="$HOME/energy-epp/llm-d-router"
cd "$D" || exit 1
echo "=== mentions of standalone / non-Kubernetes operation ==="
grep -rniE 'standalone|without kubernetes|no kubernetes|outside (of )?kubernetes|local mode|--kubeconfig|static (endpoints|pool)|endpoints-file|config-file' \
     --include='*.md' --include='*.go' . 2>/dev/null \
  | grep -v '_test.go' | head -25
echo
echo "=== cmd/ entrypoints ==="
ls cmd 2>/dev/null
echo
echo "=== EPP flags that look like endpoint discovery ==="
grep -rhoE 'flag\.(String|Bool|Int)\("[a-zA-Z-]+' cmd pkg 2>/dev/null \
  | sed 's/.*("//' | sort -u | grep -iE 'pool|endpoint|kube|static|standalone|config|discover' | head -25
