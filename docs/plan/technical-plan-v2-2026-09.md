# Technical Plan: Marginal-Energy Routing for llm-d

Status: proposal (v2, consolidated 2026-09-18). Supersedes
`technical-plan-2026-09.md`. Upstream reference: `llm-d/llm-d-router` at
`e149f34f`.

**Summary.** Build an energy-aware endpoint scorer for the llm-d router as an
out-of-tree plugin module, drive it with GPU energy counters, and evaluate it
on real A100s under Slurm (Frontenac) using upstream's no-Kubernetes mode.
The scorer estimates the marginal energy a request adds to each endpoint,
including prefix-cache hits, and picks the cheapest endpoint that stays
within SLO. The first target is a 5-page workshop paper (HotCarbon); a
month-2 go/no-go gate decides between a routing paper and a measurement
paper. Appendix A lists what changed from v1; Appendix B keeps the research
inputs behind the decisions.

---

## 1. Research question, hypotheses, scope

**RQ.** Can a production LLM router reduce energy per served token, at equal
SLO attainment, by routing each request on a live marginal-energy estimate
instead of load or cache signals alone?

- **H1 (model).** Per-endpoint power is predictable online as
  `P(b, t) ~ P_idle + k_b*b + k_t*t` (b = running requests, t = tokens in
  flight), fitted per `(GPU, model, precision, TP)` configuration, with R^2
  above an agreed threshold. Prefill energy per uncached prompt token is
  measured separately.
- **H2 (fixed fleet).** Marginal-energy scoring under an SLO constraint
  lowers J/token against default llm-d routing **and against SLO-aware
  packing**, with p99 TTFT/TPOT within SLO.
- **H3 (scaled fleet).** Marginal-energy routing lets fewer replicas stay
  active at equal SLO attainment. Reported as GPU-hours released and as
  energy computed from measured idle power in three states (loaded idle,
  vLLM sleep mode, no process), because on a shared HPC cluster a released
  GPU stays powered on.
- **H4 (optional, cloud).** On a mixed-GPU pool the same scorer shifts decode
  load toward the more efficient GPU type without SLO loss.

Each hypothesis maps to one figure. If H1 fails, the paper becomes a
measurement paper on why online energy models for routing are unreliable.

**Go/no-go gate (end of month 2).** Replay the workload traces offline
against the measured H1 curves and compute energy for spread (round robin),
SLO-aware packing, and an offline oracle. If oracle savings over packing are
below about 5% J/token, stop building the online model and write the
measurement paper.

**Scope tiers.**

| Tier | Contents |
|---|---|
| Workshop (HotCarbon, 5 pages) | H1; H2 on BF16 replicas with the GPU-tier prefix-cache term; static SLO caps; packing and oracle baselines; H3 on Slurm. |
| Full paper (later) | Learned SLO constraint via the latency predictor; mixed precision / mixed TP pools; intra-node P/D; CPU-RAM KV tier; H100 curves; cloud mixed-GPU run (H4). |

## 2. Engineering design

### 2.1 Packaging: out-of-tree module, not a fork
A separate Go module holds the plugins and a custom `main.go` that calls
`fwkplugin.Register(...)` for each plugin and then
`runner.NewRunner().Run(ctx)`, the pattern upstream documents in
`docs/discovery.md` and `cmd/epp/main.go`. Upstream is a pinned `go.mod`
dependency, so upgrading is a version bump, not a rebase. Upstream PRs copy
the plugin packages into the tree later.

### 2.2 Components

1. **Energy extractor** (data layer). Publishes vendor-neutral attributes
   (`AcceleratorPowerWatts`, `AcceleratorEnergyJoules`, temperature,
   enforced power limit). Sources: `dcgm-data-source` on Kubernetes; on
   Slurm, a small exporter built on `nvidia-ml-py` that emits the same DCGM
   metric names. AMD (amd-smi) or Kepler documented as later sources.
2. **Online energy model.** Recursive least squares fit of `P(b, t)` per
   endpoint from energy-counter deltas, `num_requests_running`, and upstream
   `InFlightLoad` tokens. One fit per `(GPU, model, precision, TP)`, never
   transferred across GPU types (kernel selection changes with shape and
   card). Cold-start priors from Watt Counts / ML.ENERGY / WattGPU. The
   functional form follows a per-GPU roofline sketch (prefill compute-bound,
   decode memory-bound).
