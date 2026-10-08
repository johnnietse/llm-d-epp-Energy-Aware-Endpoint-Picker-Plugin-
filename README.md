# Energy-Aware Routing for Heterogeneous LLM Inference

A measured study, and an out-of-tree plugin for the
[llm-d router](https://github.com/llm-d/llm-d-router), asking one question:
**can an inference router save energy by choosing which GPU serves each
request, without slowing requests past their latency target, when the tenant
has no privileged control over the hardware?**

> **Status, 2026-10-08: research in progress.** Every number on this page was
> measured on real GPUs, and each one is traced to a job id and a committed
> raw record. The figures this README used to show came from a 1,000-cycle
> simulation and are **withdrawn**; see [What was withdrawn](#what-was-withdrawn).
> The authoritative record is [`docs/plan/FINAL-PLAN-2026-10.md`](docs/plan/FINAL-PLAN-2026-10.md).

The thesis report is
[here](Johnnie_Yan_Ho_Tse_Energy_Aware_Token_Level_Routing_for_Heterogeneous_LLM_Inference_in_Kubernetes_Research_Paper.pdf).
It was written before the measurements below, so check any figure in it
against the plan before quoting it.

## What has been measured

Testbed: Queen's University **Frontenac** HPC cluster (Slurm, no Kubernetes, no
root access). GPUs: NVIDIA A100-PCIE-40GB and Quadro RTX 6000. Model:
Qwen2.5-1.5B-Instruct. Server: vLLM 0.30.0, the official container. Energy:
NVML's hardware energy counter, read per GPU, per node. Requests: open-loop
arrivals at fixed rates, with a 2.0 s end-to-end latency target (the SLO).

The metric is **SLO-goodput per joule**: requests that met the latency
target, per joule of GPU energy. Each policy is compared at its own best load
level among those where at least 95% of requests meet the target, so a
policy cannot win by saving energy on requests that missed it.

### 1. On a mixed fleet, energy-aware placement wins narrowly but consistently

4x A100 + 4x RTX 6000, three trials at seeds 7, 11 and 13 (jobs 12305232,
12319685, 12321476). All 75 measurement cells are valid.

| Policy | SLO-goodput per joule | vs `slo_packing` | Per trial |
|---|---|---|---|
| `energy_consolidate` | 0.3574 | **+1.4%** | +2.0%, +1.2%, +1.0% |
| `energy_greedy` | 0.3559 | +0.9% | +1.6%, +0.8%, +0.5% |
| `slo_packing` (baseline) | 0.3526 | | |
| `least_loaded` | 0.2323 | -34.1% | |
| `round_robin` | 0.1096 | -68.9% | |

The pre-registered gate passes: `energy_consolidate` beats the baseline in
every trial. The margin is small. Three positive trials out of three is weak
evidence on its own (a coin would do it one time in eight), so the trial
count for the comparative study is set by a power analysis before any further
claim is made.

### 2. On a same-size, single-type fleet, the ranking reverses

8x RTX 6000, with load levels inside that fleet's capacity (job 12321478).
`round_robin` is best, at 0.1682 SLO-goodput per joule. **Every policy that
uses the energy curves has no feasible point at all**: concentrating load to
save energy pushes latency past the target before any saving is collected.

The fleet's composition decides whether energy-aware routing helps. The
control matches the mixed fleet on GPU count (8) and on model storage
(node-local disk), so neither explains the reversal.

### 3. The router path costs about one millisecond

Job 12321497, using vLLM's own benchmark client. Measured, not estimated:

| Cost | Measured |
|---|---|
| Router path (Envoy, then the EPP), median time to first token | +1.2 to +2.4 ms |
| Router path, median end-to-end | +0.06% to +0.28% |
| The EPP's routing decision | about 0.2 ms |
| The EPP polling each vLLM's metrics every 50 ms, median time to first token | under +1 ms |

There is no Prometheus server in this system. The EPP reads each vLLM
server's metrics page directly, off the request path, and that can be turned
off entirely.

### 4. The load generator is accurate per token

A Python generator's inter-token timings agree with vLLM's own histogram to
within **0.6%**, across all 25 cells of job 12319685. The two come from
independent sources.

## The llm-d router runs here without Kubernetes

llm-d is Kubernetes-native, but its endpoint picker (EPP) has a documented
**file-discovery mode** that needs no Kubernetes: a static list of vLLM
servers, Envoy in front, and the EPP between them. Smoke tests 12321494 and
12321496 routed **40 of 40** requests through Envoy, then the EPP with our
plugin, then two vLLM servers, on a Slurm node. Which features need
Kubernetes, and why the scorer does not, is set out in plan section 12.14a.

Everything is pinned to one release: **llm-d-router v0.11.0** (commit
`a5cbe600`), **Envoy 1.39.2**, **vLLM 0.30.0**. The EPP binary is built
reproducibly by [`router-plugin/build.sh`](router-plugin/build.sh).

## What is not done yet

- **The energy-aware scorer is not in the router yet.** `router-plugin/`
  currently ships an inert probe that proves the wiring. All results above
  come from routing rules written in the Python load generator, so they show
  that the **rule** works, not yet that an llm-d plugin delivers it. Porting
  the winning rule to Go is Stage 4. It will use the EPP's own count of
  in-flight requests, which needs no metrics polling.
- **Pre-registration (Stage 3)** comes first. It fixes the hypotheses, the
  metric and the trial count before the comparative study (Stage 5).
- `energy_consolidate` against `energy_greedy` (+0.4 to +0.5 points per
  trial) is not a resolved difference.

## How this relates to prior work

Placing requests on more energy-efficient hardware is **not a new idea**.
Wilkins, Keshav and Mortier proposed it in 2024 (arXiv 2407.00010 and
2407.04014, HotCarbon 2024), evaluated on a workload trace with offline energy
models. What this project adds is narrower: a **measured, online** test inside
a production router's plugin API, at a fixed latency target, by an
**unprivileged** tenant, with a same-size homogeneous control that shows the
effect reversing. The full positioning is in plan section 12.2.

## Repository layout

| Path | What it is |
|---|---|
| [`docs/plan/FINAL-PLAN-2026-10.md`](docs/plan/FINAL-PLAN-2026-10.md) | The authoritative plan, results, threats to validity and defect log |
| [`experiments/scripts/`](experiments/scripts/) | Measurement harness, Slurm jobs, the Stage 2 gate (`stage2_analyse.py`), the verification suite (`verify_fixes.sh`) |
| [`experiments/cluster-records/`](experiments/cluster-records/) | Every raw record fetched from the cluster, logs gzipped |
| [`router-plugin/`](router-plugin/) | Out-of-tree llm-d-router plugin module and the EPP entry point |
| [`llm-d-ref/`](llm-d-ref/) | Git submodule of the official llm-d-router, pinned to v0.11.0 |
| [`tools/cluster-helpers/`](tools/cluster-helpers/) | Local scripts that connect to the cluster, submit, wait and fetch |
| `pkg/`, `cmd/energy-epp/` | Pre-measurement code. Builds and tests pass, but its scorer uses a GPU power-rating (TDP) proxy that the measurements refuted, and it does not plug into llm-d-router. Being rewritten in Stage 4 |
| [`legacy/`](legacy/) | Quarantined components kept for history: the simulation, eBPF tracker, Slurm SPANK adapter, KubeRay policy, thermal filter, SCI calculator, KV-transfer and RDMA scorers, and the old upstream port |

See [`QUICKSTART.md`](QUICKSTART.md) to rerun the analysis from the committed
records, build the EPP, or reproduce a measurement.

## What was withdrawn

Until 2026-10-08 this README presented results from a 1,000-cycle simulation
as findings: prefill and decode "win rates" between an H100 and a Qualcomm
Cloud AI 100, per-token energy, carbon and cost ratios, ISO SCI scores, and an
adaptive weight controller's modes. **None of that hardware was measured.** The
energy and power figures were modelled, not read from instruments. The
project's rule since 2026-10-03 is that simulated numbers are never presented
as results.

The simulation and the components built around it are in [`legacy/`](legacy/).
The old README remains in git history: `git show 3543e10:README.md`.

## License

Apache License 2.0; see [LICENSE](LICENSE). Part of ongoing thesis research.
