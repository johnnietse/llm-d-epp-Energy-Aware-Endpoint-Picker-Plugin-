# Frontenac HPC Benchmark Guide — Energy-Aware EPP

> [!IMPORTANT]
> Frontenac is a **SLURM-managed HPC cluster** — you **cannot** install Kubernetes, k3s, or Docker. All benchmarks run via SLURM batch jobs with Apptainer (Singularity) containers.

## Cluster Resources You Have

| Resource | Specification |
|----------|--------------|
| **GPU Nodes** | 2× DGX A100 (8×A100 40GB each) |
| **GPU Partitions** | `gpubase_6hrs` (6h), `gpubase_24hrs` (24h), `gpubase_14days` (14d) |
| **Idle GPU Nodes** | frnt108, frnt109, frnt143-145, frnt147, frnt155-156 |
| **Container Runtime** | `apptainer/1.3.5` (Singularity) |
| **Go** | `Go/19.6` (or install newer Go in `$HOME`) |
| **Python** | `python/3.11.5` |
| **CUDA** | `cuda/11.6.1` |
| **Account** | `sa6079052` on `login.cac.queensu.ca` |

## What This Proves

The benchmark strategy answers the question: **"Does the EPP actually work with real hardware?"**

| What We Measure | How It Proves the EPP Works |
|---|---|
| A100 power at idle vs load | Confirms non-linear power scaling (assumption behind EPP scoring) |
| Energy-per-token at different RPS | Shows decode-phase tokens cost less energy → EPP should route there |
| EPP scorer fed real profiles | Demonstrates correct prefill→high-power, decode→low-power routing |
| Token economics (kWh, gCO₂, $) | Quantifies real savings: **X% less energy, Y% less carbon** |

## Step-by-Step Execution

### Step 1: Setup (Login Node, ~15 minutes)

```bash
ssh sa6079052@login.cac.queensu.ca
cd ~/energy-epp    # or clone your project here

bash benchmarks/scripts/frontenac/01-setup-env.sh
```

This will:
- Load Python 3.11, Apptainer, CUDA modules
- Install Go 1.22 in `$HOME/.local/go/`
- Build the EPP binary (`bin/energy-epp`)
- Pull the vLLM Apptainer image (~10 min)

### Step 2: Profile Single GPU (SLURM Job, ~2 hours)

```bash
sbatch benchmarks/scripts/frontenac/02-profile-gpu.sbatch
```

**Resources requested:** 1 GPU, 8 CPUs, 64GB RAM, 2 hours  
**Partition:** `gpubase_6hrs`

This job:
1. Records idle GPU power (baseline)
2. Starts vLLM in Apptainer with `facebook/opt-1.3b`
3. Polls `nvidia-smi` every 2 seconds for power/temperature
4. Sends inference at 1, 2, 5, 10, 20 RPS
5. Profiles prefill (200 tokens) vs decode (20 tokens) workloads
6. Outputs `gpu_profile_summary.json` + CSVs

### Step 3: Multi-GPU Sweep (SLURM Job, ~4 hours)

```bash
sbatch benchmarks/scripts/frontenac/03-power-sweep.sbatch
```

**Resources requested:** 2 GPUs, 16 CPUs, 128GB RAM, 4 hours

This job:
1. Starts vLLM on GPU 0 (port 8000, prefill role)
2. Starts vLLM on GPU 1 (port 8001, decode role)
3. Sweeps RPS 0.5→20 on each GPU independently
4. Records per-GPU power timeseries
5. Outputs `sweep_gpu0.csv` and `sweep_gpu1.csv`

### Step 4: EPP Scoring with Real Data (Login Node, ~5 minutes)

```bash
bash benchmarks/scripts/frontenac/04-run-epp-scoring.sh \
    benchmarks/results/frontenac/
```

This feeds measured A100 power/throughput into the EPP scorer, proving:
- **Prefill routing:** EPP picks the high-throughput endpoint (GPU at full load)
- **Decode routing:** EPP picks the energy-efficient endpoint (lower power per token)
- **Unit tests pass** with real-world parameter ranges

### Step 5: Generate Thesis Figures (Login Node, ~1 minute)

```bash
python3 benchmarks/scripts/frontenac/05-analyze-frontenac.py \
    benchmarks/results/frontenac/
```

**Outputs in `benchmarks/results/frontenac/figures/`:**

| Figure | Description |
|--------|-------------|
| `power_timeline.png` | A100 power draw during inference workload |
| `ept_vs_load.png` | Energy-per-token at different request rates |
| `token_economics.png` | kWh/gCO₂/$ per 1M tokens comparison |
| `tables.tex` | LaTeX-ready tables for thesis |

## Expected Results

Based on A100 specifications and prior literature:

| Metric | Expected Range |
|--------|---------------|
| A100 Idle Power | 40-60W |
| A100 Load Power | 200-350W (LLM inference) |
| A100 Max TDP | 400W |
| Energy per Token (high load) | 4-8 mJ/token |
| Energy per Token (low load) | 15-40 mJ/token |
| Prefill EPP Score | Highest for GPU_HIGH_PERF |
| Decode EPP Score | Highest for lowest-EPT endpoint |

## Monitoring Your Jobs

```bash
# Check job status
squeue -u $USER

# Watch job output in real-time
tail -f benchmarks/results/frontenac/profile_<JOBID>.out

# Check GPU availability
sinfo -p gpubase_6hrs

# Cancel a job
scancel <JOBID>
```

## File Structure After Benchmarks

```
benchmarks/results/frontenac/
├── 2026-05-22_10-30_profile/      # From Step 2
│   ├── gpu_profile_summary.json   # ← Key output
│   ├── idle_power.csv
│   ├── power_timeseries.csv
│   ├── load_rps_1.json ... load_rps_20.json
│   ├── prefill_profile.json
│   ├── decode_profile.json
│   └── vllm_server.log
├── 2026-05-22_14-00_sweep/        # From Step 3
│   ├── sweep_gpu0.csv             # ← Key output
│   ├── sweep_gpu1.csv
│   ├── power_gpu0.csv
│   └── power_gpu1.csv
├── epp_scoring/                   # From Step 4
│   ├── measured_profiles.json
│   ├── epp_output.txt             # ← Key output
│   └── test_results.txt
├── figures/                       # From Step 5
│   ├── power_timeline.png
│   ├── ept_vs_load.png
│   └── token_economics.png
└── tables.tex                     # LaTeX tables
```

## Troubleshooting

> [!TIP]
> **Job pending with "(Resources)"?** GPU nodes may be busy. Try `gpubase_14days` partition or request fewer GPUs.

> [!WARNING]
> **vLLM OOM on A100 40GB?** Use a smaller model like `facebook/opt-1.3b` (2.6GB) instead of Llama. Edit the `MODEL` variable in the sbatch scripts.

> [!NOTE]
> **No DCGM exporter?** That's fine — we use `nvidia-smi` polling directly, which gives the same power data without needing daemon privileges.