3. **`energy-scorer`.** Score is `1 - normalized(marginal energy)`. Marginal
   energy comes from the fitted model for the request's work on each
   endpoint. Prefill work counts **uncached prompt tokens only**, from
   upstream `PrefixCacheMatchInfo` (`CachedBlockCount`, `BlockSizeTokens`).
   Full-paper tier adds a measured load cost for blocks in the CPU-RAM tier
   (`CachedBlocksByTier`, available with the precise prefix-cache producer and
   a KV offloading connector). Combined with prefix-cache and load scorers via
   profile weights; phase asymmetry is profile configuration.
4. **SLO constraint.**
   - Workshop tier: static per-configuration admission caps (maximum running
     requests or tokens in flight that keep p99 TTFT/TPOT within SLO),
     calibrated from H1 latency curves and enforced with upstream
     `endpoint-attribute-filter`. The packing baseline uses the same caps, so
     the comparison isolates the energy model.
   - Full-paper tier: upstream `predicted-latency-producer` +
     `slo-headroom-tier-filter`. This needs the `llm-d-latency-predictor`
     prediction and training services (Python/FastAPI, early-stage docs) and
     SLO request headers from the load generator.
5. **Scaling (H3).** On Slurm, a small scaler script removes an idle replica
   from the `file-discovery` endpoints file (EPP reloads it with
   `watchFile: true`) and puts that vLLM into sleep mode
   (`--enable-sleep-mode`, level 1: weights to CPU, KV cache dropped, fast
   wake); it reverses both on rising load. On Kubernetes the same policy maps
   to a KEDA ScaledObject (upstream autoscaling is KEDA-based; the WVA
   controller is deprecated).
6. **Measurement boundary and accuracy.** Primary metric: GPU energy from
   NVML counters. Secondary check: node-level readings (IPMI/RAPL) where
   accessible. NIC energy for cross-node KV transfer is outside the boundary
   and stated as a limitation. On A100/H100 the on-board sensor samples about
   25% of the time (Yang et al., SC24), so ground-truth runs follow their
   practices: steady-state runs of minutes, warm-up and rise time discarded,
   at least 4 trials with randomized start offsets, error bars reported. The
   routing signal uses the fitted model, never a single sub-second reading.
7. **Out of scope.** Carbon inside one cluster (all endpoints share one
   grid), eBPF, Slurm SPANK, Ray, custom GPU kernels (vLLM, NIXL and vendor
   libraries used unmodified), cross-node P/D until CAC confirms InfiniBand
   between DGX nodes, cross-vendor P/D.

## 3. Viability check

| Component | Viable? | Evidence | Risk and mitigation |
|---|---|---|---|
| EPP on Slurm | Yes | Upstream `docs/discovery.md`, "Running EPP with file discovery (no Kubernetes)". | `InferenceObjective` is inactive in file mode; workshop tier does not need it. |
| Custom EPP binary | Yes | `cmd/epp/main.go` is a thin wrapper over `runner.NewRunner()`; plugins register via `fwkplugin.Register`. | Upstream API churn: pin a commit, bump deliberately. |
| vLLM on Frontenac | Yes | Repo scripts ran vLLM on `gpubase_*` with A100 40GB via Apptainer. | 40GB limits model size: 8B at TP1, 14B at TP2. |
| Energy telemetry without root | Likely | NVML energy counter reads do not need root; Zeus uses them on Volta and newer. | `dcgm-exporter` may need privileges; own NVML exporter is the default on Slurm. |
| Measurement accuracy | Yes, with method | ~25% sensor sampling on A100/H100; SC24 practices bring error to ~5%. | Long steady-state runs, repeated trials, Zeus cross-check. |
| SLO constraint | Yes (workshop tier) | `endpoint-attribute-filter` thresholds on metrics the EPP already has. | Learned predictor deferred: extra services, early-stage docs. |
| H3 savings on shared HPC | Partial | Released GPUs stay powered. | Report GPU-hours released plus energy from measured idle states. |
| Effect size | Unknown until month 2 | Batch-size effect is large (3-5x J/token); savings over packing unmeasured. | Go/no-go gate. |
| P/D on one DGX node | Likely | NixlConnector supports intra-node transfer. | Full-paper tier only. |
| Power capping as heterogeneity | Unlikely on Frontenac | `nvidia-smi -pl` needs root. | Configuration heterogeneity (TP degree, BF16 vs AWQ-INT4; A100 has no FP8) or cloud. |
| Mixed-GPU pool | Yes, costs money | GKE supports multiple GPU node pools. | Optional; budget cap, short scripted runs. |
| Upstream acceptance | Uncertain | No energy scorer upstream; `AGENTS.md` requires an issue first and minimal PRs. | Extractor PR first (useful for observability alone); paper does not depend on the merge. |

