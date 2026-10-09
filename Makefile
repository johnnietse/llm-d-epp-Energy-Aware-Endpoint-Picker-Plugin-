# Energy-aware replica selection for llm-d: build, test, and rerun the analysis.
#
# The first design's Makefile (Kind cluster, simulated pool, synthetic thesis
# figures, the abandoned benchmark plan) is kept at
# legacy/docs-pre-measurement-2026-06/Makefile-first-design.

.PHONY: help test test-race vet fmt build plugin-test plugin-build \
        figures figures-check gate prereg-pilot power calibrate docker clean

PY      ?= python
RESULTS := experiments/cluster-records/results
HET     := $(RESULTS)/stage2het-12305232 $(RESULTS)/stage2het-12319685 $(RESULTS)/stage2het-12321476
HOMOG   := $(RESULTS)/stage2-12321478

help: ## List targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-15s %s\n", $$1, $$2}'

# --- Go -----------------------------------------------------------------
test: ## Unit tests for pkg/ (96 tests in 7 packages, pre-measurement code)
	go test -count=1 ./pkg/...

test-race: ## The same with the race detector
	go test -race -count=1 ./pkg/...

vet: ## go vet over pkg/ and cmd/
	go vet ./pkg/... ./cmd/...

fmt: ## gofmt pkg/ and cmd/
	go fmt ./pkg/... ./cmd/...

build: ## Build the pre-measurement standalone binary (cmd/energy-epp)
	go build -o bin/energy-epp ./cmd/energy-epp/

plugin-test: ## Build, vet and test the llm-d-router plugin module
	cd router-plugin && go build ./... && go vet ./... && go test -count=1 ./...

plugin-build: ## Reproducible EPP binary with our plugins (router-plugin/build.sh)
	bash router-plugin/build.sh

# --- Analysis from committed records (no cluster, no GPU) ---------------
figures: ## Regenerate docs/figures/measured/ from the records
	$(PY) experiments/scripts/make_figures.py

figures-check: figures ## What CI checks: plotted data must not change
	git diff --exit-code -- 'docs/figures/measured/*.csv'

gate: ## The Stage 2 gate on the three mixed-fleet trials
	$(PY) experiments/scripts/stage2_analyse.py $(HET)

prereg-pilot: ## Run the pre-registered Stage 5 analysis on Stage 2 (pilot, non-confirmatory)
	$(PY) experiments/scripts/prereg_analysis.py --pilot --het $(HET) --homog $(HOMOG)

power: ## Trial count from the measured trial-to-trial spread
	$(PY) experiments/scripts/power_analysis.py

calibrate: ## Choose the packing headroom: make calibrate CAL_HOMOG="d1 d2 d3" CAL_HET="d1 d2 d3"
	@test -n "$(CAL_HOMOG)" -a -n "$(CAL_HET)" || { echo "set CAL_HOMOG and CAL_HET to three run dirs each"; exit 2; }
	$(PY) experiments/scripts/headroom_calibrate.py --homog $(CAL_HOMOG) --het $(CAL_HET)

# --- Container ----------------------------------------------------------
docker: ## Container image of cmd/energy-epp (what CI builds)
	docker build -t energy-epp:dev .

clean: ## Remove build outputs
	rm -rf bin coverage.out coverage.html
