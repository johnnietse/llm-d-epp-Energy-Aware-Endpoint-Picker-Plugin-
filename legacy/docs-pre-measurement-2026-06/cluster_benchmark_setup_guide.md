# Cluster Benchmark Setup Guide
## Energy-Aware EPP — From Simulation to Real-World Validation

> [!IMPORTANT]
> This guide answers: **"How do I run this on a real cluster to prove it actually works?"**
> It's organized from most realistic → most practical, with honest assessments of what each option proves.

---

## Table of Contents
1. [What You Already Have vs What You Need](#1-what-you-already-have-vs-what-you-need)
2. [Option A: University HPC Bare-Metal (Best for Thesis)](#2-option-a-university-hpc-bare-metal)
3. [Option B: Cloud GPUs via GKE/Lambda Labs (Fastest to Set Up)](#3-option-b-cloud-gpus)
4. [Option C: Single-Node Power-Cap Emulation (Cheapest)](#4-option-c-single-node-power-cap-emulation)
5. [Common Setup: Software Stack](#5-common-setup-software-stack)
6. [Experiment Matrix & What Each Proves](#6-experiment-matrix)
7. [Data Collection & Analysis Pipeline](#7-data-collection-pipeline)
8. [Time & Cost Estimates](#8-time-and-cost-estimates)
9. [What's Publishable From Each Option](#9-whats-publishable)

---

## 1. What You Already Have vs What You Need

### ✅ Already Done (Your Codebase)

| Component | Status | Files |
|-----------|--------|-------|
| EPP binary (Go, builds for linux/amd64) | ✅ Complete | [cmd/energy-epp/](file:///c:/Users/Johnnie/Documents/Energy_aware_token_level_routing_forheterogeneous_LLM_inference_in_kubernetes_design_implementation_and_evaluation_of_an_llm_d_endpoint_picker_plugin/cmd/energy-epp) |
| Scoring algorithms (energy, carbon, SCI) | ✅ 112 tests pass | [pkg/plugins/](file:///c:/Users/Johnnie/Documents/Energy_aware_token_level_routing_forheterogeneous_LLM_inference_in_kubernetes_design_implementation_and_evaluation_of_an_llm_d_endpoint_picker_plugin/pkg/plugins) |
| GIE v1.5.0 interface adapters | ✅ Compile-time verified | [pkg/config/gie_adapter.go](file:///c:/Users/Johnnie/Documents/Energy_aware_token_level_routing_forheterogeneous_LLM_inference_in_kubernetes_design_implementation_and_evaluation_of_an_llm_d_endpoint_picker_plugin/pkg/config/gie_adapter.go) |
| Adaptive weight controller | ✅ 4-mode FSM | [pkg/adaptive/](file:///c:/Users/Johnnie/Documents/Energy_aware_token_level_routing_forheterogeneous_LLM_inference_in_kubernetes_design_implementation_and_evaluation_of_an_llm_d_endpoint_picker_plugin/pkg/adaptive) |
| Prometheus metrics exporter (17 families) | ✅ | [pkg/metrics/](file:///c:/Users/Johnnie/Documents/Energy_aware_token_level_routing_forheterogeneous_LLM_inference_in_kubernetes_design_implementation_and_evaluation_of_an_llm_d_endpoint_picker_plugin/pkg/metrics) |
| Grafana dashboard (13 panels) | ✅ | [deploy/grafana/](file:///c:/Users/Johnnie/Documents/Energy_aware_token_level_routing_forheterogeneous_LLM_inference_in_kubernetes_design_implementation_and_evaluation_of_an_llm_d_endpoint_picker_plugin/deploy/grafana) |
| Dockerfile (multi-stage, distroless) | ✅ | [Dockerfile](file:///c:/Users/Johnnie/Documents/Energy_aware_token_level_routing_forheterogeneous_LLM_inference_in_kubernetes_design_implementation_and_evaluation_of_an_llm_d_endpoint_picker_plugin/Dockerfile) |
| K8s manifests (pool, deployment, config) | ✅ | [deploy/manifests/](file:///c:/Users/Johnnie/Documents/Energy_aware_token_level_routing_forheterogeneous_LLM_inference_in_kubernetes_design_implementation_and_evaluation_of_an_llm_d_endpoint_picker_plugin/deploy/manifests) |
| Hardware profiles (5 accelerators) | ✅ | [hardware_profiles.yaml](file:///c:/Users/Johnnie/Documents/Energy_aware_token_level_routing_forheterogeneous_LLM_inference_in_kubernetes_design_implementation_and_evaluation_of_an_llm_d_endpoint_picker_plugin/benchmarks/profiles/hardware_profiles.yaml) |
| E2E simulation (1000 cycles) | ✅ | [e2e_simulation_test.go](file:///c:/Users/Johnnie/Documents/Energy_aware_token_level_routing_forheterogeneous_LLM_inference_in_kubernetes_design_implementation_and_evaluation_of_an_llm_d_endpoint_picker_plugin/pkg/simulation/e2e_simulation_test.go) |

### ❌ Gaps That Require Real Hardware

| Gap | What's Missing | Why It Matters |
|-----|---------------|----------------|
| **Real DCGM power telemetry** | Your DCGM scraper exists but reads from simulated profiles | Can't claim "measured 17.53% savings" without real watts |
| **Real vLLM inference latency** | No actual model running; TTFT/TPOT are profile constants | Need to prove routing doesn't violate SLOs |
| **Real KV-cache transfer cost** | Transfer energy is modeled, not measured | Novel contribution needs empirical backing |
| **Actual end-to-end request routing** | EPP runs standalone or sidecar, but never routed a real request through Envoy | The full Gateway → ext_proc → EPP → vLLM path |
| **Load-dependent behavior** | Scoring uses static profiles, not load-varying power | Real GPUs draw different power under different batch sizes |

---

## 2. Option A: University HPC Bare-Metal

> **Best for thesis quality. If you have access to Queen's Centre for Advanced Computing (CAC) or any HPC with GPU nodes, this is the gold standard.**

### Hardware Needed

| Node | GPU | Purpose | Access Method |
|------|-----|---------|---------------|
| 1× Control plane | None (CPU-only) | K8s master + monitoring | Any Linux VM |
| 1× H100 or A100 node | NVIDIA H100/A100 | Prefill worker | HPC GPU queue |
| 1× A100 power-capped node | Same A100, capped to 200W | Decode worker (mid-tier) | Same GPU, `nvidia-smi -pl 200` |
| 1× CPU/L4 node | NVIDIA L4 or CPU-only | Decode worker (low-power) | HPC inference queue |

> [!TIP]
> **You don't need 3 different GPU types!** A single A100 node can emulate all 3 hardware classes using NVIDIA power capping:
> ```bash
> # "H100-like" — run at full 250W TDP
> sudo nvidia-smi -pl 250
>
> # "A100 power-capped" — cap to 200W  
> sudo nvidia-smi -pl 200
>
> # "Low-power decode" — cap to 100W (emulates efficient ASIC)
> sudo nvidia-smi -pl 100
> ```
> This is the **power-cap emulation** approach and is perfectly valid for a thesis — many papers (including throttLLeM) use this.

### Step-by-Step Setup

```bash
# ── 1. Get a GPU allocation ──────────────────────────────────────
# At Queen's CAC or your university's SLURM cluster:
salloc --nodes=2 --gres=gpu:a100:1 --time=6:00:00 --partition=gpu

# ── 2. Install Kubernetes on the allocated nodes ─────────────────
# On the control plane node:
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644

# On each worker node (get token from control plane):
curl -sfL https://get.k3s.io | K3S_URL=https://<control-plane-ip>:6443 \
  K3S_TOKEN=<node-token> sh -

# ── 3. Install NVIDIA device plugin (for GPU access in K8s) ─────
kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml

# ── 4. Label nodes for heterogeneous routing ─────────────────────
kubectl label node <worker-1> llm-d.ai/hardware-class=GPU_HIGH_PERF llm-d.ai/tdp-watts=250 llm-d.ai/role=prefill
kubectl label node <worker-2> llm-d.ai/hardware-class=GPU_MED_PERF  llm-d.ai/tdp-watts=200 llm-d.ai/role=decode

# ── 5. Set power caps to create heterogeneity ───────────────────
# On worker-1 (prefill, full power):
ssh <worker-1> 'sudo nvidia-smi -pl 250'

# On worker-2 (decode, power-capped):
ssh <worker-2> 'sudo nvidia-smi -pl 150'
```

> [!NOTE]
> **K3s vs kubeadm**: K3s is dramatically easier to set up on HPC allocations (single binary, no systemd dependency). Use it unless your university mandates kubeadm.

---

## 3. Option B: Cloud GPUs

> **Fastest to set up. Most expensive per hour. Best if you need results in a weekend.**

### GKE (Since You Already Have gcloud Set Up)

```bash
# ── 1. Create cluster with a CPU control plane ──────────────────
gcloud container clusters create energy-epp-bench \
  --zone us-central1-a \
  --num-nodes=1 \
  --machine-type e2-standard-4

# ── 2. Add GPU node pool — "Prefill" (A100, full power) ─────────
gcloud container node-pools create prefill-pool \
  --cluster energy-epp-bench \
  --zone us-central1-a \
  --machine-type a2-highgpu-1g \
  --accelerator type=nvidia-tesla-a100,count=1 \
  --num-nodes=1 \
  --node-labels=llm-d.ai/hardware-class=GPU_HIGH_PERF,llm-d.ai/role=prefill

# ── 3. Add GPU node pool — "Decode" (L4, low power) ─────────────
gcloud container node-pools create decode-pool \
  --cluster energy-epp-bench \
  --zone us-central1-a \
  --machine-type g2-standard-4 \
  --accelerator type=nvidia-l4,count=1 \
  --num-nodes=1 \
  --node-labels=llm-d.ai/hardware-class=GPU_MED_PERF,llm-d.ai/role=decode

# ── 4. Install NVIDIA GPU Operator ──────────────────────────────
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator --create-namespace \
  --set dcgmExporter.enabled=true

# ── 5. Get credentials ──────────────────────────────────────────
gcloud container clusters get-credentials energy-epp-bench --zone us-central1-a
```

### Lambda Labs (Cheapest Per-GPU-Hour)

```bash
# Lambda Labs API — ~$2/hr per A100, ~$0.80/hr per L4 equivalent
# 1. Create 2 instances via dashboard or API
# 2. SSH in, install k3s (same as Option A)
# 3. Total cost for a 4-hour experiment: ~$12
```

> [!WARNING]
> **GKE GPU costs**: An A100 node is ~$3.67/hr, an L4 is ~$0.70/hr. Budget **$25-40 for a full experiment run** (4-6 hours including setup). Set a billing alarm!

---

## 4. Option C: Single-Node Power-Cap Emulation

> **Cheapest option ($0). Runs on any Linux box with a single NVIDIA GPU. Still produces publishable results.**

This is the approach used in many systems papers (throttLLeM, Zeus, etc.) — run the same GPU at different power caps to emulate heterogeneous hardware.

### What You Need
- 1× Linux machine with a NVIDIA GPU (even a GTX 3090 or A4000 works)
- Docker + Kind (or just k3s)

### How It Works

```bash
# ── Phase 1: "H100-like" full-power run ─────────────────────────
sudo nvidia-smi -pl 350  # or whatever your GPU's max TDP is
# Deploy vLLM, run workload, collect DCGM metrics for 10 minutes

# ── Phase 2: "A100 power-capped" run ────────────────────────────
sudo nvidia-smi -pl 200
# Same workload, collect metrics

# ── Phase 3: "Low-power ASIC-like" run ──────────────────────────
sudo nvidia-smi -pl 100
# Same workload, collect metrics

# ── Now you have real power/latency data at 3 operating points ──
# Feed this into your EPP scorer and show that it correctly routes
# prefill → full-power and decode → low-power
```

### Why This Is Valid
- You're measuring **real GPU power draw** via DCGM (not simulated)
- You're measuring **real inference latency** (TTFT, TPOT) under different power constraints
- The EPP scoring logic is **identical** to what runs in production
- Papers like *throttLLeM (HPCA 2025)* and *Zeus (NSDI 2023)* use this exact methodology

> [!TIP]
> This is probably your **best bet** if you want quick results. You can even do this on your local machine if you have a NVIDIA GPU, or on a single HPC node with a GPU allocation.

---

## 5. Common Setup: Software Stack

Regardless of which option you choose, you need this software stack deployed:

### 5.1 — Deploy vLLM Model Servers

```yaml
# deploy/benchmarks/vllm-server.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-llama-7b
  namespace: inference
spec:
  replicas: 1
  selector:
    matchLabels: { app: vllm }
  template:
    metadata:
      labels: { app: vllm }
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8000"
    spec:
      containers:
        - name: vllm
          image: vllm/vllm-openai:v0.8.0
          args:
            - "--model"
            - "meta-llama/Llama-3.2-3B-Instruct"  # Small enough for any GPU
            - "--max-model-len"
            - "2048"
            - "--dtype"
            - "float16"
          ports:
            - containerPort: 8000
          resources:
            limits:
              nvidia.com/gpu: 1
          env:
            - name: HUGGING_FACE_HUB_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-token
                  key: token
```

> [!IMPORTANT]
> **Model choice matters.** Use `Llama-3.2-3B-Instruct` (3B params) for benchmarks — it fits on any GPU with >8GB VRAM and still shows meaningful prefill vs decode latency differences. Don't use 70B unless you have H100s.

### 5.2 — Deploy Monitoring Stack

```bash
# Prometheus + Grafana
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.adminPassword=energy-epp

# DCGM Exporter (if not using GPU Operator)
helm install dcgm-exporter nvidia/dcgm-exporter \
  --namespace monitoring \
  --set serviceMonitor.enabled=true
```

### 5.3 — Build & Deploy Your EPP

```bash
# Build for Linux (from your Windows machine)
$env:GOOS="linux"; $env:GOARCH="amd64"; $env:CGO_ENABLED="0"
go build -ldflags="-s -w" -o bin/energy-epp-linux ./cmd/energy-epp/

# Or use Docker
docker build -t energy-epp:bench .

# If using Kind, load the image
kind load docker-image energy-epp:bench --name energy-epp-dev

# Deploy
kubectl apply -f deploy/manifests/energy-epp-deployment.yaml
kubectl apply -f deploy/manifests/energy-epp-config.yaml
kubectl apply -f deploy/manifests/heterogeneous-pool.yaml
```

### 5.4 — Deploy Gateway (For Full E2E Path)

```bash
# Gateway API CRDs
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.3.0/standard-install.yaml

# Envoy Gateway
helm install envoy-gateway oci://docker.io/envoyproxy/gateway-helm \
  --version v1.2.0 -n envoy-gateway-system --create-namespace

# Inference Extension CRDs (GIE)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/v0.3.0/manifests.yaml
```

---

## 6. Experiment Matrix

### The 6 Experiments You Need

| ID | Name | What It Tests | Variable | Control | Duration |
|----|------|--------------|----------|---------|----------|
| **B1** | Baseline Round-Robin | Default K8s routing | No EPP | Same workload | 10 min |
| **B2** | Baseline Least-Loaded | Queue-depth only routing | Standard EPP (no energy) | Same workload | 10 min |
| **E1** | Energy-Aware (Prefill) | Phase-aware prefill routing | EPP with prefill weights | Same workload | 10 min |
| **E2** | Energy-Aware (Decode) | Phase-aware decode routing | EPP with decode weights | Same workload | 10 min |
| **E3** | Power-Cap Sweep | Energy at different TDPs | Power limit (100/200/300W) | Same workload | 30 min |
| **E4** | Load Sweep | Throughput vs energy curve | Request rate (1→50 RPS) | Same config | 30 min |

### What Each Experiment Produces

```
B1 vs E1/E2 → "Energy-aware routing reduces energy by X% vs round-robin"
B2 vs E1/E2 → "Phase-aware routing improves on load-only routing"
E3          → "Power-cap sensitivity: relationship between TDP limit and energy/token"
E4          → "Energy-performance Pareto frontier under load"
```

### Workload Generation Script

```bash
#!/bin/bash
# benchmarks/scripts/run-cluster-benchmark.sh

GATEWAY_URL="http://$(kubectl get svc envoy-gateway -n envoy-gateway-system -o jsonpath='{.status.loadBalancer.ingress[0].ip}'):8080"
MODEL="meta-llama/Llama-3.2-3B-Instruct"
RESULTS_DIR="benchmarks/results/$(date +%Y-%m-%d_%H-%M)"
mkdir -p "$RESULTS_DIR"

# ── B1: Baseline (no EPP, round-robin) ────────────────────────────
echo "Running B1: Baseline Round-Robin..."
python -m vllm.entrypoints.openai.api_server_benchmark \
  --model "$MODEL" \
  --num-prompts 500 \
  --request-rate 10 \
  --endpoint "$GATEWAY_URL/v1/chat/completions" \
  2>&1 | tee "$RESULTS_DIR/b1_baseline.txt"

# Snapshot Prometheus metrics
curl -s "http://prometheus:9090/api/v1/query?query=DCGM_FI_DEV_POWER_USAGE" \
  > "$RESULTS_DIR/b1_power.json"

# ── E1: Energy-Aware Routing ─────────────────────────────────────
echo "Running E1: Energy-Aware..."
# (Enable EPP via InferencePool.endpointPickerConfig)
kubectl apply -f deploy/manifests/energy-epp-config.yaml

python -m vllm.entrypoints.openai.api_server_benchmark \
  --model "$MODEL" \
  --num-prompts 500 \
  --request-rate 10 \
  --endpoint "$GATEWAY_URL/v1/chat/completions" \
  2>&1 | tee "$RESULTS_DIR/e1_energy_aware.txt"

curl -s "http://prometheus:9090/api/v1/query?query=DCGM_FI_DEV_POWER_USAGE" \
  > "$RESULTS_DIR/e1_power.json"

# ── E3: Power-Cap Sweep ──────────────────────────────────────────
for cap in 100 150 200 250 300; do
  echo "Running E3: Power cap = ${cap}W..."
  ssh gpu-node "sudo nvidia-smi -pl $cap"
  sleep 10  # Let GPU stabilize

  python -m vllm.entrypoints.openai.api_server_benchmark \
    --model "$MODEL" \
    --num-prompts 200 \
    --request-rate 5 \
    --endpoint "$GATEWAY_URL/v1/chat/completions" \
    2>&1 | tee "$RESULTS_DIR/e3_cap_${cap}w.txt"

  curl -s "http://prometheus:9090/api/v1/query?query=DCGM_FI_DEV_POWER_USAGE" \
    > "$RESULTS_DIR/e3_power_${cap}w.json"
done
```

---

## 7. Data Collection Pipeline

### Metrics to Scrape (Every 5 Seconds During Each Experiment)

```bash
# Prometheus queries to run via API or record as rules

# GPU power (watts) — from DCGM
DCGM_FI_DEV_POWER_USAGE

# GPU utilization (%) — from DCGM
DCGM_FI_DEV_GPU_UTIL

# Cumulative energy (joules) — from DCGM
DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION

# vLLM latency metrics
vllm:time_to_first_token_seconds_bucket    # TTFT histogram
vllm:inter_token_latency_seconds_bucket    # ITL/TPOT histogram
vllm:num_requests_running                  # Active requests

# EPP custom metrics (from your Prometheus exporter)
epp_energy_per_token_millijoules           # Energy efficiency
epp_routing_decisions_total                # Which pod was chosen
epp_carbon_intensity_gco2_per_kwh          # Grid carbon
epp_sci_score_gco2_per_request             # ISO SCI
epp_adaptive_mode                          # Controller state
```

### Post-Experiment Analysis

Your existing [analyze_results.py](file:///c:/Users/Johnnie/Documents/Energy_aware_token_level_routing_forheterogeneous_LLM_inference_in_kubernetes_design_implementation_and_evaluation_of_an_llm_d_endpoint_picker_plugin/benchmarks/scripts/analyze_results.py) handles the KPI computation. For cluster benchmarks, you'd extend it to:

1. **Pull Prometheus range queries** for the experiment window
2. **Compute aggregate energy** = ∫ power dt (from DCGM cumulative energy)
3. **Compute per-request metrics** = total_energy / total_requests
4. **Generate comparison charts** (bar charts, Pareto frontiers, CDFs)

---

## 8. Time & Cost Estimates

| Option | Setup Time | Run Time | Cost | Result Quality |
|--------|-----------|----------|------|----------------|
| **A: University HPC** | 2-3 hours | 2-3 hours | $0 (allocation) | ⭐⭐⭐⭐⭐ |
| **B: GKE Cloud** | 1 hour | 2-3 hours | $25-50 | ⭐⭐⭐⭐ |
| **B: Lambda Labs** | 1 hour | 2-3 hours | $12-20 | ⭐⭐⭐⭐ |
| **C: Single-node power-cap** | 30 min | 1-2 hours | $0 | ⭐⭐⭐ |
| **C: Kind (current)** | 0 | 5 min | $0 | ⭐⭐ (simulation only) |

---

## 9. What's Publishable From Each Option

### Option C (Single-Node Power-Cap) — Minimum Viable Thesis Evaluation

You can produce these thesis-quality results:

| Claim | Evidence |
|-------|----------|
| "Energy-aware routing reduces energy/token by X%" | Compare baseline vs EPP at same power cap |
| "Power-capped GPU achieves Y tokens/watt" | Direct DCGM measurement |
| "Prefill and decode have different optimal power points" | E3 sweep data |
| "EPP scoring correctly routes to lowest-energy endpoint" | Routing decision logs vs actual power |

### Option A/B (Multi-Node) — Full Thesis Evaluation

Everything above, **plus**:

| Claim | Evidence |
|-------|----------|
| "Heterogeneous routing across different hardware types" | Real H100 vs A100 vs L4 |
| "KV-cache transfer energy cost is measurable" | Network + GPU energy during migration |
| "Adaptive controller responds to real carbon grid data" | Multi-hour run spanning grid changes |
| "Full Envoy→EPP→vLLM path works end-to-end" | Request traces through entire stack |

---

## Recommended Path Forward

> [!IMPORTANT]
> **My recommendation: Start with Option C** (single-node power-cap on any GPU you can access). Here's why:

1. **It produces real, measured data** — actual watts from DCGM, actual latency from vLLM
2. **It validates the core thesis claim** — that phase-aware routing saves energy
3. **The EPP code is identical** — same binary, same scoring, same metrics
4. **It's free and fast** — you can do it in an afternoon
5. **If Option C works, Option A is just a bigger version** — the upgrade path is clean

### Concrete Next Steps

```
Week 1: Option C
  ├── Get SSH access to any machine with a NVIDIA GPU
  ├── Install k3s + vLLM + your EPP
  ├── Run E3 (power-cap sweep) — takes 30 minutes
  ├── Run B1 vs E1 (baseline vs energy-aware) — takes 20 minutes
  └── Generate results with analyze_results.py

Week 2: Option A (if university GPU time available)
  ├── Request 2-node GPU allocation (4-6 hours)
  ├── Deploy full stack with different-TDP nodes
  ├── Run complete experiment matrix (E1-E4)
  └── Produce final thesis figures
```

### What Changes In Your Code For Real Deployment

Almost nothing. The key change is in the **data source**:

| Component | Current (Simulation) | Cluster (Real) | Code Change Needed |
|-----------|---------------------|----------------|-------------------|
| Power data | Hardcoded profiles | DCGM scraper (already implemented) | Set `DCGM_ENDPOINT` env var |
| Carbon data | CO2Signal API (already real) | Same | None |
| Latency data | Profile constants | vLLM `/metrics` | Set `VLLM_METRICS_URL` env var |
| Scoring logic | Same | Same | **None** |
| Adaptive controller | Same | Same | **None** |
| Prometheus export | Same | Same | **None** |

> The architecture was designed for this exact transition. The "gap" between simulation and production is **configuration, not code**.
