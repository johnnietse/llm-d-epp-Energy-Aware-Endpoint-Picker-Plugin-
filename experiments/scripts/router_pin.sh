#!/usr/bin/env bash
# Pins the cluster's llm-d-router clone to the same release the EPP binary is
# built from, so configs extracted from it and the binary describe one version.
# Until 2026-10-07 the clone sat at 297bfb0 (main, 2026-10-02), the repo
# submodule at e149f34f, and the build at v0.11.0: three official-source copies
# at three different commits.
set -u
TAG="${1:-v0.11.0}"
cd "$HOME/energy-epp/llm-d-router" || { echo "no clone"; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "REFUSING: clone has local changes"; git status --short | head; exit 1; }
echo "before: $(git rev-parse --short HEAD) $(git describe --tags --always 2>/dev/null)"
git fetch --quiet --tags origin || { echo "FATAL: fetch failed"; exit 1; }
git -c advice.detachedHead=false checkout --quiet "$TAG" || { echo "FATAL: no tag $TAG"; exit 1; }
echo "after:  $(git rev-parse --short HEAD) $(git describe --tags --always 2>/dev/null)"
echo "tag commit: $(git rev-list -n 1 "$TAG")"
[ -f docs/discovery.md ] && echo "docs/discovery.md present ($(wc -l < docs/discovery.md) lines)"
