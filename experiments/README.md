# Experiments

Measurements run on Queen's Frontenac (CAC) under account `hpc6081`,
Slurm account `def-hpcg1971_gpu`. Working tree on the cluster:
`~/energy-epp/` (binaries and container images are not in this repo).

## Stack

| Piece | Version / note |
|---|---|
| EPP | built from `llm-d/llm-d-router` `297bfb0`, Go 1.27.1 |
| Envoy | 1.39.2 (Apptainer SIF) |
| vLLM | 0.30.0, torch 2.13.0+cu130 (Apptainer SIF) |
| Energy | NVML `nvmlDeviceGetTotalEnergyConsumption` (hardware counter) |
| Tokens | vLLM Prometheus counters (`vllm:generation_tokens_total`) |

## scripts/

- `energy_exporter.py` - per-GPU JSONL power/energy sampler.
- `h1_sweep.py` - H1 driver: closed-loop load per level, energy counter deltas,
  engine token counters, shared-prefix variant.
- `h1_fit.py` - fits the power model, reports R^2, residuals, activation cost
  and the J/token curve.
- `smoke_test.sbatch` - full path: 2 vLLM + EPP (file discovery) + Envoy, with
  traffic driven through Envoy.
- `h1_sweep.sbatch` - the H1 campaign.

Both sbatch scripts carry fixes for five Frontenac-specific issues: batch
shells have no Lmod, `set -u` breaks the CC profile, the cluster python
(not `/usr/bin/python3`) has `pynvml`, host `SSL_CERT_FILE` points into CVMFS
and breaks TLS inside containers, and the EPP serves gRPC over TLS while
upstream's Envoy config expects plaintext (`--secure-serving=false`).

## h1-2026-10-03/

Job `12302438` on `frnt152` (Quadro RTX 6000, 250 W limit, driver 610.43.02).
Qwen2.5-1.5B-Instruct, 6 load levels x 75 s x 2 trials, plus a shared-prefix
variant at concurrency 8.

Headline: active power is nearly constant (202 +/- 8 W) across a 32x load
range, so the linear `P_idle + k_b*b` model fails (R^2 = 0.37), while
`J/token = P_active / throughput` holds to 0.0% error. Activation (idle to
active) costs +135 W against +0.46 W per additional concurrent request.
J/token improves 21x from concurrency 1 to 32.

See section 11 of `docs/plan/technical-plan-v2-2026-09.md` for the analysis
and what it changes in the plan.
