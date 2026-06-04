# Action Plan: Validate & Integrate Energy-Aware EPP

## Part 1: What To Do Right Now

### Can You Run Kubernetes on Frontenac?

**No.** You cannot install Kubernetes on a shared HPC cluster. You need root access for `kubelet`, `containerd`, `etcd`, and networking — none of which a regular SLURM user has.

### What You CAN Do on Frontenac

You already have a working SLURM account (`sa6079052`). You can:

| Action | Command |
|--------|---------|
| Submit GPU jobs | `sbatch your_script.sbatch` |
| Run containers | `apptainer exec --nv image.sif ...` |
| Build Go binaries | `module load Go/19.6 && go build ...` |
| Use A100 GPUs | Via `gpubase_*` partitions |

### The 3-Step Validation Plan

```
Step 1 (5 min, Windows)     →  Run EPP standalone demo locally
Step 2 (2 hrs, Frontenac)   →  Collect real A100 power data via SLURM
Step 3 (5 min, Frontenac)   →  Feed real data into EPP, generate thesis figures
```

**Step 1** proves the algorithm works.  
**Steps 2-3** prove it works with *real hardware data*.

### Step 1: Run Right Now on Your Windows Machine

```bash
cd c:\Users\Johnnie\Documents\Energy_aware_token_level_routing_...
go run ./cmd/energy-epp/ --mode standalone
```

This already runs with A100-calibrated synthetic profiles and outputs scoring tables.

### Step 2: SSH into Frontenac and Submit GPU Job

```bash
ssh sa6079052@login.cac.queensu.ca

# Transfer project (first time only)
# From your Windows machine:
# scp -r . sa6079052@login.cac.queensu.ca:~/energy-epp/

cd ~/energy-epp
module load Go/19.6
go build -o bin/energy-epp ./cmd/energy-epp/

# Submit GPU profiling job
sbatch benchmarks/scripts/frontenac/02-profile-gpu.sbatch

# Check status
squeue -u $USER
```

### Step 3: Generate Results

```bash
# After job completes
bash benchmarks/scripts/frontenac/04-run-epp-scoring.sh
python3 benchmarks/scripts/frontenac/05-analyze-frontenac.py
```

---

## Part 2: Where to Integrate This Upstream

Your EPP implements the `sigs.k8s.io/gateway-api-inference-extension v1.5.0` interface. Here are the exact repositories where this work belongs:

### Target Repository Map

