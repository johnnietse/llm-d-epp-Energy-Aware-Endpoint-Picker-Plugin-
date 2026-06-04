# Quick Start Guide
## Energy-Aware Endpoint Picker Plugin for llm-d

Get the energy-aware EPP running in under 10 minutes, on any platform.

---

## Prerequisites

| Tool | Version | Install |
|------|---------|---------|
| **Go** | 1.25+ | [go.dev/dl](https://go.dev/dl/) |
| **Docker** | 24+ | [docs.docker.com/get-docker](https://docs.docker.com/get-docker/) |
| **kubectl** | 1.25+ | [kubernetes.io/docs/tasks/tools](https://kubernetes.io/docs/tasks/tools/) |
| **Kind** | 0.20+ | `go install sigs.k8s.io/kind@latest` |
| **Python** | 3.10+ | [python.org](https://www.python.org/) *(optional, for diagrams)* |
| **Make** | 4+ | Included on Linux/macOS; on Windows use WSL2 or Git Bash |

> [!NOTE]
> **Windows users**: All scripts use Bash. Run them inside WSL2, Git Bash, or a Linux container. The Go binary itself compiles natively on Windows.

---

## Option 1: Run Tests Only (No Kubernetes)

The fastest way to verify the project works:

```bash
# Clone the repository
git clone https://github.com/johnnietse/llm-d-epp-Energy-Aware-Endpoint-Picker-Plugin-.git
cd llm-d-epp-Energy-Aware-Endpoint-Picker-Plugin-

# Run all Go unit tests (112 tests across 8 packages)
go test -v -count=1 ./pkg/...

# Run the 1000-cycle end-to-end simulation
go test -v -run TestEndToEnd_FullPipelineSimulation ./pkg/simulation/
```

Expected output:
```
A1: GPU prefill wins: 404/405 (99.8%)
A2: ASIC decode wins: 595/595 (100.0%)
A4: GPU kWh/1M=0.1910, ASIC kWh/1M=0.0331
SIMULATION COMPLETE: 1000 cycles, all assertions passed
```

---

## Option 2: Local Kind Cluster (Simulated GPUs)

Deploy the full EPP with simulated heterogeneous hardware in a local Kind cluster:

```bash
# One-command setup: creates cluster, builds image, deploys EPP + sim pods
./deploy/kind/setup-cluster.sh --demo
```

This creates:
- A 4-node Kind cluster with hardware labels (`GPU_HIGH_PERF`, `GPU_MED_PERF`, `ASIC_LOW_POWER`)
- The EPP deployment with health checks
- Simulated vLLM pods with fake DCGM metrics

### Verify it works

```bash
# Check cluster status
./deploy/kind/setup-cluster.sh --status

# Port-forward to the EPP health endpoint
kubectl -n llm-inference port-forward svc/energy-epp 8080:8080 &

# Check health
curl http://localhost:8080/healthz

# View energy metrics
curl http://localhost:8080/metrics/prometheus
```

### Teardown

```bash
./deploy/kind/setup-cluster.sh --teardown
```

---

## Option 3: Cloud Kubernetes (Real GPUs)

### Google Cloud (GKE)

```bash
# Set up environment
export PROJECT_ID=your-gcp-project
export ZONE=us-central1-a

# Create cluster with GPU node pools
gcloud container clusters create energy-epp-eval \
  --zone $ZONE --num-nodes=1 --project $PROJECT_ID

# Add H100 prefill pool
gcloud container node-pools create prefill-h100 \
  --cluster energy-epp-eval --zone $ZONE \
  --machine-type a3-highgpu-1g \
  --accelerator type=nvidia-h100-80gb,count=1 \
  --num-nodes=1 \
  --node-labels=llm-d.ai/hardware-class=GPU_HIGH_PERF,llm-d.ai/tdp-watts=700,llm-d.ai/role=prefill

# Add L4 decode pool
gcloud container node-pools create decode-l4 \
  --cluster energy-epp-eval --zone $ZONE \
  --machine-type g2-standard-4 \
  --accelerator type=nvidia-l4,count=1 \
  --num-nodes=1 \
  --node-labels=llm-d.ai/hardware-class=GPU_MED_PERF,llm-d.ai/tdp-watts=72,llm-d.ai/role=decode

# Install NVIDIA GPU operator
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
helm install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator --create-namespace \
  --set dcgmExporter.enabled=true

# Build and push EPP image
docker build -t gcr.io/$PROJECT_ID/energy-epp:v1.0.0 .
docker push gcr.io/$PROJECT_ID/energy-epp:v1.0.0

# Deploy
kubectl apply -f deploy/manifests/energy-epp-deployment.yaml
```

### AWS (EKS)

```bash
# Create cluster
eksctl create cluster --name energy-epp-eval --region us-east-1

# Add GPU node groups
eksctl create nodegroup --cluster energy-epp-eval \
  --name prefill-h100 --instance-types p5.48xlarge --nodes 1 \
  --node-labels=llm-d.ai/hardware-class=GPU_HIGH_PERF,llm-d.ai/tdp-watts=700

eksctl create nodegroup --cluster energy-epp-eval \
  --name decode-l4 --instance-types g6.xlarge --nodes 1 \
  --node-labels=llm-d.ai/hardware-class=GPU_MED_PERF,llm-d.ai/tdp-watts=72

# Same GPU operator + EPP deployment as above
```

### Azure (AKS)

```bash
az aks create --name energy-epp-eval --resource-group your-rg \
  --node-count 1 --generate-ssh-keys

az aks nodepool add --cluster-name energy-epp-eval --resource-group your-rg \
  --name prefillh100 --node-count 1 --node-vm-size Standard_ND96isr_H100_v5 \
  --labels llm-d.ai/hardware-class=GPU_HIGH_PERF llm-d.ai/tdp-watts=700
```

---

## Option 4: With Official llm-d-router (Upstream Integration)

If you want to run the energy-aware scorer inside the official `llm-d-router`, here's how:

### Step 1: Clone the official llm-d-router
```bash
git clone https://github.com/llm-d/llm-d-router.git
cd llm-d-router
```

### Step 2: Copy the energy-aware scorer plugin
```bash
# Copy from our repo's upstream-port into the official plugin directory
mkdir -p pkg/epp/framework/plugins/scheduling/scorer/energyaware
cp /path/to/our-repo/upstream-port/energy_aware.go \
   pkg/epp/framework/plugins/scheduling/scorer/energyaware/
cp /path/to/our-repo/upstream-port/energy_aware_test.go \
   pkg/epp/framework/plugins/scheduling/scorer/energyaware/
cp /path/to/our-repo/upstream-port/README.md \
   pkg/epp/framework/plugins/scheduling/scorer/energyaware/
```

### Step 3: Register the plugin (one line change)

Edit `cmd/epp/runner/runner.go` and add this import:
```go
"github.com/llm-d/llm-d-router/pkg/epp/framework/plugins/scheduling/scorer/energyaware"
```

Then add this line inside `registerInTreePlugins()`:
```go
fwkplugin.Register(energyaware.EnergyAwareType, energyaware.Factory)
```

### Step 4: Deploy using the official llm-d workflow
```bash
# The official one-command local dev setup
make env-dev-kind

# Port-forward to test
kubectl port-forward service/inference-gateway-istio 8080:80

# Send an inference request
curl -s http://localhost:8080/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"TinyLlama/TinyLlama-1.1B-Chat-v1.0","prompt":"hi","max_tokens":10}' | jq
```

### Step 5: Enable energy-aware scoring in the config
Add to your `EndpointPickerConfig`:
```yaml
scorers:
  - type: energy-aware-scorer
    weight: 5
    parameters:
      prefillLatencyWeight: 0.7
      prefillEnergyWeight: 0.2
      prefillCarbonWeight: 0.1
      decodeLatencyWeight: 0.15
      decodeEnergyWeight: 0.65
      decodeCarbonWeight: 0.20
      fallbackCarbonIntensity: 390
```

---

## Generating Diagrams & Figures

Reproduce all publication-quality diagrams:

```bash
# Install Python dependencies
pip install matplotlib numpy pandas pyyaml

# Generate all figures (one command)
make gen-figures

# Or run individual scripts
python benchmarks/scripts/generate_advanced_diagrams.py
python benchmarks/scripts/generate_new_diagrams.py
python benchmarks/scripts/generate_extra_diagrams.py
```

Output goes to `docs/diagrams/` and `docs/figures/`.

---

## Project Structure

```
.
├── cmd/energy-epp/          # Main binary entry point
├── pkg/
│   ├── adaptive/            # FSM controller (Normal/Carbon-High/Load-Shed/Green)
│   ├── config/              # GIE-compatible plugin configuration
│   ├── metrics/             # Prometheus metrics (17 families)
│   ├── plugins/
│   │   ├── filter/          # SLO + energy budget filters
│   │   ├── scorer/          # Multi-objective energy scorer
│   │   └── scraper/         # DCGM/RAPL telemetry scraper
│   ├── signals/             # EnergyStore, SCI calculator, types
│   └── simulation/          # 1000-cycle E2E simulation test
├── upstream-port/           # Bridge file for official llm-d-router integration
├── deploy/
│   ├── kind/                # Local Kind cluster setup (setup-cluster.sh)
│   ├── manifests/           # Production K8s YAML (Deployment, Service, Config)
│   ├── helm/                # Helm chart
│   └── grafana/             # Grafana dashboard JSON
├── benchmarks/
│   ├── profiles/            # Hardware TDP profiles, carbon intensity data
│   ├── traces/              # Reproducible workload traces
│   └── scripts/             # Diagram generation scripts
├── docs/
│   ├── diagrams/            # ~18 publication-quality PNG diagrams
│   └── figures/             # Generated evaluation figures
├── llm-d-ref/               # Official llm-d-router source (git submodule reference)
├── Dockerfile               # Multi-stage build (8.6 MB distroless)
├── Makefile                 # Build, test, deploy automation
└── production_deployment_guide.md  # Full production setup documentation
```

---

## Makefile Targets

```bash
make build          # Build Go binary
make test           # Run all tests
make docker         # Build Docker image
make kind-demo      # Deploy to local Kind cluster
make bench-report   # Regenerate all figures
make gen-figures    # Generate advanced diagrams only
make lint           # Run golangci-lint
make clean          # Clean build artifacts
```

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `upstream-port` tests fail | Expected — requires `llm-d-router` dependencies. Run `go test ./pkg/...` instead |
| Kind cluster won't start | Ensure Docker is running: `docker ps` |
| Diagrams fail with Unicode errors | Set `PYTHONIOENCODING=utf-8` before running |
| Go build fails | Ensure Go 1.25+: `go version` |
| Windows line ending issues | Run `git config core.autocrlf true` |

---

## Links

- **This repo**: [github.com/johnnietse/llm-d-epp-Energy-Aware-Endpoint-Picker-Plugin-](https://github.com/johnnietse/llm-d-epp-Energy-Aware-Endpoint-Picker-Plugin-)
- **Official llm-d-router**: [github.com/llm-d/llm-d-router](https://github.com/llm-d/llm-d-router)
- **Gateway API Inference Extension**: [gateway-api-inference-extension.sigs.k8s.io](https://gateway-api-inference-extension.sigs.k8s.io)
- **llm-d community Slack**: [llm-d.slack.com](https://llm-d.slack.com)
