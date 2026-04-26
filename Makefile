# Energy-Aware Endpoint Picker Plugin for llm-d
# Makefile for building, testing, and deploying the energy-aware EPP

.PHONY: all build test test-race lint clean fmt vet help demo docker

# Go parameters
GOCMD=go
GOBUILD=$(GOCMD) build
GOTEST=$(GOCMD) test
GOFMT=$(GOCMD) fmt
GOVET=$(GOCMD) vet
GOMOD=$(GOCMD) mod

# Binary name
BINARY_NAME=energy-epp
BINARY_DIR=bin
DOCKER_IMAGE=energy-epp:dev

# Package paths
PKG_SIGNALS=./pkg/signals/...
PKG_SCORER=./pkg/plugins/scorer/...
PKG_FILTER=./pkg/plugins/filter/...
PKG_SCRAPER=./pkg/plugins/scraper/...
PKG_CONFIG=./pkg/config/...
PKG_METRICS=./pkg/metrics/...
PKG_ADAPTIVE=./pkg/adaptive/...
PKG_ALL=./...

# ─── Default target ──────────────────────────────────────────────────
all: fmt vet test build

# ─── Build ───────────────────────────────────────────────────────────
build: ## Build the EPP binary
	@echo "Building $(BINARY_NAME)..."
	@mkdir -p $(BINARY_DIR)
	$(GOBUILD) -o $(BINARY_DIR)/$(BINARY_NAME) ./cmd/energy-epp/

# ─── Test ────────────────────────────────────────────────────────────
test: ## Run all unit tests (74 tests across 7 packages)
	@echo "Running unit tests..."
	$(GOTEST) -v -count=1 $(PKG_ALL)

test-race: ## Run tests with race detector
	@echo "Running tests with race detector..."
	$(GOTEST) -race -count=1 $(PKG_ALL)

test-signals: ## Run signals package tests only
	$(GOTEST) -v -count=1 $(PKG_SIGNALS)

test-scorer: ## Run scorer package tests only
	$(GOTEST) -v -count=1 $(PKG_SCORER)

test-filter: ## Run filter package tests only
	$(GOTEST) -v -count=1 $(PKG_FILTER)

test-scraper: ## Run scraper package tests only
	$(GOTEST) -v -count=1 $(PKG_SCRAPER)

test-config: ## Run config/GIE adapter tests only
	$(GOTEST) -v -count=1 $(PKG_CONFIG)

test-metrics: ## Run Prometheus exporter tests only
	$(GOTEST) -v -count=1 $(PKG_METRICS)

test-adaptive: ## Run adaptive weight controller tests only
	$(GOTEST) -v -count=1 $(PKG_ADAPTIVE)

test-cover: ## Run tests with coverage report
	@echo "Running tests with coverage..."
	$(GOTEST) -v -coverprofile=coverage.out $(PKG_ALL)
	$(GOCMD) tool cover -html=coverage.out -o coverage.html
	@echo "Coverage report: coverage.html"

# ─── Code Quality ────────────────────────────────────────────────────
fmt: ## Format Go source files
	$(GOFMT) $(PKG_ALL)

vet: ## Run Go vet
	$(GOVET) $(PKG_ALL)

lint: ## Run golangci-lint (install: go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest)
	golangci-lint run $(PKG_ALL)

# ─── Dependencies ────────────────────────────────────────────────────
deps: ## Download and tidy dependencies
	$(GOMOD) download
	$(GOMOD) tidy

# ─── Demo ────────────────────────────────────────────────────────────
demo: build ## Build and run the standalone demo
	@echo "Running standalone demo..."
	./$(BINARY_DIR)/$(BINARY_NAME) --mode standalone

sidecar: build ## Build and run in sidecar mode (Ctrl+C to stop)
	@echo "Running sidecar mode on :8080..."
	./$(BINARY_DIR)/$(BINARY_NAME) --mode sidecar --health-port 8080

# ─── Benchmarks ──────────────────────────────────────────────────────
bench: ## Run Go benchmarks
	$(GOTEST) -bench=. -benchmem $(PKG_ALL)

analyze: ## Analyze experiment results with Python
	python benchmarks/scripts/analyze_results.py --output benchmarks/results/

experiments: build ## Run full experiment suite (tests + demo + analysis)
	bash benchmarks/scripts/run-experiments.sh

# ─── Docker ──────────────────────────────────────────────────────────
docker: ## Build Docker image
	@echo "Building Docker image $(DOCKER_IMAGE)..."
	docker build -t $(DOCKER_IMAGE) .

docker-run: docker ## Build and run Docker container
	docker run --rm -p 8080:8080 $(DOCKER_IMAGE)

# ─── Kubernetes ──────────────────────────────────────────────────────
deploy-sim: ## Deploy simulated heterogeneous pool to local Kind cluster
	kubectl apply -f deploy/manifests/heterogeneous-pool.yaml

deploy-epp: ## Deploy energy-aware EPP configuration
	kubectl apply -f deploy/manifests/energy-epp-config.yaml

undeploy: ## Remove all energy-aware EPP resources
	kubectl delete -f deploy/manifests/heterogeneous-pool.yaml --ignore-not-found
	kubectl delete -f deploy/manifests/energy-epp-config.yaml --ignore-not-found

kind-setup: ## Set up a local Kind cluster with labeled nodes
	bash deploy/kind/setup-cluster.sh

kind-demo: ## Full Kind demo (cluster + build + deploy + sim pods)
	bash deploy/kind/setup-cluster.sh --demo

kind-teardown: ## Tear down the Kind cluster
	bash deploy/kind/setup-cluster.sh --teardown

kind-status: ## Show cluster and EPP status
	bash deploy/kind/setup-cluster.sh --status

# ─── Clean ───────────────────────────────────────────────────────────
clean: ## Clean build artifacts
	rm -rf $(BINARY_DIR)
	rm -f coverage.out coverage.html

# ─── Help ────────────────────────────────────────────────────────────
help: ## Display this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
