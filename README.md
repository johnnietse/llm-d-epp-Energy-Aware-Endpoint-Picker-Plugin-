# Energy-Aware Token-Level Routing for Heterogeneous LLM Inference

> **Master's Thesis** — Design, Implementation, and Evaluation of an LLM-D Endpoint Picker Plugin

An energy-aware endpoint picker plugin (EPP) for the [llm-d inference scheduler](https://github.com/llm-d/llm-d-inference-scheduler) on Kubernetes. Enables **token-level, phase-aware routing** that dynamically directs Prefill and Decode phases to heterogeneous hardware (high-performance GPUs vs. low-power ASICs) to optimize for energy efficiency, carbon footprint, and total cost of ownership.

## Key Results

### Phase-Aware Routing (E2E Simulation — 1,000 cycles)

| Phase | Winner | Win Rate | Rationale |
|-------|--------|----------|-----------|
| **Prefill** | GPU H100 | **99.8%** | Latency-dominant weights favor high FLOPS |
| **Decode** | ASIC QC-100 | **100.0%** | Energy-dominant weights favor efficiency |

### Token Economics

| Metric | GPU H100 | ASIC QC-100 | Ratio |
|--------|----------|-------------|-------|
| Power | 550W | 50W | 11.0× |
| Energy/1M tokens | 0.191 kWh | 0.033 kWh | **5.8×** |
| Carbon/1M tokens | 74.5 gCO2 | 13.5 gCO2 | **5.5×** |
| Cost/1M tokens | $0.019 | $0.004 | **5.5×** |
| **SCI Score** | **0.0194 gCO2/req** | **0.0037 gCO2/req** | **5.2×** |

### Adaptive Weight Controller

| Mode | Trigger | Decode Weights (L/E/C) | Effect |
|------|---------|----------------------|--------|
| **Normal** | Default | 0.20 / 0.50 / 0.30 | Balanced |
| **Carbon High** | CI > 500 gCO2/kWh | 0.05 / 0.38 / **0.57** | Aggressively favor ASICs |
| **Load Shed** | Power > 85% budget | 0.01 / **0.82** / 0.16 | Maximum energy efficiency |
| **Green** | CI < 100 gCO2/kWh | **0.41** / 0.47 / 0.12 | Allow latency-optimized GPU routing |

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                    Scheduling Pipeline                               │
│                                                                      │
│  Request ──▶ EnergyBudgetFilter ──▶ EnergyAwareScorer ──▶ Winner    │
│                     │                      │                         │
│              (>90% TDP? reject)    (phase-aware weights)             │
│                     │                      │                         │
│              ┌──────┴──────┐       ┌───────┴────────┐               │
│              │ EnergyStore │◀──────│ AdaptiveCtrl   │               │
│              │  (shared)   │       │ (closed-loop)  │               │
│              └──────┬──────┘       └────────────────┘               │
│                     │                                                │
│  ┌──────────────────┼──────────────────────────┐                    │
│  │       Scrapers   │                          │                    │
│  │  DCGM ──▶ GPU power, util, tokens/sec       │                    │
│  │  RAPL ──▶ CPU/pkg energy (ΔE/Δt)            │                    │
│  │  Carbon ──▶ grid CO2 intensity              │                    │
│  └─────────────────────────────────────────────┘                    │
│                                                                      │
│  Prometheus Exporter (17 metrics) ──▶ Grafana Dashboard (13 panels) │
│  SCI Calculator (ISO 21031) ──▶ Per-Request Carbon Intensity Score  │
└──────────────────────────────────────────────────────────────────────┘
```

## Project Structure

```
.
├── cmd/
│   └── energy-epp/
│       └── main.go                    # Binary (standalone demo + sidecar mode)
├── pkg/
│   ├── signals/
│   │   ├── types.go                   # Core types: HardwareClass, EnergyProfile, WeightVector
│   │   ├── energy_store.go            # Thread-safe telemetry store + stale eviction
│   │   ├── sci_calculator.go          # ISO SCI score (Green Software Foundation)
│   │   └── *_test.go
│   ├── plugins/
│   │   ├── scorer/
│   │   │   ├── energy_aware_scorer.go # Phase-aware multi-objective scoring
│   │   │   ├── carbon_intensity_scorer.go
│   │   │   └── *_test.go
│   │   ├── filter/
│   │   │   ├── energy_budget_filter.go
│   │   │   └── *_test.go
│   │   └── scraper/
│   │       ├── dcgm_scraper.go        # NVIDIA GPU metrics via Prometheus
│   │       ├── rapl_scraper.go        # CPU energy counters via sysfs
│   │       ├── carbon_api_scraper.go  # CO2Signal / ElectricityMaps
│   │       └── *_test.go
│   ├── config/
│   │   ├── energy_config.go           # Master config + plugin suite factory
│   │   ├── plugin_registry.go         # GIE adapter layer (Filter + Scorer)
│   │   └── config_test.go
│   ├── adaptive/
│   │   ├── weight_controller.go       # Closed-loop adaptive weight adjustment
│   │   └── weight_controller_test.go
│   ├── metrics/
│   │   ├── prometheus_exporter.go     # 17 custom Prometheus metric families
│   │   └── prometheus_exporter_test.go
│   └── simulation/
│       └── e2e_simulation_test.go     # 1000-cycle full-pipeline simulation
├── deploy/
│   ├── kind/
│   │   ├── kind-config.yaml
│   │   └── setup-cluster.sh           # Bootstrap + simulated vLLM pods
│   ├── manifests/
│   │   ├── energy-epp-config.yaml
│   │   └── heterogeneous-pool.yaml
│   └── grafana/
│       └── energy-epp-dashboard.json  # 13-panel Grafana dashboard
├── benchmarks/
│   ├── profiles/hardware_profiles.yaml
│   └── scripts/
│       ├── analyze_results.py
│       └── run-experiments.sh
├── Dockerfile                         # Multi-stage distroless build
├── Makefile                           # 25 targets
├── go.mod
└── README.md
```

## Quick Start

```bash
# Run all tests (93 tests across 8 packages, 0 race conditions)
go test -race -count=1 ./...

# Build and run standalone demo
make demo

# Run in sidecar mode (serves /healthz, /readyz, /metrics/prometheus)
make sidecar

# Run 1000-cycle end-to-end simulation
go test -race -v -count=1 ./pkg/simulation/...

# Generate coverage report
make test-cover

# Deploy to Kind cluster (requires kind, kubectl, docker)
make kind-setup
```

## Phase-Aware Scoring

The core innovation is **asymmetric weight vectors** for Prefill vs Decode:

| Phase | Latency Weight | Energy Weight | Carbon Weight |
|-------|---------------|---------------|---------------|
| **Prefill** | 0.60 | 0.20 | 0.20 |
| **Decode** | 0.20 | 0.50 | 0.30 |

This means:
- **Prefill** (compute-bound): Routes to high-FLOPS GPUs for minimum TTFT
- **Decode** (memory-bound): Routes to low-power ASICs for minimum energy-per-token

## ISO SCI Score (Software Carbon Intensity)

Following the [Green Software Foundation ISO 21031](https://sci.greensoftware.foundation/) standard:

**SCI = ((E × I) + M) / R**

| Component | GPU H100 | ASIC QC-100 |
|-----------|----------|-------------|
| E (energy/request) | 48.9 μWh | 9.3 μWh |
| I (grid intensity) | 390 gCO2/kWh | 390 gCO2/kWh |
| M (embodied/request) | 0.38 mgCO2 | 0.10 mgCO2 |
| **SCI** | **19.4 mgCO2/req** | **3.7 mgCO2/req** |

On clean grids (e.g., France nuclear @ 55 gCO2/kWh), embodied carbon dominates at 88.6%.

## Supported Hardware

| Accelerator | Class | TDP | Decode mJ/tok | Prefill ms/tok |
|-------------|-------|-----|---------------|----------------|
| NVIDIA H100 SXM5 | GPU_HIGH_PERF | 700W | 0.625 | 0.0012 |
| NVIDIA A100 (capped) | GPU_MED_PERF | 200W | 0.267 | 0.0017 |
| NVIDIA L4 | GPU_MED_PERF | 72W | 0.200 | 0.0050 |
| Qualcomm Cloud AI 100 | ASIC_LOW_POWER | 75W | 0.138 | 0.0029 |
| Intel Gaudi2 | ASIC_LOW_POWER | 600W | 0.486 | 0.0014 |

## Test Coverage

| Package | Tests | Coverage |
|---------|-------|----------|
| `pkg/signals` | 25 | 100.0% |
| `pkg/metrics` | 2 | 98.2% |
| `pkg/plugins/filter` | 7 | 93.3% |
| `pkg/plugins/scorer` | 18 | 88.7% |
| `pkg/config` | 10 | 87.8% |
| `pkg/plugins/scraper` | 23 | 87.2% |
| `pkg/adaptive` | 6 | 75.8% |
| `pkg/simulation` | 2 | E2E |
| **Total** | **93** | **~90%** |

## Sidecar Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/healthz` | GET | Health status + adaptive mode + stale count |
| `/readyz` | GET | Readiness probe |
| `/metrics/energy` | GET | JSON: profiles, external signals, adaptive mode |
| `/metrics/prometheus` | GET | 17 Prometheus metric families (text format) |

## License

This project is part of a Master's thesis research. See LICENSE for details.
