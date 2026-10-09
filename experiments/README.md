# Experiments

Every measurement in this project was taken on Queen's University's Frontenac
cluster (Slurm, no Kubernetes, no root) under account `hpc6081`, Slurm account
`def-hpcg1971_gpu`. Energy is **GPU-package energy** from NVML's hardware
counter (`nvmlDeviceGetTotalEnergyConsumption`). It excludes CPU, DRAM, fans
and PSU losses, so it is not comparable to an MLPerf Power figure (plan
section 5.1).

## Where things are

| Path | What it holds |
|---|---|
| [`cluster-records/`](cluster-records/) | **Every raw record fetched from the cluster**, one directory per job. This is the evidence; everything else is derived from it |
| [`scripts/`](scripts/) | Everything that ran on the cluster, and everything that analyses the records |
| [`STAGE1-SUMMARY.md`](STAGE1-SUMMARY.md) | Stage 1, 2026-10-03: four energy-versus-load configurations |
| `h1-2026-10-03*/` | The Stage 1 sweeps summarised there, with their own READMEs (see below) |
| [`instruments-2026-10-03/`](instruments-2026-10-03/) | Per-node instrument survey behind the measurement protocol |
| [`stage2-gate-2026-10-03/`](stage2-gate-2026-10-03/) | The first Stage 2 gate. It is **modelled** (queueing over measured curves): a planning decision, not a finding |

The Stage 1 directories, all Qwen2.5 on vLLM 0.30.0, 75 s per level:

| Directory | Job | Node, GPU | Model | Levels, trials |
|---|---|---|---|---|
| `h1-2026-10-03` | 12302438 | frnt152, Quadro RTX 6000 | 1.5B | 1-32, 2 trials (first sweep) |
| `h1-2026-10-03-frnt109` | 12303088 | frnt109, Quadro RTX 6000 | 1.5B | 1-32, 5 trials |
| `h1-2026-10-03-frnt109-7b` | 12303308 | frnt109, Quadro RTX 6000 | 7B | 1-32, 5 trials |
| `h1-2026-10-03-frnt140-a30` | 12303200 | frnt140, A30 | 1.5B | 1-32, 5 trials |
| `h1-2026-10-03-frnt201-l4` | 12303303 | frnt201, L4 | 1.5B | 1-32, 5 trials |

Later curves, including those the Stage 2 policies used and the final curves
for Stage 5, are under `cluster-records/results/h1-<job>/`.
`make_figures.py` and plan sections 12.14c and 12.14d say which is which.

## Scripts, by purpose

| Purpose | Scripts |
|---|---|
| Stage 1 curves | Closed loop (fixed concurrency): `h1_sweep.sbatch`, `h1_sweep.py`, `h1_fit.py`, `energy_exporter.py`, submitted by `curves256_submit.sh` and `curves6_submit.sh`. **Open loop** (Poisson arrivals, used from approach A on): `openloop_curve.sbatch`, `openloop_build.py`, `select_openloop_curves.py`, submitted by `olc_submit.sh` |
| Stage 2 policy runs | `policy_harness.py` (load generator plus routing rules, `--headroom`), `stage2_het.sbatch` (mixed fleet), `stage2_real.sbatch` (one GPU type), `het_submit.sh`, `real_submit.sh`, `calib_submit.sh` |
| Router path | `router_smoke.sbatch`, `router_overhead.sbatch`, `smoke_test.sbatch` |
| Analysis | `stage2_analyse.py` (the gate), `prereg_analysis.py` (the frozen Stage 5 analysis), `power_analysis.py`, `headroom_calibrate.py`, `make_figures.py`, `compare_runs.py` (descriptive only) |
| Integrity | `verify_fixes.sh` (run on the cluster before any submission), `prepare_records.sh` (compresses fetched logs) |

The Makefile at the repository root wraps the analysis: `make gate`,
`make prereg-pilot`, `make power`, `make figures-check`.

## Software, pinned

| Piece | Version |
|---|---|
| vLLM | 0.30.0, torch 2.13.0+cu130, Apptainer image `vllm-v0.30.0.sif` |
| llm-d-router (EPP) | v0.11.0, commit `a5cbe600`, built by `router-plugin/build.sh` |
| Envoy | 1.39.2, Apptainer image |
| Go | 1.26.6 (the router's minimum) |

The 2026-10-03 smoke test (`smoke_test.sbatch`) used an EPP built from the
cluster checkout `297bfb0`. The v0.11.0 build is named in the logs of router
smoke test 12321494 and the router-overhead job 12321497. (12321493 left an
empty directory; 12321496's EPP log carries no version string.) No Stage 2
result uses the EPP at all, because the routing rules ran inside the load
generator.

## Cluster-specific fixes the batch scripts carry

- Lmod is absent in batch shells.
- `set -u` breaks the cluster profile.
- `pynvml` is reached through a probe that reads the counter, not one that
  only imports the module.
- Host `SSL_CERT_FILE` breaks TLS inside containers.
- Model weights are staged to node-local disk, so a shared-filesystem stall
  cannot wedge a server.
- Heterogeneous jobs are never used as `afterok` dependencies.

Each is recorded with its evidence in the plan (sections 3.4 and 12.15).
`verify_fixes.sh` checks them in the cluster copies of the scripts; it reported
53 passes and 0 failures on 2026-10-09.
