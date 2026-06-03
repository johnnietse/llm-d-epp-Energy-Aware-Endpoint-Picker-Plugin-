# Project Additions Summary

## What Was Added

### 📊 8 New Advanced Diagrams (`docs/diagrams/`)

| # | Diagram | File | Purpose |
|---|---------|------|---------|
| 1 | **Regional Carbon Intensity** | `regional_carbon_comparison.png` | Bar chart of 10 global regions with FSM threshold lines (200 & 500 gCO₂/kWh). Shows why routing decisions change based on geography. |
| 2 | **DVFS Power-Frequency Curve** | `dvfs_power_frequency_curve.png` | Dual-axis plot showing the decode-phase "sweet spot" where lowering GPU frequency saves energy with negligible latency impact (~42% savings). |
| 3 | **Adaptive FSM (Detailed)** | `adaptive_fsm_detailed.png` | Full state diagram showing Normal → Carbon-Critical → Emergency mode transitions with exact weight vectors ($w_L, w_E, w_C$) for each state. |
| 4 | **Energy-Delay Product Scatter** | `edp_scatter_analysis.png` | EDP scatter plot comparing H100/A100/A100-Capped/L4 with iso-EDP contour curves. Visualizes the energy-latency tradeoff. |
| 5 | **Cost per Million Tokens** | `cost_per_million_tokens.png` | Bar chart comparing cloud inference cost (USD/MTok) across 5 hardware types using real cloud pricing × throughput. |
| 6 | **Workload Radar Chart** | `workload_characterization_radar.png` | Radar chart profiling 4 benchmark traces (Chatbot, Code Gen, Summarization, Burst) across 5 dimensions. |
| 7 | **Carbon Savings Heatmap** | `carbon_savings_heatmap.png` | Hardware × Region heatmap showing SCI values (gCO₂ per 1000 tokens). Immediately reveals where routing has the largest environmental impact. |
| 8 | **Scoring Overhead CDF** | `scoring_overhead_cdf.png` | CDF of endpoint scoring latency comparing Round-Robin (~12µs), Latency-Only (~33µs), and Energy-Aware EPP (~90µs) with P50/P99 markers. |

### 📁 New Data Files

| File | Location | Description |
|------|----------|-------------|
| **Carbon Intensity Profiles** | `benchmarks/profiles/carbon_intensity_regions.yaml` | 10 global regions (Norway through Poland) with average/marginal/peak/off-peak intensity, grid mix, API source citations, and FSM threshold config. |
| **Workload Traces** | `benchmarks/traces/sample_workload_traces.yaml` | 6 reproducible trace definitions: Chatbot, Code Gen, Summarization, Burst Traffic, Carbon Spike Scenario, and Multi-Model Mixed. Each has token distributions, arrival patterns, and SLO targets. |

### 🔧 New Scripts & Infrastructure

| File | Purpose |
|------|---------|
| `benchmarks/scripts/generate_advanced_diagrams.py` | Generates all 8 advanced diagrams above |
| `benchmarks/scripts/generate-all-figures.sh` | **One-command reproducibility script** — runs ALL figure generation scripts sequentially |
| `Makefile` additions | `make bench-report` (regenerate all figures) and `make gen-figures` (advanced diagrams only) |

### 🔍 Research-Backed Additions

Based on web research, the following data sources and methodologies were incorporated:

- **Carbon intensity data** sourced from Electricity Maps (average) and WattTime (marginal MOER)
- **DVFS sweet spot** modeling based on 2025-2026 studies showing ~42% energy savings via frequency scaling during memory-bound decode
- **Cost data** calibrated against current cloud GPU pricing (H100 $3.50/hr, L4 $0.55/hr)
- **Workload distributions** based on ShareGPT conversational dataset patterns (standard vLLM benchmark)

## Total Diagram Inventory

After all additions, the `docs/diagrams/` directory now contains **~18 publication-quality diagrams** covering every major concept in the thesis.

## 🚀 Tenstorrent Data Center Automation & Test Engineer Additions

Based on the requirements for modern Bare-Metal, HPC, and AI Infrastructure, the following advanced tooling was added to directly support hardware-layer routing, diagnostics, and Slurm/Ray interoperability:

### 1. High-Performance Networking & Locality
| Component | Location | Description |
|-----------|----------|-------------|
| **RDMA / InfiniBand Locality Scorer** | `pkg/plugins/scorer/rdma_locality_scorer.go` | Boosts scores for nodes with GPU-Direct RDMA, InfiniBand/RoCE, and optimized NUMA pinning. Essential for cross-node KV-cache transfers during Decode phases. |
| **Bare-Metal Telemetry Updates** | `pkg/signals/types.go` | Added `HasRDMA` and `NUMAOptimized` flags to the core `EnergyProfile`. |

### 2. Thermal Management & PUE Optimization
| Component | Location | Description |
|-----------|----------|-------------|
| **Thermal Throttling Filter** | `pkg/plugins/filter/thermal_filter.go` | Data center automation logic that actively prevents LLM routing to GPUs exceeding physical thermal limits (e.g., >85°C), mitigating hot spots and cooling overhead. |

### 3. Slurm & KubeRay Cross-Compatibility
| Component | Location | Description |
|-----------|----------|-------------|
| **Slurm SPANK Adapter** | `pkg/slurm/spank_adapter.go` | Adapts the EnergyStore to classic HPC environments, forcing Slurm to schedule bare-metal jobs based on power/thermals rather than raw CPU availability. |
| **KubeRay Autoscaler Policy** | `pkg/ray/autoscaler_policy.go` | Prevents KubeRay from scaling up high-power GPU worker groups during carbon-heavy grid times, enforcing ASIC delegation. |

### 4. Linux Kernel eBPF Telemetry & Signal Processing
| Component | Location | Description |
|-----------|----------|-------------|
| **eBPF Zero-Overhead Token Tracker** | `pkg/ebpf/token_tracker.c` | A raw C Linux Traffic Control (TC) hook that counts LLM egress TCP payload bytes directly in kernel memory, bypassing Prometheus entirely. |
| **Microsecond Digital Low-Pass Filter** | `pkg/signals/energy_store.go` | Implemented Time-Aware EWMA and Welford's Online Algorithm to filter noisy GPU telemetry down to the exact microsecond. |

### 5. Kubernetes Operator Pattern & CRD Reconciliation
| Component | Location | Description |
|-----------|----------|-------------|
| **InferenceObjective Informer** | `pkg/config/inference_objective_watcher.go` | Built a full `client-go` Informer loop to dynamically reconcile Gateway API Inference Extension CRDs (`InferenceObjective`). Allows cluster admins to pivot between "CarbonMinimization", "Latency", and "CostReduction" states instantly without YAML restarts. |
| **Adaptive Force States** | `pkg/adaptive/weight_controller.go` | Modified the Adaptive Controller to accept external forcing signals from the Kubernetes API, bridging autonomous metrics with human-in-the-loop control logic. |
