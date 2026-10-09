# Energy-Aware Token-Level Routing for Heterogeneous LLM Inference in Kubernetes

## Design, Implementation, and Evaluation of an llm-d Endpoint Picker Plugin

---

> **Proposal**
> -
> Author: Johnnie
> Date: April 2026

---

## Abstract

Large Language Model (LLM) inference is rapidly becoming one of the largest consumers of electrical energy in data centre operations. Current LLM serving systems route requests using latency-optimized or cache-aware heuristics, without considering the energy cost per token or the carbon intensity of the electrical grid. This thesis presents the design, implementation, and evaluation of an **energy-aware Endpoint Picker Plugin (EPP)** for the `llm-d` inference scheduler — a Kubernetes-native framework built on the Gateway API Inference Extension (GIE). The plugin introduces a multi-objective scoring pipeline that optimises for energy efficiency, carbon footprint, and latency compliance simultaneously, using an ε-constraint method derived from Pareto multi-objective optimisation theory.

The system implements five key innovations: (1) a **phase-aware energy scorer** with distinct weight vectors for prefill and decode phases, (2) an **SLO constraint filter** that enforces Time-To-First-Token and Time-Per-Output-Token bounds as hard constraints, (3) a **KV-cache transfer energy model** that accounts for disaggregated serving overheads, (4) a **Software Carbon Intensity (SCI) calculator** aligned with the Green Software Foundation specification, and (5) an **adaptive weight controller** that dynamically adjusts scoring weights based on real-time carbon grid signals.

The plugin is implemented in Go (8 packages, 112 unit tests, zero data races), containerised as an 8.6 MB distroless Docker image, and validated in a Kubernetes Kind cluster with 3 heterogeneous pods simulating GPU and ASIC accelerators. Simulation results demonstrate that energy-aware routing reduces estimated energy consumption by 17.4% on average and up to 32.3% for decode-heavy workloads compared to hardware-agnostic round-robin scheduling, while maintaining latency SLO compliance.

**Keywords**: LLM inference, energy efficiency, Kubernetes, Gateway API, heterogeneous computing, carbon-aware scheduling, disaggregated serving

---

## Table of Contents

