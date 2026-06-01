# Frontenac 2.0 Benchmark Plan
## Energy-Aware EPP on Queen's CAC HPC (SLURM, No K8s)

## The Problem

Frontenac is a **SLURM-managed HPC cluster** — you have:
- ✅ DGX A100 nodes (8×A100 40GB each)
- ✅ GPU partitions (gpubase_6hrs, gpubase_24hrs, gpubase_14days)
- ✅ Apptainer (Singularity) for containers
- ✅ Go 1.21, Python 3.11, CUDA 11.6
- ❌ No root/sudo (can't install k3s/k8s)
- ❌ No Kubernetes
- ❌ No `nvidia-smi -pl` (power capping usually requires sudo)
- ❌ No DCGM exporter (no daemon privileges)

## The Strategy: "Simulation-Validated, Hardware-Profiled"

Instead of running the full K8s stack, we run a **two-phase benchmark**:

### Phase 1: Hardware Power Profiling (SLURM jobs)
Run vLLM at different loads on A100s, measure **real power/latency/throughput**
via `nvidia-smi` polling. This gives us ground-truth hardware profiles.

### Phase 2: EPP Scoring Validation (uses Phase 1 data)
Feed the real measured profiles into the EPP scorer and demonstrate
that it **correctly routes prefill→high-power, decode→low-power**.

This proves: "Given real A100 telemetry, the EPP makes correct decisions."

## Available Resources

| Resource | Details |
|----------|---------|
| GPU Nodes | 2× DGX A100 (8×A100 40GB each) |
| Partitions | `gpubase_6hrs`, `gpubase_24hrs`, `gpubase_14days` |
| Idle GPU nodes | frnt108, frnt109, frnt143-145, frnt147, frnt155-156 |
| Containers | `apptainer/1.3.5` |
| Go | `Go/19.6` |
| Python | `python/3.11.5` |
| CUDA | `cuda/11.6.1` |
| Account | sa6079052 |

## Files in This Directory

| File | Purpose |
|------|---------|
| `01-setup-env.sh` | One-time environment setup on Frontenac |
| `02-profile-gpu.sbatch` | SLURM job: run vLLM and collect power/latency data |
| `03-power-sweep.sbatch` | SLURM job: measure A100 at different utilization levels |
| `04-run-epp-scoring.sh` | Feed real profiles into EPP scorer |
| `05-analyze-frontenac.py` | Generate thesis-quality results from collected data |
