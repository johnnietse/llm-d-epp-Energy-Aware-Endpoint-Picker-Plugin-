#!/bin/bash
# ─────────────────────────────────────────────────────────────────────
# 01-setup-env.sh — One-time environment setup on Frontenac
#
# Run this ONCE on the login node (not as a SLURM job).
# It sets up Go, builds the EPP binary, and prepares the vLLM container.
#
# Usage:
#   ssh sa6079052@login.cac.queensu.ca
#   bash benchmarks/scripts/frontenac/01-setup-env.sh
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

echo "═══════════════════════════════════════════════════════"
echo "  Frontenac EPP Benchmark — Environment Setup"
echo "═══════════════════════════════════════════════════════"

# ─── 1. Load modules ────────────────────────────────────────────────
echo "[1/5] Loading modules..."
module load python/3.11.5
module load apptainer/1.3.5
module load cuda/11.6.1

echo "  Python: $(python3 --version)"
echo "  Apptainer: $(apptainer --version)"

# ─── 2. Install Go (module version may be too old) ──────────────────
echo "[2/5] Setting up Go..."
GO_VERSION="1.22.5"
GO_DIR="$HOME/.local/go"
if [[ ! -f "$GO_DIR/bin/go" ]]; then
    echo "  Downloading Go ${GO_VERSION}..."
    wget -q "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -O /tmp/go.tar.gz
    mkdir -p "$HOME/.local"
    tar -C "$HOME/.local" -xzf /tmp/go.tar.gz
    rm /tmp/go.tar.gz
fi
export PATH="$GO_DIR/bin:$PATH"
export GOPATH="$HOME/go"
echo "  Go: $(go version)"

# ─── 3. Clone/update project ───────────────────────────────────────
echo "[3/5] Setting up project..."
PROJECT_DIR="$HOME/energy-epp"
if [[ -d "$PROJECT_DIR" ]]; then
    echo "  Project directory exists: $PROJECT_DIR"
else
    echo "  Clone your project to: $PROJECT_DIR"
    echo "  git clone https://github.com/johnnie/energy-aware-epp.git $PROJECT_DIR"
    echo "  OR: scp -r your-local-project/ sa6079052@login.cac.queensu.ca:~/energy-epp/"
    exit 1
fi

# ─── 4. Build EPP binary (static, for Linux) ───────────────────────
echo "[4/5] Building EPP binary..."
cd "$PROJECT_DIR"
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
    -ldflags="-s -w" -o bin/energy-epp ./cmd/energy-epp/
echo "  Built: $(ls -lh bin/energy-epp | awk '{print $5}')"
chmod +x bin/energy-epp

# ─── 5. Pull vLLM container image ──────────────────────────────────
echo "[5/5] Pulling vLLM Apptainer image (this takes ~10 minutes)..."
VLLM_SIF="$HOME/containers/vllm-openai-v0.6.0.sif"
mkdir -p "$HOME/containers"
if [[ -f "$VLLM_SIF" ]]; then
    echo "  vLLM image already exists: $VLLM_SIF"
else
    echo "  Pulling vllm/vllm-openai:v0.6.0..."
    apptainer pull "$VLLM_SIF" docker://vllm/vllm-openai:v0.6.0
fi

# ─── 6. Set up Python analysis environment ─────────────────────────
echo "[6/5] Setting up Python environment..."
python3 -m venv "$HOME/epp-bench-env" 2>/dev/null || true
source "$HOME/epp-bench-env/bin/activate"
pip install --quiet matplotlib pandas numpy 2>/dev/null || true

# ─── 7. Create results directory ───────────────────────────────────
mkdir -p "$PROJECT_DIR/benchmarks/results/frontenac"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Setup complete!"
echo ""
echo "  Next: Submit GPU profiling job:"
echo "    sbatch benchmarks/scripts/frontenac/02-profile-gpu.sbatch"
echo "═══════════════════════════════════════════════════════"

# ─── Write shell profile additions ──────────────────────────────────
cat >> "$HOME/.bashrc.epp" << 'PROFILE'
# Energy-EPP benchmark environment
export PATH="$HOME/.local/go/bin:$PATH"
export GOPATH="$HOME/go"
alias epp-env='source $HOME/epp-bench-env/bin/activate'
PROFILE

echo ""
echo "  To load EPP env in future sessions:"
echo "    source ~/.bashrc.epp"