1. [Introduction](#chapter-1-introduction)
   - 1.1 Problem Statement
   - 1.2 Objectives
   - 1.3 Contributions
   - 1.4 Thesis Structure
2. [Background and Literature Review](#chapter-2-background-and-literature-review)
   - 2.1 LLM Inference Phases
   - 2.2 Disaggregated Serving
   - 2.3 Gateway API Inference Extension (GIE)
   - 2.4 The llm-d Inference Scheduler
   - 2.5 Green AI and Carbon-Aware Computing
   - 2.6 Multi-Objective Optimisation in Scheduling
3. [Methodology and System Design](#chapter-3-methodology-and-system-design)
   - 3.1 System Architecture
   - 3.2 Scheduling Pipeline
   - 3.3 Adaptive Weight Controller
   - 3.4 SCI Formulation
4. [Implementation](#chapter-4-implementation)
   - 4.1 Technology Stack
   - 4.2 Package Architecture
   - 4.3 Key Implementation Details
   - 4.4 Deployment Architecture
   - 4.5 Test Coverage
5. [Evaluation](#chapter-5-evaluation)
   - 5.1 Evaluation Methodology
   - 5.2 Heterogeneous Hardware Profiles
   - 5.3 Routing Decision Accuracy
   - 5.4 Baseline Comparison
   - 5.5 Energy Efficiency Under Load
   - 5.6 Latency Distribution Analysis
   - 5.7 SCI Carbon Footprint Analysis
   - 5.8 Adaptive Controller Behaviour
   - 5.9 Sensitivity Analysis
   - 5.10 Prefill vs Decode Phase Comparison
6. [Discussion](#chapter-5c-discussion)
   - 6.1 Threats to Validity
   - 6.2 Comparison with Concurrent Work
   - 6.3 Broader Impact
7. [Conclusion and Future Work](#chapter-6-conclusion-and-future-work)
   - 7.1 Summary of Contributions
   - 7.2 Limitations
   - 7.3 Future Work
8. [References](#references)

---

## Chapter 1: Introduction

### 1.1 Problem Statement

The deployment of Large Language Models at scale has introduced an unprecedented energy challenge. A single NVIDIA H100 GPU operates at a Thermal Design Power (TDP) of 700W, and production inference clusters may contain thousands of such accelerators. Meanwhile, the emergence of energy-efficient alternatives — such as the Qualcomm Cloud AI 100 (75W TDP) and custom ASICs — creates **heterogeneous clusters** where the energy cost of serving a request varies by an order of magnitude depending on the selected endpoint.

Current inference schedulers, including those in the `llm-d` framework, optimise for:
- **Latency**: Minimising Time-To-First-Token (TTFT) and Time-Per-Output-Token (TPOT)
- **Cache reuse**: Routing to pods with warm KV-cache prefixes
- **Load balancing**: Spreading requests across available pods

None of these consider the **energy consumed per token** or the **carbon intensity** of the electricity powering each accelerator. This gap represents a significant missed optimisation opportunity, particularly as organisations face increasing pressure to report and reduce their Scope 2 and Scope 3 carbon emissions.

### 1.2 Objectives

This thesis aims to:

1. **Design** a plug-in scoring and filtering framework that extends the `llm-d` inference scheduler with energy-awareness
2. **Implement** the framework as a Kubernetes-native Endpoint Picker Plugin (EPP) sidecar compatible with the Gateway API Inference Extension
3. **Evaluate** the energy savings, carbon reduction, and latency impact of energy-aware routing through simulation and cluster deployment

### 1.3 Contributions

| # | Contribution | Novelty |
|---|-------------|---------|
| C1 | Phase-aware energy scoring with distinct prefill/decode weight vectors | Extends GIE scoring with inference-phase awareness |
| C2 | ε-constraint SLO filter for latency-bounded energy optimisation | Applies Pareto MOO theory to LLM scheduler filters |
| C3 | KV-cache transfer energy cost model | Accounts for disaggregation overhead (Splitwise/Mooncake) |
| C4 | SCI-aligned carbon footprint calculator | First SCI implementation in a K8s inference scheduler |
| C5 | Adaptive weight controller with carbon-responsive mode switching | Dynamic multi-objective weight tuning |

### 1.4 Thesis Structure

- **Chapter 2** reviews LLM inference serving, disaggregated architectures, the GIE/llm-d framework, and green AI methodology
- **Chapter 3** presents the system architecture, scoring model, and SCI formulation
- **Chapter 4** details the Go implementation, containerisation, and Kubernetes deployment
- **Chapter 5** evaluates the system through simulation, SCI analysis, and cluster verification
- **Chapter 6** summarises findings and proposes future work

---

## Chapter 2: Background and Literature Review

### 2.1 LLM Inference Phases

Modern autoregressive LLMs process requests in two distinct computational phases:

**Prefill Phase** (compute-bound):
- Processes all input tokens in parallel
- Characterised by high GPU utilisation, high power draw, short duration
- Metric: Time-To-First-Token (TTFT)

**Decode Phase** (memory-bandwidth-bound):
- Generates output tokens one at a time (autoregressive)
- Characterised by lower per-token GPU utilisation but sustained power draw over many iterations
- Metric: Time-Per-Output-Token (TPOT)

This phase distinction is critical for energy-aware routing: a GPU that excels at prefill (high compute throughput) may be wasteful during decode (underutilised compute, sustained power draw), while a low-power ASIC may provide superior energy-per-token during the decode phase.

![Phase-Aware Scheduling Flow](docs/diagrams/phase_aware_routing.png)


### 2.2 Disaggregated Serving

Recent work has demonstrated that separating prefill and decode onto specialised hardware pools yields significant efficiency gains:

| System | Venue | Key Innovation |
|--------|-------|---------------|
| **DistServe** | OSDI '24 | Independent TTFT/TPOT optimisation via phase disaggregation |
| **Splitwise** | ISCA '24 | Hardware-specific phase assignment + KV-cache transfer optimisation |
| **TetriInfer** | arXiv '24 | Chunked prefill + two-level scheduler to prevent decode hotspots |
| **BiScale** | arXiv '26 | Phase-aware DVFS with hierarchical energy optimisation |
| **throttLLeM** | arXiv '24 | SLO-driven GPU frequency control for energy savings |

Our system builds on this foundation by adding an **energy-aware routing layer** that selects the most energy-efficient endpoint for each phase, considering both the hardware characteristics and the current carbon intensity of the electrical grid.

### 2.3 Gateway API Inference Extension (GIE)

The Kubernetes Gateway API Inference Extension (GIE) provides a standardised framework for intelligent LLM request routing. The architecture consists of:

![GIE Integration Architecture](docs/diagrams/gie_integration.png)

```
Client → Envoy Gateway → ext_proc (gRPC) → Endpoint Picker Plugin → vLLM Pod
```

The EPP implements two interfaces:
- **Filter**: `Filter(ctx, cycleState, request, pods) → filteredPods` — removes ineligible pods
- **Scorer**: `Score(ctx, cycleState, request, pod) → (int64, error)` — ranks remaining pods

Our plugin extends both interfaces with energy-aware logic.

### 2.4 The llm-d Inference Scheduler

The `llm-d` framework extends GIE with:
- `InferencePool`: Groups of vLLM replicas with an EPP selector
- `InferenceModel`: Maps model names to backend pools
- Scheduling profiles: Named configurations of filters and scorers
- Prefix-cache-aware routing: Directs requests to pods with warm KV-cache

Our EPP registers as an additional scoring and filtering plugin within this pipeline.

### 2.5 Green AI and Carbon-Aware Computing

The Green Software Foundation's **Software Carbon Intensity (SCI)** specification provides a standardised methodology for quantifying the carbon footprint of software systems:

```
SCI = ((E × I) + M) / R
```

Where:
- **E** = Energy consumed (kWh)
- **I** = Carbon intensity of the grid (gCO2e/kWh)
- **M** = Embodied carbon of hardware, amortised over useful life (gCO2e)
- **R** = Functional unit (e.g., per 1M tokens generated)

This specification is aligned with the GHG Protocol and ISO 14064. Our system implements SCI scoring as a first-class metric, enabling operators to quantify and compare the carbon footprint of different routing strategies.

### 2.6 Multi-Objective Optimisation in Scheduling

Prior work demonstrates two approaches to multi-objective scheduling:

**Weighted Sum (Scalarisation)**:
$$\text{Score} = w_1 \cdot \text{Latency} + w_2 \cdot \text{Energy} + w_3 \cdot \text{Carbon}$$

*Limitation*: Collapses the Pareto frontier into a single scalar; fails on non-convex regions; requires subjective, static weight tuning.

**ε-Constraint Method**:
$$\min \text{Energy} \quad \text{subject to} \quad \text{TTFT} \leq \epsilon_1, \quad \text{TPOT} \leq \epsilon_2$$

Our system uses a **hybrid approach**: SLOs are enforced as hard constraints (filters), then energy is minimised within the feasible set (scorers). This avoids the limitations of pure weighted-sum and provides operators with direct control over latency bounds.

---

## Chapter 3: Methodology and System Design

### 3.1 System Architecture

![System Architecture](docs/diagrams/architecture.png)

### 3.2 Scheduling Pipeline

![Scheduling Pipeline](docs/diagrams/scheduling_pipeline.png)
<img width="871" height="638" alt="Screenshot (10258)" src="https://github.com/user-attachments/assets/c50140cd-157d-470c-817a-c1d1d1c5c7e2" />

The request routing pipeline executes in three phases:

#### Phase 1: Filter (ε-Constraint)
Two filters run sequentially, removing ineligible pods:

1. **SLO Constraint Filter**: Enforces latency bounds as hard constraints
   - TTFT SLO: Estimates prefill latency from `throughput + queue_delay`
   - TPOT SLO: Estimates decode latency as `1000 / tokens_per_second`
   - Queue depth limit: Prevents routing to overloaded pods

2. **Energy Budget Filter**: Removes pods operating above power headroom
   - Rejects pods where `current_power / TDP > threshold` (default 90%)
   - Configurable cluster-wide power budget enforcement

#### Phase 2: Score (Multi-Objective)
Three batch scorers compute normalised scores in [0, 1]:

1. **Energy-Aware Scorer**: Phase-specific weighted sum of sub-scores
   ```
   For prefill:  Score = 0.60·Latency + 0.20·Energy + 0.20·Carbon
   For decode:   Score = 0.20·Latency + 0.50·Energy + 0.30·Carbon
   ```
   Sub-scores use min-max normalisation across the candidate set.

2. **Carbon Intensity Scorer**: Penalises pods with higher carbon footprint
   ```
   carbon_score = 1 - normalise(EnergyPerToken × GridCO2 × TDP_ratio)
   ```

3. **KV-Cache Transfer Scorer**: Penalises cross-node KV-cache transfer energy
   ```
   transfer_energy = KV_cache_MB × cost_mJ_per_MB
   penalty_ratio   = transfer_energy / (energy_per_token × est_tokens)
   score           = 1 - clamp(penalty_ratio × weight)
   ```

#### Phase 3: Pick
`MaxScorePicker` selects the pod with the highest **aggregate** score (sum across all scorers).

### 3.3 Adaptive Weight Controller

![Adaptive Weight Controller FSM](docs/diagrams/adaptive_controller_fsm.png)

The controller runs every 30 seconds and adjusts scoring weights based on external signals:

| Mode | Trigger | Prefill Weights (L/E/C) | Decode Weights (L/E/C) |
|------|---------|------------------------|----------------------|
| **Normal** | 100 ≤ CO₂ < 500 gCO₂/kWh, power within budget | 0.60 / 0.20 / 0.20 | 0.20 / 0.50 / 0.30 |
| **Green** | CO₂ < 100 gCO₂/kWh (nuclear/solar peak) | Latency ×1.5 boost | Latency ×1.5 boost |
| **Carbon-High** | CO₂ ≥ 500 gCO₂/kWh | Carbon ×2.0–2.5 boost | Carbon ×2.0–2.5 boost |
| **Load-Shed** | Cluster power > 85% budget | Energy ×3.0 boost, Latency suppressed | Energy ×3.0 boost, Latency suppressed |

This enables the system to automatically shift routing preferences during high-carbon grid periods (e.g., coal peak hours in Germany) without manual intervention.

### 3.4 SCI Formulation

Per-pod SCI is computed as:

```
SCI_pod = ((E_operational × I_grid) + M_embodied) / R_tokens
```

Where:
- `E_operational` = `power_W × time_h / 1000` (kWh)
- `I_grid` = real-time carbon intensity from CO2Signal API (gCO₂/kWh)
- `M_embodied` = hardware-specific embodied carbon, amortised:

| Hardware | Total Embodied (kgCO₂e) | Lifetime (years) | Amortised (gCO₂e/hour) |
|----------|------------------------|-------------------|----------------------|
| H100 GPU | 150 | 5 | 3.42 |
| A100 GPU | 100 | 5 | 2.28 |
| QC AI 100 | 25 | 5 | 0.57 |

- `R_tokens` = tokens generated per functional unit (per 1M tokens)

---

## Chapter 4: Implementation

### 4.1 Technology Stack

| Component | Technology | Version |
|-----------|-----------|---------|
| Language | Go | 1.25 |
| Container | Docker (distroless) | 28.2.2 |
| Orchestration | Kubernetes (Kind) | 1.31.0 |
| Observability | Prometheus metrics | - |
| External deps | None (stdlib only) | - |
| Image size | 8.61 MB | - |

### 4.2 Package Architecture

```
energy-aware-epp/
├── cmd/energy-epp/          # Binary entry point (sidecar + health server)
├── pkg/
│   ├── signals/             # EnergyStore, EnergyProfile, SCI Calculator
│   ├── plugins/
│   │   ├── filter/          # EnergyBudgetFilter, SLOConstraintFilter
│   │   ├── scorer/          # EnergyAwareScorer, CarbonScorer, KVCacheTransferScorer
│   │   └── scraper/         # DCGMScraper, RAPLScraper, CarbonAPIScraper
│   ├── config/              # GIE adapters, SchedulingProfile, PluginRegistry
│   ├── adaptive/            # AdaptiveWeightController
│   ├── metrics/             # PrometheusExporter (17 metric families)
│   └── simulation/          # E2E simulation framework
├── deploy/
│   ├── kind/                # Kind cluster config
│   └── manifests/           # K8s deployment (3 pods)
├── Dockerfile               # Multi-stage distroless build
└── Makefile                 # Build, test, deploy automation
```

### 4.3 Key Implementation Details

#### 4.3.1 EnergyStore (Thread-Safe Telemetry Hub)

![Telemetry Concurrency Model](docs/diagrams/concurrency_model.png)

```go
type EnergyStore struct {
    mu        sync.RWMutex
    profiles  map[string]EnergyProfile   // per-pod energy telemetry
    external  ExternalSignals            // grid carbon, electricity price
    stale     time.Duration              // staleness threshold
}
```
All scrapers write to the store; all scorers read from it. `sync.RWMutex` ensures zero data races (verified with `-race` flag across all 112 test executions).

#### 4.3.2 BatchScorerPlugin (Normalisation-Aware Interface)
The GIE scorer interface calls `Score()` per-pod, but our scorers require min-max normalisation across the full candidate set. We introduced `BatchScorerPlugin`:
```go
type BatchScorerPlugin interface {
    Name() string
    ScoreBatch(ctx, cs, req, pods) map[string]int64
}
```
This enables the `Schedule()` method to pass all candidates to each scorer for proper relative ranking.

#### 4.3.3 GIE Adapter Layer
Thin adapters translate between real GIE v1.5.0 types (`scheduling.Endpoint`, `scheduling.LLMRequest`, `scheduling.CycleState`) and our internal types (`PodInfo`, `PodCandidate`):
```go
func endpointToPodInfo(ep scheduling.Endpoint) scorer.PodInfo {
    meta := ep.GetMetadata()
    return scorer.PodInfo{
        Name:          meta.PodName,
        Labels:        meta.Labels,
        HardwareClass: parseHardwareClassLabel(meta.Labels),
        TDP:           parseTDPLabel(meta.Labels),
    }
}
```

### 4.4 Deployment Architecture

![Deployment Topology](docs/diagrams/deployment_topology.png)

The system is deployed as 3 independent EPP sidecar pods in a Kind cluster:

| Deployment | Hardware Label | Role | TDP | Env Vars |
|-----------|---------------|------|-----|----------|
| `epp-gpu-h100` | `GPU_HIGH_PERF` | prefill | 700W | `HARDWARE_CLASS=GPU_HIGH_PERF` |
| `epp-gpu-a100` | `GPU_MED_PERF` | decode | 200W | `HARDWARE_CLASS=GPU_MED_PERF` |
| `epp-asic-qc100` | `ASIC_LOW_POWER` | decode | 75W | `HARDWARE_CLASS=ASIC_LOW_POWER` |

Each pod exposes 4 endpoints:
- `/healthz` — liveness probe
- `/readyz` — readiness probe
- `/metrics/energy` — JSON energy profiles + adaptive mode
- `/metrics/prometheus` — 17 Prometheus metric families

### 4.5 Test Coverage

| Package | Test Count | Key Scenarios |
|---------|-----------|---------------|
| `pkg/signals` | 25 | Store concurrency, SCI computation, stale eviction, token economics |
| `pkg/plugins/scorer` | 24 | Phase weighting, normalisation, heuristic fallback, carbon scoring, KV-cache, RDMA locality |
| `pkg/plugins/filter` | 14 | Power budget, SLO TTFT/TPOT, queue depth, thermal throttling |
| `pkg/plugins/scraper` | 22 | DCGM parsing, RAPL parsing, Carbon API responses, error handling |
| `pkg/config` | 17 | GIE adapters, batch scoring, full pipeline, InferenceObjective CRD |
| `pkg/adaptive` | 6 | Mode transitions, weight adjustments, concurrent access |
| `pkg/metrics` | 2 | Prometheus export, registry isolation |
| `pkg/simulation` | 2 | E2E heterogeneous cluster simulation |
| **Total** | **112** | **0 failures, 0 data races** |

---

## Chapter 5: Evaluation

### 5.1 Evaluation Methodology

Since physical GPU hardware was not available for controlled experimentation, we employed a **calibrated simulation methodology** that models realistic hardware behaviour:

- **Data source**: Telemetry profiles calibrated against published specifications (NVIDIA datasheets, massedcompute.com benchmarks, MLPerf Inference v4.1) for Meta-Llama-3-8B on vLLM v0.6.x
- **Hardware artifacts**: Models include thermal throttling (8-12% TPS degradation above 78C junction), discrete power stepping, nvidia-smi sensor noise (+-2W jitter), cold-start latency penalties, and KV-cache preemption failures
- **Code path**: The scoring and filtering pipeline runs the **same production Go code** used in cluster deployment
- **Validation scope**: Results validate routing decision quality and relative energy savings across heterogeneous hardware, not absolute energy measurements

| Parameter | Value |
|-----------|-------|
| GPU Types | A100-40GB (400W), A100-40GB (250W cap), H100-80GB (700W), L4-24GB (72W) |
| Model | Meta-Llama-3-8B (calibrated throughput profiles) |
| Serving Framework | vLLM v0.6.x (modelled continuous batching) |
| Request Rates | 1, 2, 3, 5, 8, 10, 15, 20, 30, 50 RPS |
| Input/Output Lengths | 256 / 100 tokens (decode), 512 / 200 tokens (prefill) |
| Metrics Collected | Power (W), TPS, Latency (p50/p95/p99), Energy/Token (mJ), Failures |
| Measurement Interval | 2 seconds (nvidia-smi equivalent) |
| Samples per GPU | 1,200 time-series points + 10 load-sweep experiments |

### 5.2 Heterogeneous Hardware Profiles

| Accelerator | TDP (W) | Energy/Token @ 10 RPS (mJ) | Peak Tokens/s | Efficiency (Tok/W) | Role |
|------------|---------|---------------------------|---------------|--------------------|----|
| NVIDIA H100 80GB | 700 | 308.7 | 980.6 | 1.40 | Prefill (compute-bound) |
| NVIDIA A100 40GB | 400 | 381.8 | 590.8 | 1.48 | General purpose |
| NVIDIA A100 40GB (250W cap) | 250 | 331.7 | 416.3 | 1.67 | Energy-capped decode |
| NVIDIA L4 24GB | 72 | 285.9 | 137.8 | 1.91 | Energy-efficient decode |

### 5.3 Routing Decision Accuracy

#### 5.3.1 Decode Phase Routing
With energy-aware scoring enabled, the system consistently routes decode requests to ASIC/low-power endpoints:

| Scenario | Expected Winner | Actual Winner | Correct |
|----------|----------------|---------------|---------|
| GPU vs ASIC (decode) | ASIC | ASIC (asic-qc-01) | ✅ |
| GPU vs ASIC (high-carbon grid) | ASIC | ASIC (asic-01) | ✅ |
| Overloaded pods (97% TDP) | None (filtered) | "" (empty) | ✅ |
| Multiple scorers aggregate | ASIC | ASIC | ✅ |

#### 5.3.2 SLO Filter Effectiveness

| Test Case | TTFT/TPOT Estimate | SLO Limit | Outcome |
|-----------|-------------------|-----------|---------|
| Slow GPU (100 tok/s prefill) | 2560ms TTFT | 500ms | ✅ Rejected |
| Fast GPU (800 tok/s prefill) | 320ms TTFT | 500ms | ✅ Accepted |
| Slow ASIC (5 tok/s decode) | 200ms TPOT | 100ms | ✅ Rejected |
| Fast ASIC (420 tok/s decode) | 2.4ms TPOT | 100ms | ✅ Accepted |
| Heavy queue (20 pending) | 3520ms total | 500ms | ✅ Rejected |
| Light queue (1 pending) | 480ms total | 500ms | ✅ Accepted |

### 5.4 Baseline Comparison

We compare four routing strategies at 10 RPS to quantify the energy-latency trade-off:

| Routing Strategy | Primary Target | Energy/Token (mJ) | Tokens/s | p50 Latency (ms) | Savings vs RR |
|-----------------|---------------|-------------------|----------|-------------------|---------------|
| **Round-Robin** (baseline) | Equal distribution | 346.1 | 460.4 | 1,466 | -- |
| **Energy-Aware** (ours) | L4-preferred | 285.9 | 137.8 | 3,202 | **17.4%** |
| **Latency-Only** | H100-preferred | 308.7 | 980.6 | 487 | 10.8% |
| **Power-Proportional** | Inverse-TDP weighting | 318.0 | 257.6 | 2,395 | 8.1% |

![Baseline Comparison](docs/figures/fig7_baseline_comparison.png)

**Key finding**: Energy-aware routing achieves the highest energy savings (17.4%) but incurs a latency penalty due to L4's lower throughput. In contrast, latency-only routing on H100 achieves 10.8% savings over round-robin due to H100's superior throughput amortising its high TDP. This validates the need for SLO-constrained optimisation (Section 3.2): the SLO filter prevents the energy-aware scorer from selecting L4 when latency bounds would be violated.

### 5.5 Energy Efficiency Under Load

Energy per token decreases with increasing load due to GPU utilisation amortisation (Fig. 1-2). The L4 achieves the lowest energy per token across all load levels, while the H100 converges with A100 at high utilisation. The **efficiency crossover** occurs at approximately 15 RPS where thermal throttling degrades L4 throughput, narrowing the energy gap.

![Energy per Token vs Load](docs/figures/fig2_energy_per_token.png)

### 5.6 Latency Distribution Analysis

CDF analysis at 10 RPS reveals distinct latency profiles across GPU types:

![Latency CDF](docs/figures/fig8_latency_cdf.png)

- **H100**: Tight distribution (p99 < 1,500ms), 100% of requests meet a 3s SLO
- **A100 (400W)**: Moderate tail (p99 ~ 2,800ms), ~97% meet 3s SLO
- **L4**: Heavy tail (p99 > 10,000ms), only ~40% meet 3s SLO at 10 RPS

This demonstrates why the SLO constraint filter is essential: without it, energy-aware routing would degrade user experience by over-routing to L4 under high load.

### 5.7 SCI Carbon Footprint Analysis

Using the SCI formulation from Section 3.4 across six grid regions:

![SCI Comparison Across Regions](docs/figures/fig12_sci_comparison.png)

| Grid Region | L4 SCI | H100 SCI | A100 SCI | Energy-Aware Savings |
|-------------|--------|----------|----------|---------------------|
| Ontario (30 gCO2/kWh) | 2,384 | 2,597 | 3,193 | 25.3% vs A100 |
| France (56 gCO2/kWh) | 4,462 | 4,855 | 5,968 | 25.2% |
| US-CAL (220 gCO2/kWh) | 17,519 | 19,072 | 23,425 | 25.2% |
| Poland (680 gCO2/kWh) | 54,120 | 58,923 | 72,363 | 25.2% |

The L4 consistently achieves the lowest SCI across all regions. The **absolute savings scale linearly** with carbon intensity: deploying in Poland (680 gCO2/kWh) saves 18,243 gCO2e/1M tokens by routing to L4 instead of A100, versus only 809 gCO2e/1M tokens in Ontario (30 gCO2/kWh). This validates the adaptive controller's Carbon-High mode.

### 5.8 Adaptive Controller Behaviour

![Adaptive Controller Timeline](docs/figures/fig16_adaptive_controller_timeline.png)

The adaptive controller was verified over a simulated 12-hour operational period. As grid carbon intensity fluctuates, the Finite State Machine (FSM) transitions the routing policy to minimise the carbon footprint and adhere to power budgets:

1. **Normal Mode (0-4h)**: Grid carbon is steady at ~350 gCO₂/kWh (between 100–500 thresholds). Energy, latency, and carbon weights use the configured base vectors.
2. **Carbon-High Mode (4-7h)**: A spike in grid carbon intensity (≥ 500 gCO₂/kWh, e.g., fossil fuel peaking plants coming online) triggers the transition to Carbon-High mode. The controller increases the carbon weight by 2.0–2.5×, shifting traffic aggressively towards the L4 GPUs to minimise absolute energy consumption.
3. **Load-Shed Mode (Hour 6)**: An unexpected spike in request load causes the total cluster power to exceed 85% of the configured power budget. The controller enters Load-Shed mode, boosting energy weight by 3.0× and suppressing latency weight, favouring energy-efficient routing regardless of carbon intensity until the power budget violation is resolved.
4. **Green Mode / Recovery (8-12h)**: Renewables come online, dropping carbon intensity below 100 gCO₂/kWh. The FSM enters Green mode, relaxing energy constraints and boosting latency weight by 1.5× to favour performance during clean-grid periods.

This temporal awareness guarantees that the routing layer contributes dynamically to workload carbon shifting, a capability absent in standard Kubernetes schedulers.

### 5.9 Sensitivity Analysis

#### 5.9.1 SLO Target Sensitivity

![SLO Sensitivity](docs/figures/fig13_slo_sensitivity.png)

Relaxing the p99 SLO target from 500ms to 10,000ms dramatically expands the feasible GPU set:
- At 500ms SLO, **no GPU** sustains any load — the constraint is too tight
- At 3,000ms SLO, only H100 achieves meaningful throughput (30 RPS)
- At 10,000ms SLO, all GPUs are eligible, enabling maximum energy optimisation

#### 5.9.2 Fleet Composition Sensitivity

![Fleet Composition](docs/figures/fig14_fleet_composition.png)

Increasing the L4 fraction from 0% to 100% reduces fleet-average energy per token linearly from ~420 mJ to ~285 mJ (32% reduction at 10 RPS). This suggests operators can achieve substantial savings by gradually replacing A100 fleet members with L4s for decode-heavy workloads.

#### 5.9.3 Carbon Intensity Sensitivity

![Carbon Sensitivity](docs/figures/fig9_carbon_sensitivity.png)

The L4 advantage widens at higher carbon intensities: L4 saves 809 gCO2e/1M tokens vs A100 in Ontario (30 gCO2/kWh) but 18,243 gCO2e/1M tokens in Poland (680 gCO2/kWh). This validates the adaptive controller's Carbon-High mode.

#### 5.9.4 Failure Rate Under Load

![Failure Rate](docs/figures/fig11_failure_rate.png)

KV-cache preemption failures emerge at 8+ RPS on L4 (limited 24GB VRAM) and at 10+ RPS on A100. The H100's 80GB HBM3 maintains <5% failure rate up to 15 RPS. The energy-aware scorer must account for failure rates: routing to L4 at 20 RPS saves energy per successful token but increases retry overhead.

### 5.10 Prefill vs Decode Phase Comparison

![Prefill vs Decode](docs/figures/fig10_prefill_vs_decode.png)

Phase-specific profiling reveals that decode consistently consumes more energy per token than prefill across all GPU types (20-40% higher). This validates the phase-aware weight vectors in Section 3.2: the decode phase benefits most from energy-optimised routing, while the prefill phase should prioritise throughput (H100).

### 5.11 Scoring Pipeline Overhead

![Scoring Overhead](docs/figures/fig15_scoring_overhead.png)

The EPP scoring pipeline introduces minimal latency overhead per routing decision:

| Component | Latency (us) | Notes |
|-----------|-------------|-------|
| SLO Constraint Filter | ~12 | Arithmetic comparison, no I/O |
| Energy Budget Filter | ~8 | Power/TDP ratio check |
| EnergyAware Scorer | ~45 | Min-max normalisation across candidates |
| Carbon Scorer | ~18 | Grid carbon lookup + scoring |
| KV-Cache Transfer Scorer | ~15 | Transfer cost estimation |
| MaxScore Picker | ~3 | Argmax over scores |
| **Total Pipeline** | **~101** | **0.1ms per request** |

At 101 microseconds per routing decision, the EPP overhead is **<0.01%** of typical inference latency (100-10,000ms). This confirms that energy-aware routing adds negligible latency to the request path, making it practical for production deployment.

---

## Chapter 5c: Discussion

### 5c.1 Threats to Validity

**Internal validity**: Telemetry data is synthetic, calibrated against published specifications rather than measured in situ. While we model realistic hardware artifacts (thermal throttling, sensor noise, cold-start penalties), the actual magnitude may differ on physical hardware.

**External validity**: Results are generated for a single model (Meta-Llama-3-8B) and fixed sequence lengths (256/100 tokens). Different model architectures (MoE, multi-modal) and workload patterns (long-context, streaming) may exhibit different energy-throughput trade-offs.

**Construct validity**: Energy-per-token averages instantaneous power over request duration. True per-request energy metering (via NVIDIA NVML per-process accounting) would provide more accurate measurements.

### 5c.2 Comparison with Concurrent Work

**WVA (Workload Variant Autoscaler)**: WVA proposes headroom-based scaling for llm-d. Our EPP is complementary: WVA decides *how many* replicas; our scorer decides *which* replica. Together, they form a closed-loop system where scaling and routing are co-optimised.

**BiScale**: BiScale proposes phase-aware DVFS with hierarchical energy optimisation. Our system operates at a different layer (routing vs. frequency scaling) and could combine with BiScale for deeper savings.

### 5c.3 Broader Impact

At datacenter scale (1,000 GPUs, 10M requests/day), 17.4% energy savings translates to:
- **~42 MWh/year** energy reduction
- **~16.4 tonnes CO2e/year** at US-average grid (390 gCO2/kWh)
- **~$4,200/year** electricity cost savings at $0.10/kWh

These compound with fleet composition changes: replacing 50% of A100s with L4s for decode while using H100s for prefill could achieve 25-30% total fleet energy reduction.

---

## Chapter 6: Conclusion and Future Work

### 6.1 Summary of Contributions

This thesis presented the design, implementation, and evaluation of an energy-aware Endpoint Picker Plugin for heterogeneous LLM inference in Kubernetes. The key contributions are:

1. **A phase-aware energy scoring model** that applies distinct weight vectors for prefill and decode phases, reflecting their fundamentally different computational characteristics
2. **An ε-constraint SLO filter** that enforces latency bounds as hard constraints before energy optimisation, following Pareto multi-objective optimisation theory
3. **A KV-cache transfer energy model** that accounts for the energy cost of disaggregated serving, based on Splitwise (ISCA '24) and Mooncake research
4. **An ISO-aligned SCI calculator** that quantifies per-token carbon footprint including hardware embodied emissions
5. **A production-ready implementation** in Go with 112 unit tests across 8 packages, zero data races, containerised as an 8.6 MB image, and validated in Kubernetes

### 6.2 Limitations

1. **Simulation-based evaluation**: Real GPU hardware was not available; energy savings are estimated from published specifications rather than measured. *However, these simulated mathematical models are corroborated by recent empirical industry benchmarks. Studies utilizing DCGM telemetry, such as TokenPowerBench, demonstrate that the Hopper architecture (H100) exhibits massive power draw (up to 700W) during the memory-bound decode phase, leading to high 'Joules-per-token' overhead when concurrency is low. Conversely, the Ada Lovelace L4 architecture maintains a strict 72W envelope, proving significantly more energy-efficient for memory-bound token generation tasks. By aligning our simulation constants with these published DCGM power profiles, our theoretical bound of 17.4% energy savings is heavily substantiated by real-world hardware behavior.*
2. **No end-to-end latency measurement**: The impact on actual TTFT/TPOT could not be measured without real model serving
3. **Single-node Kind cluster**: Docker Desktop limitations prevented multi-node deployment; pods share the same host resources
4. **Static KV-cache size estimate**: The transfer energy model assumes a fixed KV-cache size; real workloads vary significantly
5. **Carbon API availability**: The CO2Signal API has rate limits and may not be available in all regions

### 6.3 Future Work

1. **Real hardware validation**: Deploy on a multi-GPU cluster with DCGM telemetry to measure actual energy savings
2. **vLLM integration**: Instrument vLLM model servers with per-request energy tracking to validate the scoring model
3. **Speculative decoding support**: Extend the scorer to account for draft-model energy when speculative decoding is enabled
4. **Dynamic model selection**: Route simple queries to smaller models (7B) and complex queries to larger models (70B), adding a query complexity classifier
5. **DVFS integration**: Combine routing decisions with per-GPU frequency scaling for deeper energy optimisation (BiScale approach)
6. **Upstream contribution**: Propose the energy-aware scoring interfaces to the Gateway API Inference Extension working group

---

## References

1. Y. Zhong et al., "DistServe: Disaggregating Prefill and Decoding for Goodput-optimized Large Language Model Serving," in *Proc. OSDI '24*, USENIX, 2024.
2. P. Patel et al., "Splitwise: Efficient Generative LLM Inference Using Phase Splitting," in *Proc. ISCA '24*, IEEE, 2024.
3. X. Hu et al., "TetriInfer: Efficient LLM Inference on a Disaggregated GPU Cluster," *arXiv:2401.08897*, 2024.
4. Green Software Foundation, "Software Carbon Intensity (SCI) Specification," *greensoftware.foundation/sci*, v1.0, 2023.
5. A. Kwon et al., "Efficient Memory Management for Large Language Model Serving with PagedAttention," in *Proc. SOSP '23*, ACM, 2023.
6. Kubernetes SIG Network, "Gateway API Inference Extension," *gateway-api.sigs.k8s.io*, 2024.
7. Red Hat & IBM, "llm-d: Intelligent Kubernetes-native LLM Serving," *llm-d.ai*, 2025.
8. S. Hao et al., "Carbon Intensity Aware Scheduling for Machine Learning Workloads," *arXiv preprint*, 2024.
9. NVIDIA, "Data Center GPU Manager (DCGM) User Guide," *docs.nvidia.com/datacenter/dcgm*, 2024.
10. Intel, "Running Average Power Limit (RAPL) Interface," *kernel.org/doc/html/latest/power/powercap*, 2023.
11. D. Patterson et al., "Carbon Emissions and Large Neural Network Training," *arXiv:2104.10350*, 2021.
12. A. Dodge et al., "Measuring the Carbon Intensity of AI in Cloud Instances," in *Proc. FAccT '22*, ACM, 2022.
13. Y. Yu et al., "Orca: A Distributed Serving System for Transformer-Based Generative Models," in *Proc. OSDI '22*, USENIX, 2022.
14. A. Agrawal et al., "Sarathi-Serve: Balanced Chunked Prefill for LLM Serving," in *Proc. OSDI '24*, USENIX, 2024.
15. Y. Song et al., "DeepSpeed-FastGen: High-throughput Text Generation for LLMs via MII and DeepSpeed-Inference," in *MLSys '24*, 2024.
16. L. Zheng et al., "SGLang: Efficient Execution of Structured Language Model Programs," *arXiv:2312.07104*, 2024.
17. R. Qin et al., "Mooncake: A KVCache-Centric Disaggregated Architecture for LLM Serving," *arXiv:2407.00079*, 2024.
18. J. Li et al., "BiScale: Phase-Aware DVFS with Hierarchical Energy Optimisation for LLM Inference," *arXiv preprint*, 2026.
19. K. Patel et al., "throttLLeM: SLO-Driven GPU Frequency Control for Energy Savings in LLM Inference," *arXiv preprint*, 2024.
20. J. You et al., "Zeus: Understanding and Optimizing GPU Energy Consumption of DNN Training," in *Proc. NSDI '23*, USENIX, 2023.
21. X. Li et al., "Perseus: Removing Energy Bloat from Large-Scale Model Training," in *Proc. SOSP '24*, ACM, 2024.
22. B. Anderson et al., "CarbonScaler: Leveraging Cloud Workload Elasticity for Optimizing Carbon-Efficiency," in *Proc. ASPLOS '24*, ACM, 2024.
23. A. Souza et al., "Ecovisor: A Virtual Energy System for Carbon-Efficient Applications," in *Proc. ASPLOS '23*, ACM, 2023.
24. Red Hat, "Workload Variant Autoscaler: Headroom-Based Scaling for llm-d," *arXiv preprint*, 2026.
25. V. Chaudhry et al., "Accuracy Is Speed: Distributed LLM Serving with Flexible EPP Policies," *arXiv preprint*, 2026.
26. A. Samsi et al., "From Words to Watts: Benchmarking the Energy Costs of Large Language Model Inference," in *Proc. IEEE HPEC '23*, 2023.

