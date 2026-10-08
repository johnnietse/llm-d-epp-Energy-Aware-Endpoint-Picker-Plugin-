#!/usr/bin/env bash
# Builds the EPP for Frontenac (static linux/amd64) reproducibly, and writes
# its sha256 next to it. Run from anywhere; output goes to router-plugin/bin/.
#
# -buildvcs=false is what makes this reproducible. Without it Go embeds the
# repository's commit and a "modified" flag in the binary, so the same source
# gives a different hash at every commit, and a build from an uncommitted tree
# cannot be reproduced from any commit at all. That is exactly what happened to
# the first build (sha256 f3f2aa63..., vcs.revision=9775cc3, vcs.modified=true),
# found on 2026-10-08 when a rebuild produced a different hash.
#
# -trimpath drops local file paths; -s -w drop the symbol table and DWARF.
# Go 1.26.6 is the router's minimum and GOTOOLCHAIN=auto fetches it.
set -eu
cd "$(dirname "$0")"
mkdir -p bin
GOTOOLCHAIN=auto CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -buildvcs=false -trimpath -ldflags "-s -w" -o bin/epp-linux-amd64 ./cmd/epp
sha256sum bin/epp-linux-amd64 | tee bin/epp-linux-amd64.sha256
GOTOOLCHAIN=auto go version -m bin/epp-linux-amd64 | grep -E 'go1|llm-d-router|buildvcs|CGO_ENABLED'
