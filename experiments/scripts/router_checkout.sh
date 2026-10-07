#!/usr/bin/env bash
# Reports what the llm-d-router checkout on the cluster actually is: remote,
# commit, and whether anything has been built from it. Read-only.
set -u
D="$HOME/energy-epp/llm-d-router"
if [ ! -d "$D" ]; then
  echo "no checkout at $D"
  exit 0
fi
cd "$D" || exit 1
echo "remote:  $(git remote get-url origin 2>/dev/null || echo none)"
echo "commit:  $(git log -1 --format='%h %cd %s' --date=short 2>/dev/null || echo none)"
echo "branch:  $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo none)"
echo "go.mod:  $(head -1 go.mod 2>/dev/null || echo none)"
echo "dirty:   $(git status --porcelain 2>/dev/null | wc -l) changed file(s)"
echo
echo "top level:"
ls | head -30 | sed 's/^/  /'
echo
echo "built binaries anywhere under it:"
find . -maxdepth 3 -type f -perm -u+x -newer go.mod ! -name '*.sh' 2>/dev/null | head -5 | sed 's/^/  /'
echo "  (nothing above means nothing has been built here)"
echo
echo "go toolchain on the login node: $(command -v go || echo none)"
echo
echo "any vLLM source checkout under energy-epp?"
find "$HOME/energy-epp" -maxdepth 2 -type d -name 'vllm*' ! -path '*/images/*' 2>/dev/null | head
echo "  (only the container image is expected: images/vllm-v0.30.0.sif)"
ls -la "$HOME/energy-epp/images/" 2>/dev/null | tail -n +2