## 4. Experiments

**Experiment 0 (gate for everything else).**
(a) Routing correctness: logs show the router picks the endpoint the scorer
ranks highest.
(b) Energy closure: exporter counter deltas match an independent Zeus
measurement window within a stated tolerance.

**H1 measurements.** Power and latency vs running requests and tokens in
flight; J/token vs prefix-hit ratio; idle power in three states. Pin each
vLLM process to the NUMA node local to its GPU and record it.

**Workloads.** Azure LLM inference traces (2023/2024) for arrivals;
ShareGPT / LMSYS-style prompt lengths; a long-context (summarization) mix, a
short (chat) mix, and a prefix-sharing mix (multi-turn chat, shared system
prompts) so the cache term is exercised.

**Models.** Llama-3.1-8B-Instruct (BF16, TP1); Qwen2.5-14B-Instruct (BF16,
TP2); full-paper tier adds an AWQ-INT4 variant. Check Hugging Face license
terms before use.

**Pools on one DGX node.** Workshop tier: homogeneous BF16 replicas.
Full-paper tier: mixed TP1/TP2, mixed BF16/AWQ-INT4, intra-node P/D.

**Baselines.**
1. Default llm-d config (prefix-cache + load/kv-utilization scorers).
2. `endpoint-attribute-scorer` on GPU utilization (upstream #1904).
3. Round robin.
4. SLO-aware packing: busiest endpoint still under the SLO cap, no energy
   model. The strongest simple baseline; results are stated against it.
5. Offline oracle: upper bound from trace replay on measured curves.

**Ablations.** Energy scorer without the SLO constraint; with static J/token
instead of the online model; without the prefix-cache term.

**Metrics.** J/token (GPU energy counters; node level where accessible);
TTFT/TPOT p50/p99; SLO attainment; goodput; active replica-hours and
GPU-hours released (H3); scoring overhead per request. At least 5 runs per
configuration; mean and 95% CI; warm-up excluded.

**Figures (one per claim).** P(b, t) fit with residuals (H1); J/token vs load
per policy (H2); SLO attainment vs load (H2); J/token with and without the
cache term on the prefix-sharing mix (H2); replica count and energy over time
under scaling (H3); scoring overhead; full-paper tier adds mixed-pool and
mixed-GPU figures.

## 5. What you need

### 5.1 Software (critical path first)

| Item | Choice and reason | Where |
|---|---|---|
| Router | Out-of-tree Go module importing `github.com/llm-d/llm-d-router` at a pinned commit; custom EPP `main.go`. Go 1.26.6 per upstream `go.mod` (local 1.26.0 auto-downloads the toolchain). Plain `go build` on Linux. | WSL2, Frontenac login node |
| Proxy | Envoy >= 1.31, static config from upstream `docs/discovery.md` | Frontenac (Apptainer) |
| Engine | vLLM, one pinned release (V1 engine, prefix caching on, `--enable-sleep-mode` for H3); container image pinned by digest | Frontenac (Apptainer) |
| Energy exporter | ~100-line Python service: `nvidia-ml-py` (official NVIDIA bindings; `pynvml` is deprecated) + `prometheus_client`, emitting DCGM metric names and writing raw timestamped samples to Parquet | GPU node |
| Ground-truth check | Zeus (`zeus-ml`) measurement windows, Experiment 0 | GPU node |
| Load generator | `inference-perf` (kubernetes-sigs; engine-agnostic, standalone, trace replay); `vllm bench serve` for quick checks | client process |
| Orchestration | One config-driven runner per experiment (YAML in, run directory out) recording git SHAs, image digests, `nvidia-smi -q`, flags, seeds | Slurm batch jobs |
| Trace simulator | Small Python discrete-event replay over measured curves (go/no-go gate, oracle) | dev machine |
| Analysis | Python 3.11+, pandas or polars, statsmodels (fits with confidence intervals), matplotlib | dev machine |
| Profiling | Nsight Systems (GPU timelines, idle gaps); `numactl` / `hwloc` (CPU-GPU affinity) | Frontenac |
| Writing | Venue LaTeX template on Overleaf; Zotero + Better BibTeX | dev machine |
| Optional: learned SLO | `llm-d-latency-predictor` prediction + training services | Frontenac |
| Optional: Kubernetes path | kind, kubectl, helm, `llm-d-inference-sim` (functional plugin tests), KEDA, `dcgm-exporter`, Prometheus + Grafana (demos), `llm-d-benchmark` | dev machine, cloud |
| Optional: upstream PR checks | `make presubmit` runs in a builder container: Docker Engine or Podman on WSL2 (Docker Desktop on this machine has a known startup fault) | WSL2 |

### 5.2 Hardware

| Tier | What | Cost | Needed for |
|---|---|---|---|
| Dev machine | Laptop with at least 100 GB free disk (about 3.6 GB free on C: as of 2026-09-17), 16 GB+ RAM, WSL2 | free; clear disk first | building, simulator, analysis |
| Frontenac | 1 DGX A100 node (8x A100 40GB) via `gpubase_*`, Apptainer | free (allocation) | H1-H3 |
| DRAC (optional) | H100 80GB on Fir / Nibi / Rorqual / Trillium through a supervisor's allocation | free with sponsor | second GPU generation for H1 |
| Cloud (optional) | GKE with two GPU node pools (for example A100 + L4) | estimate a few hundred USD; set a billing cap | H4, Kubernetes demo |

### 5.3 People and process

- Supervisor sign-off on the RQ, scope tier, and venue.
- CAC ticket: maximum job length; InfiniBand between DGX nodes; NVML energy
  counters readable by users; container runtime policy; long-running
  services inside jobs.
- Hugging Face account with accepted model licenses; request access to
  `ml-energy/benchmark-v3` (gated).
- Check whether Queen's has a student cluster-competition team or HPC club
  (second compute source).

## 6. Paper plan

**Working title.** "Routing by the Joule: Marginal-Energy Endpoint Selection
for LLM Serving".

**Contributions (only claims the experiments test).**
1. Measurement: load-, cache- and configuration-dependent power and J/token
   for vLLM on A100 (H100 if available) with counter-based measurement and
   stated accuracy.
2. Design: an online, cache-aware marginal-energy model and an
   SLO-constrained scorer in llm-d's plugin framework, with vendor-neutral
   telemetry.
3. Evaluation: J/token and SLO attainment on real hardware against llm-d's
   default routing and SLO-aware packing, with ablations and a scaled-fleet
   study.
4. Artifact: plugin module, configs, scripts, raw data (Zenodo DOI).

**Structure.** Introduction -> Background and motivation (measured evidence
that J/token varies with load and cache hits) -> Design -> Implementation ->
Evaluation (one subsection per hypothesis) -> Discussion and limitations ->
Related work -> Conclusion.

**Venues (check each CFP before committing).**

| Venue | Type | Known date | Fit |
|---|---|---|---|
| HotCarbon '27 | 5-page workshop, double blind | 2026 edition deadline was May 18 | First target |
| MLSys 2027 | Full paper | Deadline 2026-10-30 | Too soon |
| EuroSys 2027 | Full paper | Fall deadline 2026-09-24 | Too soon; later cycles are a reach |
| SIGOPS ATC | Full paper | USENIX ended ATC in 2025; ACM SIGOPS continues it | Full-paper target after workshop feedback |
| SoCC, e-Energy, Middleware, IEEE CLOUD | Full paper | Not verified | Alternatives |

### 6.1 Writing practices

- Levin and Redell (SOSP-9 PC chairs): answer their questions per section;
  say at the start that the system is real and implemented.
- Peyton Jones: write first; one key idea; tell a story; contributions as
  refutable claims; related work at the end; get outside readers.
- Chen Haibo (CCCF 2011): question why this approach and not an existing one;
  a working prototype is required; strict logic from paper to sentence;
  do not start three months before a deadline.
- Zhihu systems-writing advice: one line from motivation to challenges to
  method to results.
- Write hypotheses, metrics and analysis in the repo before running H2/H3
  (lightweight pre-registration).
- Draft the introduction and motivation figure in month 2 from H1 data; the
  draft shows which experiments are missing.
- Report effect sizes against SLO-aware packing, including where the scorer
  loses.
- Include an "instruments" table (GPU, driver, CUDA, vLLM, Envoy, EPP commit,
  model, precision, CPU, NUMA layout, network).
- Fits report R^2 and residuals; explanations cite profiler evidence
  (batch size over time, Nsight timelines), not speculation.
- Keep a running threats-to-validity list; it becomes the limitations
  section.

## 7. Timeline (about 8 months to a workshop submission)

| Month | Milestone |
|---|---|
| 1 | Disk cleanup, WSL2 toolchain; CAC ticket; week-1 smoke test on one Frontenac node: stock EPP (file discovery) + Envoy + 2 vLLM + NVML read. GPU MODE / vLLM ramp-up starts. |
| 2 | Energy exporter; Experiment 0; H1 curves (load, prefix-hit ratio, idle states); SLO caps calibrated; trace simulator; **go/no-go gate**; upstream issue opened; introduction and motivation figure drafted. |
| 3 | Out-of-tree module: extractor, online model, cache-aware scorer, packing baseline; unit tests; extractor PR upstream. |
| 4 | H2 on Frontenac with all workloads; ablations; address PR review. |
| 5 | Slurm scaler + sleep mode; H3. |
| 6 | Full-paper-tier items as time allows; scorer PR or out-of-tree release. |
| 7 | Complete draft; outside readers; figures; artifact packaged. |
| 8 | Submission (HotCarbon '27 or the nearest suitable workshop). |

## 8. Risks

- H1 fails (poor fit): per-endpoint lookup tables from profiling runs, or
  publish the measurement result.
- Gate fails (savings over packing below ~5%): measurement paper.
- Frontenac forbids long-running services or container networking inside
  jobs: move real-hardware runs to DRAC or cloud.
- Upstream rejects the scorer: keep the out-of-tree module; the paper does
  not depend on the merge.
- Prior work with the same idea appears: search arXiv and llm-d issues
  monthly; the differentiators are real-system integration, the cache-aware
  model, and the packing baseline.

---

## Appendix A. Changes from v1

| v1 assumption | Finding | Effect |
|---|---|---|
| Frontenac cannot run the router (no Kubernetes). | Upstream `file-discovery` runs the EPP with no Kubernetes, CRDs or RBAC ("bare metal inference clusters, Slurm jobs, or local development"). | Real-hardware experiments run on Frontenac under Slurm. |
| Heterogeneity means different GPU models. | Only homogeneous A100s are available in one place, but J/token varies 3-5x with load, and with parallelism, precision and cache hits. | Main axis is load- and cache-dependent efficiency; hardware heterogeneity is optional. |
| Instantaneous DCGM power is a good signal. | A100/H100 sensors sample ~25% of the time; energy readings inherit this unless runs are designed for it (SC24). | Energy counters plus measurement practices; routing uses a fitted model. |
| Packing saves energy by itself. | Idle GPUs still draw static power; on shared HPC released GPUs stay on. | Fixed-fleet and scaled-fleet studies; GPU-hours released reported. |
| Cross-vendor P/D (NVIDIA to ASIC) is a target. | Needs custom KV-format handling (HMA-Serve); production heterogeneous P/D stays within one vendor. | NVIDIA only. |
| Fork llm-d-router. | Upstream supports registering plugins in a custom `main.go`. | Out-of-tree module. |
| SLO filtering is free. | `slo-headroom-tier-filter` needs the latency predictor services. | Static calibrated caps for the workshop tier. |

## Appendix B. Research inputs

### B.1 Zhihu question 657927103 ("本科生能做并行计算hpc吗？")

**Linked answer** (Haibin Lai, SUSTech CS205 report "Matrix Multiplication:
Java vs C"; code at github.com/HaibinLai/CS205-CPP-Programing-Project). Full
text read; 94 figures saved to `research/zhihu-657927103/images/`
(git-ignored, author's copyright). Four experiments: correctness check first
(found a float-precision difference); compiler optimization explained at
assembly level; scaling on two machines with log-log plots and `N^3` fits
(R^2 > 0.999), communication overhead and NUMA jumps; bottleneck analysis with
Intel VTune Top-Down. Weak points: the GPU part was dropped after a CUDA
driver failed to install, timers differed per language, several conclusions
were speculation.
Adopted: Experiment 0; one measurement source for every baseline;
instruments table; fits with goodness-of-fit; profiler-backed explanations;
NUMA pinning; week-1 smoke test; threats-to-validity list.

**Answer by an HPC-to-AI-Infra engineer (794 upvotes).** Supercomputing
teams and competitions (ASC, SC IndySCC, PAC, CPC); AI Infra roles expect an
internship or an open-source project backed by real GPU compute; learn LLM
and CUDA basics (Andrew Ng, CS231n / CS224n, CUDA MODE now GPU MODE,
Karpathy's repositories); follow MLSys authors discussing Mooncake.
Adopted: upstream PR as a primary deliverable; GPU MODE / vLLM ramp-up;
checking for a Queen's cluster team.

**Answer by an AMD engineer (240 upvotes).** Kernel libraries (CUTLASS,
cuBLAS, TensorRT) are maintained by large teams; custom kernels are unstable
across shapes and cards; AMD ports CUDA to ROCm with scripts; new AI chips
rely on compilers such as TVM; kernel work is saturated; recommends a
master's degree.
Adopted: no custom kernels; vendor-neutral telemetry; per-configuration fits
never transferred across GPUs.

### B.2 Technical topics and where they entered the design

| Topic | Consequence | Where in the plan |
|---|---|---|
| KV-cache-centric serving (Mooncake, FAST 2025 Best Paper) | Prefix hits skip prefill compute, so marginal energy depends on which endpoint holds the prefix. | Scorer uses uncached tokens (2.2 item 3); prefix-sharing workload and cache ablation (4). |
| Quantization | Precision changes J/token and its benefit depends on batch size (ML.ENERGY: FP8 up to 56% worse at batch 8-16, ~11% better at 65+); A100 has no FP8. | Precision in the model key; AWQ-INT4 in the full-paper tier. |
| RDMA | NIC energy is outside the GPU counter. | Measurement boundary (2.2 item 6). |
| Shape- and card-dependent kernels | Power is not a function of request count alone; fits do not transfer across GPUs. | `P(b, t)` and per-configuration fits (2.2 item 2). |
| CUDA to ROCm, TVM, new AI chips | Telemetry must not assume NVIDIA. | Vendor-neutral attributes (2.2 item 1). |
| Older university clusters (V100) | Volta and newer have the NVML energy counter. | Check architecture before using extra clusters. |
| Roofline | Explains the shape of `P(b)` per phase. | Model form and paper explanations. |
| Cluster operations | Slurm, containers and networking skills are needed. | Week-1 smoke test; job scripts in the repo. |

### B.3 Literature map

Splitwise (ISCA 2024), DynamoLLM (HPCA 2025), throttLL'eM, GreenLLM,
DualScale (2026), Melange, HexGen-2, FREESH, GAR, AIBrix optimize energy or
cost through cluster design, placement, parallelism or DVFS. ML.ENERGY,
"Where Do the Joules Go?", Watt Counts and WattGPU provide measurements and
predictors. Mooncake, FlowKV, HMA-Serve, CloudMatrix and "Demystifying
heterogeneous LLM serving" cover disaggregation and KV transfer. None
contributes request-level endpoint picking on live energy telemetry inside a
production open-source Kubernetes router, composed with its cache and SLO
plugins; that is this project's gap.

## Appendix C. Sources

- llm-d-router: `llm-d-ref/docs/discovery.md`, `docs/architecture.md`,
  `docs/disaggregation.md`, `cmd/epp/main.go`, plugin READMEs (DCGM source and
  extractor, endpoint-attribute scorer/filter, predicted-latency-producer,
  slo-headroom-tier-filter)
- llm-d autoscaling: https://github.com/llm-d/llm-d-autoscaling
- llm-d latency predictor: https://github.com/llm-d/llm-d-latency-predictor
- llm-d inference simulator: https://github.com/llm-d/llm-d-inference-sim
- inference-perf: https://github.com/kubernetes-sigs/inference-perf
- vLLM sleep mode: https://docs.vllm.ai/en/latest/features/sleep_mode/
- vLLM NixlConnector: https://docs.vllm.ai/en/stable/features/nixl_connector_usage/
- nvidia-ml-py: https://pypi.org/project/nvidia-ml-py/ ; pynvml deprecation: https://github.com/gpuopenanalytics/pynvml
- Zeus: https://ml.energy/zeus/measure/
- Part-time Power Measurements: https://arxiv.org/abs/2312.02741
- SC24 GPU power sensor study: https://dl.acm.org/doi/10.1109/SC41406.2024.00028
- ML.ENERGY Benchmark: https://arxiv.org/abs/2505.06371 ; Where Do the Joules Go?: https://arxiv.org/html/2601.22076v1
- Watt Counts: https://arxiv.org/abs/2604.09048 ; WattGPU: https://arxiv.org/abs/2607.02391
- Splitwise: https://www.microsoft.com/en-us/research/wp-content/uploads/2023/12/Splitwise_ISCA24.pdf
- DynamoLLM: https://iacoma.cs.uiuc.edu/iacoma-papers/hpca25_2.pdf
- throttLL'eM: https://arxiv.org/abs/2408.05235 ; GreenLLM: https://arxiv.org/pdf/2508.16449
- DualScale: https://arxiv.org/abs/2602.18755 ; FREESH: https://arxiv.org/abs/2511.00807 ; GAR: https://arxiv.org/pdf/2605.11603
- Melange: https://arxiv.org/abs/2404.14527 ; HexGen-2: https://arxiv.org/pdf/2502.07903 ; AIBrix: https://arxiv.org/pdf/2504.03648
- Mooncake: https://www.usenix.org/conference/fast25/presentation/qin ; https://arxiv.org/abs/2407.00079
- HMA-Serve: https://arxiv.org/abs/2606.29986 ; Demystifying heterogeneous serving: https://arxiv.org/abs/2606.29708
- P/D on emerging accelerators: https://arxiv.org/abs/2606.17104 ; FlowKV: https://arxiv.org/pdf/2504.03775 ; CloudMatrix: https://arxiv.org/pdf/2508.02520
- DCGM field identifiers: https://docs.nvidia.com/datacenter/dcgm/latest/reference/field-identifiers.html
- DRAC: https://docs.mila.quebec/technical_reference/clusters/drac/ ; https://www.alliancecan.ca/en/services/compute/nibi
- HotCarbon: https://hotcarbon.org/cfp ; EuroSys 2027: https://2027.eurosys.org/cfp.html ; MLSys 2027: https://mlsys.org/Conferences/2027/CallForResearchPapers
- USENIX ATC: https://www.usenix.org/blog/usenix-atc-announcement ; SIGOPS ATC: https://en.wikipedia.org/wiki/ACM_SIGOPS_Annual_Technical_Conference
- Levin and Redell: https://www.usenix.org/conferences/author-resources/how-and-how-not-write-good-systems-paper
- Peyton Jones: https://simon.peytonjones.org/great-research-paper/
- Chen Haibo, CCCF 2011: https://zhaoxiahust.github.io/blog/%E4%B8%80%E5%90%8D%E7%B3%BB%E7%BB%9F%E7%A0%94%E7%A9%B6%E8%80%85%E7%9A%84%E6%94%80%E7%99%BB%E4%B9%8B%E8%B7%AF.pdf
- Zhihu: question 657927103; https://zhuanlan.zhihu.com/p/517102867 ; https://zhuanlan.zhihu.com/p/1953242569489257274 ; https://zhuanlan.zhihu.com/p/1897270081664300462
- GPU MODE: https://github.com/gpu-mode/lectures
