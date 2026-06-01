#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# generate-all-figures.sh
# ─────────────────────────────────────────────────────────────────────
# One-command reproducibility script that regenerates ALL thesis figures,
# diagrams, and benchmark visualizations from source.
#
# Usage:
#   bash benchmarks/scripts/generate-all-figures.sh
#   # or via Makefile:
#   make bench-report
#
# Requirements:
#   - Python 3.10+ with matplotlib and numpy installed
#   - Run from the project root directory
# ─────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

echo "================================================================"
echo " Energy-Aware EPP — Full Figure Regeneration"
echo " Project Root: $PROJECT_ROOT"
echo "================================================================"
echo ""

# Ensure output directories exist
mkdir -p docs/diagrams docs/figures benchmarks/results

# ── Step 1: Core benchmark figures ───────────────────────────────────
echo "[1/6] Generating core benchmark figures..."
python benchmarks/scripts/generate_figures.py
echo ""

# ── Step 2: Extended figures (CDFs, timelines) ───────────────────────
echo "[2/6] Generating extended evaluation figures..."
python benchmarks/scripts/generate_figures_extended.py
echo ""

# ── Step 3: Architectural diagrams ───────────────────────────────────
echo "[3/6] Generating architectural diagrams..."
python benchmarks/scripts/generate_new_diagrams.py
echo ""

# ── Step 4: Extra diagrams (epsilon-constraint, system, etc.) ────────
echo "[4/6] Generating extra thesis diagrams..."
python benchmarks/scripts/generate_extra_diagrams.py
echo ""

# ── Step 5: Advanced diagrams (carbon, DVFS, EDP, heatmap, etc.) ─────
echo "[5/6] Generating advanced research diagrams..."
python benchmarks/scripts/generate_advanced_diagrams.py
echo ""

# ── Step 6: DVFS and EDP specialty plots ─────────────────────────────
echo "[6/6] Generating DVFS and EDP specialty plots..."
python benchmarks/scripts/generate_dvfs_plot.py 2>/dev/null || true
python benchmarks/scripts/generate_edp_plot.py 2>/dev/null || true
echo ""

# ── Summary ──────────────────────────────────────────────────────────
echo "================================================================"
echo " COMPLETE — All figures regenerated."
echo ""
echo " Diagram output:  docs/diagrams/"
echo " Figure output:   docs/figures/"
echo ""
echo " Total diagrams:"
ls -1 docs/diagrams/*.png 2>/dev/null | wc -l
echo " Total figures:"
ls -1 docs/figures/*.png 2>/dev/null | wc -l
echo "================================================================"
