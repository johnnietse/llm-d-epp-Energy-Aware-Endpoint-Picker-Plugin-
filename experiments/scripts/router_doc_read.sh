#!/usr/bin/env bash
# Read-only: prints the router's own documentation for running EPP without
# Kubernetes, so the Stage 4/5 plan rests on what the docs say, not on memory.
set -u
D="$HOME/energy-epp/llm-d-router/docs/discovery.md"
sed -n '386,480p' "$D"
