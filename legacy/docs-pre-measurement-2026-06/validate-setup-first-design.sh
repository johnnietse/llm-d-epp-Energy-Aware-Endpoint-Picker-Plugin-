#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# validate-setup.sh — Verify that all project components work correctly
#
# This script checks:
#   1. Go toolchain and build
#   2. All unit tests pass
#   3. E2E simulation passes
#   4. Docker image builds
#   5. Python diagram generation (optional)
#
# Usage:
#   ./scripts/validate-setup.sh          # full validation
#   ./scripts/validate-setup.sh --quick  # skip Docker + diagrams
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[⚠]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }
info() { echo -e "${BLUE}[ℹ]${NC} $*"; }

check() {
    local name="$1"
    shift
    echo -e "\n${BOLD}Checking: ${name}${NC}"
    if "$@" 2>&1; then
        log "$name — PASSED"
        ((PASS++))
    else
        err "$name — FAILED"
        ((FAIL++))
    fi
}

check_skip() {
    local name="$1"
    warn "$name — SKIPPED"
    ((SKIP++))
}

# ─── Header ──────────────────────────────────────────────────────────

echo -e "${BOLD}"
echo "═══════════════════════════════════════════════════════════════"
echo "  Energy-Aware EPP — Setup Validation"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════════════"
echo -e "${NC}"

QUICK_MODE=false
if [[ "${1:-}" == "--quick" ]]; then
    QUICK_MODE=true
    info "Running in quick mode (skipping Docker + diagrams)"
fi

# ─── 1. Go Toolchain ────────────────────────────────────────────────

check "Go version (1.25+ required)" bash -c '
    go version
    GO_VER=$(go version | grep -oP "go\K[0-9]+\.[0-9]+")
    MAJOR=$(echo $GO_VER | cut -d. -f1)
    MINOR=$(echo $GO_VER | cut -d. -f2)
    if [[ $MAJOR -ge 1 && $MINOR -ge 25 ]]; then
        echo "Go $GO_VER — OK"
    else
        echo "Go $GO_VER — requires 1.25+" >&2
        exit 1
    fi
'

# ─── 2. Go Build ────────────────────────────────────────────────────

check "Go build (compiles without errors)" bash -c '
    go build -o /dev/null ./cmd/energy-epp/
    echo "Binary compiles successfully"
'

# ─── 3. Go Vet ──────────────────────────────────────────────────────

check "Go vet (static analysis)" bash -c '
    go vet ./pkg/...
    echo "No issues found"
'

# ─── 4. Unit Tests — Core Packages ──────────────────────────────────

check "Unit tests — pkg/adaptive" go test -count=1 ./pkg/adaptive/...
check "Unit tests — pkg/config" go test -count=1 ./pkg/config/...
check "Unit tests — pkg/metrics" go test -count=1 ./pkg/metrics/...
check "Unit tests — pkg/plugins/filter" go test -count=1 ./pkg/plugins/filter/...
check "Unit tests — pkg/plugins/scorer" go test -count=1 ./pkg/plugins/scorer/...
check "Unit tests — pkg/plugins/scraper" go test -count=1 ./pkg/plugins/scraper/...
check "Unit tests — pkg/signals" go test -count=1 ./pkg/signals/...

# ─── 5. E2E Simulation ──────────────────────────────────────────────

check "E2E simulation (1000 cycles)" go test -v -count=1 -run TestEndToEnd_FullPipelineSimulation ./pkg/simulation/

# ─── 6. Docker Build (optional) ─────────────────────────────────────

if [[ "$QUICK_MODE" == false ]]; then
    if command -v docker &>/dev/null; then
        check "Docker image build" bash -c '
            docker build -t energy-epp:validate-test .
            SIZE=$(docker image ls energy-epp:validate-test --format "{{.Size}}")
            echo "Image built: $SIZE"
            docker rmi energy-epp:validate-test >/dev/null 2>&1 || true
        '
    else
        check_skip "Docker build (Docker not installed)"
    fi
else
    check_skip "Docker build (quick mode)"
fi

# ─── 7. Python Diagrams (optional) ──────────────────────────────────

if [[ "$QUICK_MODE" == false ]]; then
    if command -v python3 &>/dev/null; then
        check "Python diagram generation" bash -c '
            export PYTHONIOENCODING=utf-8
            python3 -c "import matplotlib; import numpy; import pandas; print(\"Dependencies OK\")"
            python3 benchmarks/scripts/generate_advanced_diagrams.py
            echo "Diagrams generated in docs/diagrams/"
        '
    else
        check_skip "Python diagrams (Python3 not installed)"
    fi
else
    check_skip "Python diagrams (quick mode)"
fi

# ─── 7.5 Infrastructure Diagnostics & Bare-Metal Validation ──────────

if command -v python3 &>/dev/null; then
    check "Bare-Metal AI Infrastructure Diagnostics" bash -c '
        python3 scripts/baremetal_diagnostics.py
        echo "Hardware, networking, and platform layers validated successfully."
    '
else
    check_skip "Infrastructure Diagnostics (Python3 not installed)"
fi

# ─── 8. Required Files Check ────────────────────────────────────────

check "Required files exist" bash -c '
    files=(
        "Dockerfile"
        "Makefile"
        "go.mod"
        "cmd/energy-epp/main.go"
        "pkg/signals/energy_store.go"
        "pkg/plugins/scorer/energy_aware_scorer.go"
        "pkg/adaptive/controller.go"
        "upstream-port/energy_aware.go"
        "deploy/kind/setup-cluster.sh"
        "deploy/manifests/energy-epp-deployment.yaml"
        "deploy/manifests/energy-epp-config.yaml"
        "benchmarks/profiles/hardware_profiles.yaml"
    )
    missing=0
    for f in "${files[@]}"; do
        if [[ ! -f "$f" ]]; then
            echo "MISSING: $f" >&2
            missing=$((missing + 1))
        fi
    done
    if [[ $missing -gt 0 ]]; then
        exit 1
    fi
    echo "All ${#files[@]} required files present"
'

# ─── 9. Kind Availability ──────────────────────────────────────────

if command -v kind &>/dev/null; then
    log "Kind is available ($(kind version))"
else
    warn "Kind is not installed — local cluster deployment will not work"
    warn "Install: go install sigs.k8s.io/kind@latest"
fi

# ─── Summary ─────────────────────────────────────────────────────────

echo -e "\n${BOLD}"
echo "═══════════════════════════════════════════════════════════════"
echo "  VALIDATION SUMMARY"
echo "═══════════════════════════════════════════════════════════════"
echo -e "${NC}"

echo -e "  ${GREEN}Passed:${NC}  $PASS"
echo -e "  ${RED}Failed:${NC}  $FAIL"
echo -e "  ${YELLOW}Skipped:${NC} $SKIP"
echo ""

if [[ $FAIL -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All checks passed! The project is ready to use.${NC}"
    echo ""
    echo "  Next steps:"
    echo "    • Local cluster:  ./deploy/kind/setup-cluster.sh --demo"
    echo "    • Run all tests:  go test ./pkg/..."
    echo "    • Build Docker:   docker build -t energy-epp:dev ."
    echo ""
    exit 0
else
    echo -e "  ${RED}${BOLD}$FAIL check(s) failed. See output above for details.${NC}"
    exit 1
fi