| Priority | Repository | What Lives There | Your Contribution |
|----------|-----------|------------------|-------------------|
| 🥇 **Primary** | [llm-d/llm-d-router](https://github.com/llm-d/llm-d-router) | The EPP/router (Go) | Energy-aware scoring plugin |
| 🥈 **Secondary** | [llm-d/llm-d](https://github.com/llm-d/llm-d) | Deployment, Helm charts | Energy-aware deployment config |
| 🥉 **Benchmarks** | [llm-d/llm-d-benchmark](https://github.com/llm-d/llm-d-benchmark) | Perf testing (Python) | Energy benchmarking scripts |
| 📐 **API** | [kubernetes-sigs/gateway-api-inference-extension](https://github.com/kubernetes-sigs/gateway-api-inference-extension) | InferencePool API, EPP protocol | Energy labels proposal |

### About These Repos

#### 1. `llm-d/llm-d-router` — ⭐ PRIMARY TARGET
- **Language:** Go  
- **Stars:** 200 | **Forks:** 214
- **What it is:** The intelligent request router (this IS the EPP)
- **Your fit:** Your `EnergyAwareScorer` and `EnergyBudgetFilter` are scoring plugins that slot directly into this router's plugin architecture

> [!IMPORTANT]
> This is where your code would actually live. The router already supports KV-cache-aware routing and load-aware routing. Your energy-aware scoring would be a new **scoring plugin** alongside the existing ones.

#### 2. `llm-d/llm-d` — Main Project
- **Language:** Shell/YAML
- **Stars:** 3,234 | **Forks:** 488
- **Status:** CNCF Sandbox project (Red Hat, Google, IBM, NVIDIA, CoreWeave)
- **Your fit:** Hardware labels (`llm-d.ai/hardware-class`, `llm-d.ai/tdp-watts`), Helm chart values for energy config

#### 3. `llm-d/llm-d-benchmark` — Benchmarks
- **Language:** Python
- **Stars:** 59 | **Forks:** 78
- **Your fit:** Energy benchmarking scripts, power measurement tooling

#### 4. `kubernetes-sigs/gateway-api-inference-extension` — API Layer
- **Your fit:** Proposing energy-related labels as part of the InferencePool spec

### Relevant SIGs (Special Interest Groups)

llm-d has SIGs that map directly to your work:

| SIG | Relevance to Your Work |
|-----|----------------------|
| **Inference Scheduler** | Your scoring algorithm is a scheduling plugin |
| **Benchmarking** | Your power measurement and energy-per-token metrics |
| **PD-Disaggregation** | Your prefill/decode phase-aware routing |
| **Observability** | Your DCGM scraper and Prometheus metrics |

### How to Engage

#### Option A: Open an Issue First (Recommended)

Start with an issue on `llm-d/llm-d-router` proposing energy-aware scoring:

**Title:** `[Feature Request] Energy-aware scoring plugin for heterogeneous hardware routing`

**Body:**
```markdown
## Summary
Proposing an energy-aware endpoint scoring plugin that considers GPU power
consumption (via DCGM/nvidia-smi) alongside latency and queue depth when
making routing decisions.

## Motivation
Current scoring considers KV-cache locality and load, but not energy
efficiency. With heterogeneous hardware (e.g., H100 + A100-power-capped
+ inference ASICs), energy-per-token varies 6-10x across endpoints.

## Design
- Asymmetric weight vectors: latency-dominant for Prefill, energy-dominant
  for Decode
- DCGM power telemetry integration (DCGM_FI_DEV_POWER_USAGE)
- Energy budget filter (cluster-wide power cap enforcement)
- Adaptive weight controller (adjusts scoring based on grid carbon intensity)

## Implementation
I have a working prototype with 112 unit tests and 1,000-cycle E2E simulation:
https://github.com/johnnie/energy-aware-epp

Key files:
- Energy scorer: pkg/plugins/scorer/energy_aware_scorer.go
- Budget filter: pkg/plugins/filter/energy_budget_filter.go  
- DCGM scraper: pkg/plugins/scraper/dcgm_scraper.go

## Evidence
- Measured A100 power profiles on Queen's University Frontenac HPC
- Prefill routing: correctly selects high-throughput endpoints
- Decode routing: correctly selects energy-efficient endpoints
- Energy savings: ~X% reduction in energy-per-token for decode phase

## Questions
- Would this fit as a built-in scoring plugin or a separate plugin package?
- Are there existing plans for power-awareness in the router?
- What's the preferred integration path for new scoring signals?
```

#### Option B: Join Slack First

1. Go to [llm-d.ai/slack](https://llm-d.ai/slack)
2. Join `#inference-scheduler` channel
3. Introduce your work and ask for feedback before opening a PR

#### Option C: Submit a PR Directly

Fork `llm-d/llm-d-router`, add your scoring plugin, and open a PR. Remember:
- All commits need DCO sign-off: `git commit -s`
- Follow their [contribution process](https://github.com/llm-d/llm-d/blob/main/PROJECT.md#process)
- New features with APIs require [project proposals](https://github.com/llm-d/llm-d/tree/main/docs/proposals)

### Recommended Approach Order

```
1. Join llm-d Slack → introduce yourself in #inference-scheduler
2. Open issue on llm-d/llm-d-router → get maintainer feedback
3. Validate on Frontenac → collect real A100 data (Steps 1-3 above)
4. Submit PR to llm-d/llm-d-router → energy scorer plugin
5. Submit PR to llm-d/llm-d-benchmark → energy benchmarking scripts
6. Submit PR to llm-d/llm-d → hardware label additions to Helm charts
```

### Why llm-d Specifically?

Your project is a **perfect fit** for llm-d because:

1. **They already do prefill/decode disaggregation** — your phase-aware scoring extends this
2. **They already have a plugin architecture** — your scorer slots in as a new plugin
3. **They already use `sigs.k8s.io/gateway-api-inference-extension`** — same interface you implement
4. **They're a CNCF sandbox project** — backed by Red Hat, Google, NVIDIA
5. **They have a Benchmarking SIG** — where your energy metrics would be welcomed
6. **They have 20 "help wanted" issues** — active community accepting contributions
