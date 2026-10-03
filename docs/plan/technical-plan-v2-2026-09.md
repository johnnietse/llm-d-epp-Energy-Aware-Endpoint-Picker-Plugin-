# Technical Plan: Marginal-Energy Routing for llm-d

Status: proposal (v2, consolidated 2026-09-18). Supersedes
`technical-plan-2026-09.md`. Upstream reference: `llm-d/llm-d-router` at
`e149f34f`.

**Summary.** Build an energy-aware endpoint scorer for the llm-d router as an
out-of-tree plugin module, drive it with GPU energy counters, and evaluate it
on the QHPC club's Frontenac node (2x NVIDIA L4) under Slurm, using
upstream's no-Kubernetes mode.
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
- **H4 (heterogeneous pool).** On a mixed **L4 (frnt201) + L40S (frnt206)**
  pool (roughly 4-5x TDP ratio, both Ada, both FP8) the scorer shifts decode
  load toward the more efficient GPU without SLO loss. Both nodes already
  exist in `gpubase_6hrs`, so this needs no new hardware and no cloud spend.

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
| Workshop (HotCarbon, 5 pages) | H1 on 2x L4; H2 with the GPU-tier prefix-cache term; static SLO caps; packing and oracle baselines; H3 (2-to-1 scale-down); H4 if RTX 6000 nodes arrive in time. |
| Full paper (later) | Learned SLO constraint via the latency predictor; FP8 vs BF16 pools (both GPUs are Ada, so FP8 is native); intra-node P/D; CPU-RAM KV tier; A100 or H100 curves; larger fleets. |

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
| vLLM on frnt201 | Yes | Apptainer available; L4 is a supported vLLM target. | 24 GB limits models to about 3B-7B; use FP8 for headroom. |
| Long-running services | Yes | QHPC jobs on frnt201 run up to 14 days (CAC #17312). | Keep a watchdog; jobs still end at the limit. |
| Exclusive node for measurements | Needs a reservation | CAC: "we can set up a recurring reservation ... so that jobs from the general queue are not scheduled on frnt201 during those periods". | Without it, 6h general jobs and Ryan Grant's group share the GPUs and corrupt energy data. Request benchmarking windows. |
| Hardware heterogeneity | Likely, free | CAC: "If you require additional GPU resources, we can look into adding more RTX 6000 nodes for QHPC." | Ask now; it converts H4 from a paid cloud experiment into an on-prem one. |
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
(c) Sensor behaviour on L4: run the `GPU_Power_Benchmark` microbenchmark
from the SC24 study to measure this GPU's sampling period and rise time.
A100/H100 sample about 25% of the time; L4's behaviour is not published, and
the measurement method depends on it.

**H1 measurements.** Power and latency vs running requests and tokens in
flight; J/token vs prefix-hit ratio; idle power in three states. Pin each
vLLM process to the NUMA node local to its GPU and record it.

**Workloads.** Azure LLM inference traces (2023/2024) for arrivals;
ShareGPT / LMSYS-style prompt lengths; a long-context (summarization) mix, a
short (chat) mix, and a prefix-sharing mix (multi-turn chat, shared system
prompts) so the cache term is exercised.

**Models (sized for 24 GB L4).** Llama-3.2-3B-Instruct and
Qwen2.5-7B-Instruct, BF16 and FP8 (Ada supports FP8 natively on both GPU
types). An 8B model at BF16 leaves little KV-cache room on 24 GB. Check
Hugging Face license terms before use.

**Pools.** Workshop tier: 2x L4, one vLLM per GPU, identical configuration;
plus the mixed L4 + RTX 6000 pool for H4 when available. Full-paper tier:
mixed BF16/FP8, intra-node P/D, larger fleets.

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

Measured on Frontenac 2026-10-02 from account `sa6079052` (Slurm queries, not
assumptions). CAC ticket #17312 supplies the QHPC policy context.

**Blocker: this account currently cannot submit any job.** `id` returns
`sa6079052 slurm_workers frnt_user login_nodes` with no `sg6079000` Unix
group, so:
- `srun -p cpubase_6hrs` fails with "User's group not permitted to use this
  partition";
- any `-A sg6079000*` job fails with "You are not a member of the specified
  account sg6079000";
- `/global/teaching-project/sg6079000` returns "Permission denied".
The Slurm association `sg6079000_cpu` still exists for the account (with
`RawUsage` from past jobs), and CAC noted in #17312 that "some users have
been removed from the teaching account". Also, the GPU association
`sg6079000_gpu` lists `sa6079001, sa6079009, sa6079011, sa6079019,
sa6079049, sa6079053, hpc6079` and **not** `sa6079052`. Both need fixing
before any experiment runs (see `cac-access-request.md`).

**Measured cluster inventory (GPU nodes, `sinfo`):**

| Node(s) | GPUs | Notes |
|---|---|---|
| frnt201 | 2x **L4** | 128 CPU threads (2x32 cores), 250 GB RAM, features `L4,rgrant,intel,avx512`. Partitions: `gpu-L4`, `gpubase_interac`, `gpubase_6hrs`. QHPC's "gpu-rgrant" does not exist as a partition; `gpu-L4` is the node's own partition and shows `MaxTime=06:00:00`, so the 14-day limit from #17312 must come from a QOS not visible here and needs confirming. |
| frnt206 | 2x **L40S** | Same partitions as frnt201. Ada like L4, FP8 capable, roughly 300-350 W against L4's 72 W. **This is the heterogeneous pair for H4, available today, no new hardware needed.** |
| frnt140-147 | 2x **A30** each | Feature `power_ipmi`: node-level IPMI power is exposed here and nowhere else. Use for the secondary node-level energy check. Ampere, 165 W, no FP8. |
| frnt107 | 1x A100 | 379 GB RAM |
| frnt154, frnt190-191 | 8x A100 | `gpubase_6hrs` |
| frnt148-153, 163-187 | 4x RTX 6000 | also the `teaching` partition (1-day limit) |
| frnt155 | 8x RTX 6000 | |
| frnt156 | 8x RTX 8000 | |
| frnt110 | 1x V100 | Volta: lowest generation with the NVML energy counter |

Partition access is `AllowAccounts=ALL`, so the gate is the account
association and Unix group, not the partition.

| Tier | What | Cost | Needed for |
|---|---|---|---|
| Dev machine | Laptop, at least 100 GB free disk, 16 GB+ RAM, WSL2 | free | building, simulator, analysis |
| frnt201 (2x L4) | 72 W class, 24 GB, Ada, FP8 | free once access restored | H1, H2, H3 |
| frnt206 (2x L40S) | 300-350 W class, 48 GB, Ada, FP8 | free once access restored | H4 heterogeneous pool |
| frnt140-147 (2x A30) | 165 W, 24 GB, `power_ipmi` | free | node-level energy validation |
| Larger pools (A100, RTX 6000) | 4-8 GPUs per node | free, 6 h limit | fleet-size experiments, H3 at larger scale |

Home directory: 500 GB quota, 45 GB used. Project directory: 950 GB (needs
group membership). Modules: `apptainer/1.4.5`, `python/3.10-3.14`,
`cuda/11.6.1` (old; the vLLM container supplies its own CUDA, so only the
host driver version matters, still to be read from a GPU node).

Superseded assumption: the earlier plan's "DGX A100 via `gpubase_*`" came
from this repo's old scripts, not from the live cluster.

**Why this platform suits the paper.** L4 and L40S share the Ada
architecture, so the same vLLM build, kernels and FP8 path apply on both,
while TDP differs by roughly 4-5x (72 W against 300-350 W) and memory by 2x.
That is a clean energy-heterogeneity axis, it is free, and it exists on the
cluster today. The A30 nodes add node-level IPMI power for validating the
GPU-counter measurements.

**Constraints this platform imposes.**
- 24 GB on L4: models stay small. Llama-3.2-3B-Instruct and
  Qwen2.5-7B-Instruct, BF16 or FP8; 8B at BF16 leaves little KV-cache room.
- 2 GPUs per node: H1/H2 and a 2-to-1 scale-down for H3. Larger fleets need
  the 4-8 GPU A100 or RTX 6000 nodes, at a 6 h job limit.
- GPU partitions show a 6 h limit; experiment runs are minutes, so this is
  workable, but a long-lived service needs either the QHPC QOS (to be
  confirmed) or job chaining.
- Nodes are shared unless reserved, and #17312 notes another group already
  runs on the L4 GPUs. Co-tenancy corrupts energy measurements, so each run
  records co-tenant processes and contaminated runs are discarded.

### 5.3 People and process

- Supervisor sign-off on the RQ, scope tier, and venue.
- **CAC ticket, blocking everything** (draft in `cac-access-request.md`):
  restore `sa6079052` to the `sg6079000` Unix group, add the account to the
  `sg6079000_gpu` association, confirm the QHPC job-length QOS, and ask about
  reservation windows for measurement runs.
- QHPC club: confirm membership with the co-presidents and agree how research
  runs share frnt201 with workshops.
- Supervisor sign-off on the RQ, scope tier, and venue.
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
- No reservation granted: energy runs are polluted by co-tenant jobs.
  Mitigation: run inside the club's reserved window, detect foreign
  processes with `nvidia-smi` before and during each run, and discard
  contaminated runs.
- Club scheduling conflict: workshops have priority on the node. Agree a
  calendar with the co-presidents and keep runs scriptable so they fit
  between sessions.
- Only 2 GPUs: fleet-level claims stay modest; H3 is a 2-to-1 scale-down
  unless RTX 6000 nodes arrive.
- Frontenac forbids container networking inside jobs: move real-hardware
  runs to a personal A100 allocation, DRAC or cloud.
- Upstream rejects the scorer: keep the out-of-tree module; the paper does
  not depend on the merge.
- Prior work with the same idea appears: search arXiv and llm-d issues
  monthly; the differentiators are real-system integration, the cache-aware
  model, and the packing baseline.

## 11. First measurements (2026-10-03, Frontenac `frnt152`, Quadro RTX 6000)

Run `h1-12302438`: vLLM 0.30.0, Qwen2.5-1.5B-Instruct, 6 load levels x 75 s x 2
trials, energy from the NVML counter, token counts from vLLM's own Prometheus
counters. Raw data: `~/energy-epp/results/h1-12302438/` on `hpc6081`.

| concurrency | power (W) | gen tok/s | J/token | p95 latency (s) |
|---|---|---|---|---|
| idle, no process | 22.0 | - | - | - |
| idle, model resident | 54.6 | - | - | - |
| 1 | 190.0 / 215.3 | 130 | 1.458 / 1.652 | 0.98 |
| 2 | 188.4 / 197.6 | 224 | 0.841 / 0.882 | 1.15 |
| 4 | 196.2 / 197.3 | 436 | 0.450 / 0.453 | 1.18 |
| 8 | 203.2 / 199.6 | 839 | 0.242 / 0.238 | 1.22 |
| 16 | 208.5 / 206.0 | 1544 | 0.135 / 0.133 | 1.34 |
| 32 | 211.7 / 210.0 | 2693 | 0.0784 / 0.0782 | 1.53 |

### 11.1 H1 as written is refuted; the real structure is simpler

`P(b) = P_idle + k_b*b` fits badly: **R^2 = 0.37**, max residual 17.7 W. The
reason is visible in the table: once the endpoint is active, power barely
moves. Across a **32x** range of load, active power stays at
**202 +/- 8 W (13% spread)**, while throughput rises **20.7x**.

What does hold, exactly:

- **J/token = P_active / throughput(b)**, reproduced to **0.0% error** on every
  one of the 12 measurements. Energy per token is governed by the throughput
  curve, not by a power-vs-load curve.
- **Activation dominates.** Idle (model resident) 54.6 W -> active 190 W is
  **+135 W**, against **+0.46 W** for one more concurrent request: a factor of
  **293**.
- **Model residency is not free.** Bare idle 22.0 W -> model loaded 54.6 W is
  **+32.6 W**, which is what vLLM sleep mode can reclaim (relevant to H3).
- **Batching dominates efficiency.** J/token improves **21x** from c=1 to c=32
  (1.65 -> 0.078), larger than the 3-5x reported by ML.ENERGY for larger models
  on datacenter parts, and p95 latency grows only 0.98 s -> 1.53 s.

### 11.2 Revised model for the scorer

Replace the linear power model with:

```
P_endpoint(active) ~= P_active            (constant per GPU, model, precision, TP)
marginal energy of a request = L_tokens * P_active / throughput(b)
plus, if the endpoint is idle:   + (P_active - P_idle) * duration
```

So the scorer needs a measured **throughput-vs-load curve** per configuration
and a single `P_active` constant, not a per-request power slope. This is less
to estimate online, and the activation term is what drives routing decisions.

### 11.3 Consequences for the plan

- **H1 restated** (section 1): predict J/token from the throughput curve at
  constant active power, and report the activation step separately. The old
  linear form stays in the paper as a negative result with its R^2.
- **The consolidation claim gets stronger.** Routing to an already-active
  endpoint costs ~0.46 W; waking an idle one costs ~135 W. The go/no-go gate
  should compare policies primarily on how often they activate idle endpoints.
- **H3 gains a second lever**: sleep mode reclaims the 32.6 W of model
  residency on top of avoided activation.
- **Prefix sharing needs investigation before it is claimed.** At c=8 the
  shared-prefix workload was slightly *worse* (0.2566 vs 0.2423 J/token, 777 vs
  839 tok/s). Either prefix caching is not enabled in this vLLM configuration
  or the longer shared prompt costs more prefill than the cache saves. Resolve
  with `--enable-prefix-caching` explicitly and a cache-hit-rate check before
  building the cache term into the scorer.

### 11.4 Caveats

Single GPU model (Quadro RTX 6000, 250 W limit), one small model (1.5B), fixed
128-token outputs, closed-loop load, 2 trials. The activation and batching
effects are large enough to survive these limits, but the absolute numbers are
specific to this configuration. A30 and L4 runs, and a 7B model, are the next
measurements.

## 12. Instrumentation choice on Frontenac (measured 2026-10-03)

This section reports what each candidate telemetry source *actually does* on
this cluster for an unprivileged user. Every verdict below was produced by
running the tool, not by reading its documentation. The packages were
downloaded and unpacked into `~/energy-epp/opt` without root
(`rpm2cpio | cpio -idm`); scripts are
`experiments/scripts/{fetch_instruments.sh,probe_instruments_gpu.sbatch}`,
raw output in `~/energy-epp/instruments-probe/`.

Environment: Rocky Linux 8.10, host glibc 2.28, CVMFS module shell glibc 2.37,
driver **610.43.02**, job 12302443 on `frnt152` (4x Quadro RTX 6000) under
`--exclusive` with zero co-tenant processes.

| Source | Verdict | The evidence |
|---|---|---|
| **NVML** (`nvidia-smi`, `nvidia-ml-py`) | **Primary.** Unchanged. | Hardware energy counter readable unprivileged; previously validated counter 25.94 W vs polled 25.96 W at idle. |
| **DCGM** (`dcgmi`, `nv-hostengine`, `dcgm-exporter`) | **Unusable without root.** Not an optional second source: an unavailable one. | `error watching fields: Host engine is running as non-root`. It refuses **every** field, including plain power (155) and energy (156), not merely profiling fields. |
| **Nsight Systems** (`nsys`) | **Runs; counter collection restricted.** Out of scope, now for a measured reason. | `nsys --version` works on CVMFS glibc 2.37. `nsys status -e`: CPU profiling (process-tree) **OK**, (system-wide) **Fail**, `perf_event_paranoid` 2, root privilege disabled. |
| **CUPTI** | **Counters denied; tracing pending.** | `RmProfilingAdminOnly: 1`, which is the kernel-module parameter that denies non-root counter access. Whether CUDA *tracing* still works is pending a re-run (see 12.5). |
| **IPMI** | **Hardware present, permission-gated.** Strengthens the CAC ask rather than killing it. | `/dev/ipmi0` **exists** on the compute node as `crw------- 1 root root 243, 0`. `AcctGatherEnergyType = (null)`, and `sacct` duly reported `ConsumedEnergy=0` for this job. |

Decision: **NVML is the only viable source, and that is now a finding rather
than a preference.**

### 12.1 DCGM: the exact failure, and why it matters to the paper

DCGM is the path upstream llm-d uses (`dcgm-data-source`), so establishing that
it is closed to us is load-bearing for our claim, not an inconvenience.

`dcgm-exporter` 4.8.4 progressed further than expected before failing, which is
what makes the error trustworthy:

```
level=INFO  msg="DCGM successfully initialized!"
level=INFO  msg="NVML provider successfully initialized"
level=INFO  msg="Successfully queried DCGM profiling metric groups" count=7 gpu_model="Quadro RTX 6000"
level=ERROR msg="Failed to watch DCGM fields"
            field_names="[sm_clock memory_clock memory_temp gpu_temp power_usage
                          total_energy_consumption ... dram_active ...]"
            error="error watching fields: Host engine is running as non-root"
```

So initialisation, NVML attachment and profiling-group discovery all succeed;
the refusal is specifically at the field-watch call, and it covers the whole
field list rather than the profiling subset. An embedded host engine does not
help: the exporter *is* embedded mode.

Consequences:

1. The "optional explanatory DCGM fields" idea in the previous draft of this
   section is withdrawn. SM-activity and DRAM-bandwidth evidence for *why*
   power saturates is **not available to us**, and any mechanism argument has
   to be made from NVML quantities plus engine-level metrics instead.
2. This is a concrete instance of the paper's framing. The validity review
   narrowed our claim to routing "under no privileged control"; we can now cite
   a measured error string instead of asserting that privileges are unavailable.
   Reviewers can check it.
3. If CAC ever grants a root-run host engine on a reserved node, the DCGM
   comparison becomes available and is worth one job. It is not on the critical
   path.

Two packaging facts, recorded so the next person does not repeat the hour:

- `datacenter-gpu-manager-4-core-4.7.0` is a **13 KB payload-free metapackage**.
  The newest `-core` that actually ships `libdcgm.so.4` is **4.6.1**, confirmed
  by querying the repo's `primary.xml.gz` for which package provides that
  soname. DCGM 3.3.9 ships a single self-contained 816 MB RPM but registers only
  the `topo` subsystem from a user-space extraction.
- `dcgmi` takes the subsystem **before** `--host`
  (`dcgmi dmon -e 156 --host 127.0.0.1:PORT`); the reverse order returns
  `ERROR: Invalid subsystem`, which is easy to misread as a privilege problem.

### 12.2 DCGM field identifiers: correcting an error in v1

Plan v1 claimed `DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION` was deprecated in favour
of `DCGM_FI_DEV_GPU_ENERGY_JOULES_TOTAL` (field 1611, whole joules). **Both
halves of that are wrong.** From `dcgm_fields.h` in the extracted package, and
from exporter 4.8.4's own counter CSVs:

```
#define DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION 156
```

There is no `GPU_ENERGY_JOULES_TOTAL` field and no field numbered 1611 in this
header. Field **156** (millijoules) is the only energy field DCGM exposes, it is
not deprecated, and it is the one the exporter ships enabled by default. Power
is **155**. The profiling fields are `DCGM_FI_PROF_SM_ACTIVE` (1002) and
`DCGM_FI_PROF_DRAM_ACTIVE` (1005). Corrected in v1 as well.

### 12.3 IPMI: the ask is now evidence-backed

The previous version of this section said we "cannot read node power directly".
More precisely: the BMC character device **exists** on compute nodes and is
mode 0600 owned by root. Nothing is missing from the hardware or the kernel;
only the permission is absent. Slurm's `slurmd` runs as root, so enabling
`AcctGatherEnergyType=acct_gather_energy/ipmi` would expose per-job node energy
through `sacct` without granting any user direct BMC access. That is a strictly
smaller request than "give me access to `/dev/ipmi0`", and worth stating that way
in the ticket.

One correction to the ask: `frnt152` advertises
`AvailableFeatures=intel,avx512,avx512_gpu` and **not** `power_ipmi`. The
`power_ipmi` feature is on frnt140-147, so the request must name those nodes
specifically rather than ask for it cluster-wide.

### 12.4 What else the probe settled

- **`--exclusive` works.** Jobs received whole nodes with all four GPUs visible
  and no co-tenant processes, on both `frnt148` and `frnt152`. Blocking defect
  B4 is removed at no cost and with no cloud.
- **Power capping is denied**: `nvidia-smi -pl 150` returns "Insufficient
  Permissions". The RTX 6000 reports `power.min_limit 150.00 W` and
  `power.max_limit 250.00 W`, so a 1.67x controlled-heterogeneity experiment
  exists *if* CAC grants it.
- **Persistence mode is enabled** on every GPU, so idle power is stable between
  jobs.
- **GPU UUIDs are exposed**, which is what makes 13.5 possible.
- **`perf_event_paranoid` is 2**, which caps CPU-side sampling to the process
  tree. Irrelevant to our energy measurements, relevant if anyone later wants
  host-side profiling.

### 12.5 Still pending

Two items were lost to bugs in the probe script, not to the cluster, and are
queued for a re-run:

1. **CUPTI tracing.** The in-container test invoked `python`, but the vLLM image
   provides `python3`, so it never ran. The question is narrow and worth
   answering: `RmProfilingAdminOnly` gates *counter* collection, so CUDA
   *activity tracing* may still work. If it does, per-kernel timelines are
   available even though per-kernel counters are not.
2. **`nsys` CUDA trace versus counters.** Same distinction, tested by actually
   profiling a matmul rather than reading the status output.

Neither changes the NVML decision. Both belong in the thesis methods chapter as
recorded negative results.

## 13. Research design additions (2026-10-03)

### 13.1 No simulation, and we do not need any

Everything the plan previously wanted simulation for is available as real
hardware on Frontenac:

| Previously simulated | Real equivalent on the cluster |
|---|---|
| Fleet of 8 endpoints | `frnt154` (8x A100) or `frnt155` (8x RTX 6000), one vLLM per GPU |
| 16+ endpoints | multi-node job across `frnt148-153` (4x RTX 6000 each) |
| Hardware heterogeneity | six real GPU types: A30, RTX 6000, RTX 8000, A100, L4, L40S, V100, pinned with `-C` |
| "Oracle" policy | computed **post hoc from measured runs**, not simulated: the best assignment the measured curves allow. This is analysis of real data, not a model of physics. |

The only modelling that remains is the offline *bound* used at the go/no-go
gate, and it is explicitly a planning instrument, never a reported result.

### 13.2 Metrics

Report energy-delay product (or SLO-goodput per joule) as the headline, so a
policy that trades latency for energy is still orderable, with J/token and
p95 latency alongside it. Keep GPU-seconds active as the mechanism metric.

### 13.3 Experimental rigour

- **Randomised interleaved trials**, not sequential blocks: thermal drift and
  cluster state otherwise confound the policy comparison. Seed the order and
  report the seed.
- **Trial count from a power analysis** on the variance already measured, not
  a round number.
- **Negative control**: include a policy that should not help (random). If the
  harness cannot separate it from the good policy, the measurements are not
  sensitive enough to support any claim.
- **Ablations as first-class figures**: activation term on/off, cache term
  on/off, SLO filter on/off.
- **Overhead honesty**: report the scorer's own p99 CPU time and the latency it
  adds to scheduling.
- **Pre-registration**: hypotheses, metrics and analysis committed to the repo,
  timestamped, before the final runs.
- **Co-tenancy guard**: every run records `nvidia-smi --query-compute-apps`;
  contaminated runs are discarded, not averaged.

### 13.4 Per-request energy attribution under continuous batching

Every paper found in the literature check divides GPU-level energy by aggregate
tokens, ours included. Under continuous batching, requests overlap, so the
energy of an individual request is not identifiable from GPU-level counters.
A defensible method - short windows, request arrival/completion timestamps,
attribution by token share within each window, validated against controlled
single-request runs - would be a genuine methodological contribution, and it is
exactly what the scorer needs, since marginal energy is an attribution
question.

### 13.5 Intra-model heterogeneity: the same GPU model is not the same GPU

A multi-GPU node gives several nominally identical dies in different physical
slots with different airflow. If their power at matched load differs measurably,
that is a routing signal no surveyed work uses, and it exists only on real
multi-GPU hardware.

**First observation (job 12302443, `frnt152`, 4x Quadro RTX 6000, idle,
`--exclusive`, no co-tenants, persistence mode on, all sampled in one
`nvidia-smi` call):**

| GPU | UUID (prefix) | Idle power | Temp | SM clock |
|---|---|---|---|---|
| 0 | `GPU-ce3f5de7` | 21.95 W | 25 C | 300 MHz |
| 1 | `GPU-55fdeae3` | 22.29 W | 24 C | 300 MHz |
| 2 | `GPU-e1ef0a37` | 22.68 W | 23 C | 300 MHz |
| 3 | `GPU-ff881352` | **13.04 W** | 20 C | 300 MHz |

GPU 3 draws **1.69x less** idle power than GPU 2, on the same node, at the same
instant, at the same clock. The spread across 0-2 is small (0.73 W, 3.3%) and
monotonic with temperature; GPU 3 is the outlier.

**This is not yet a result, and the plan should not treat it as one.** The
obvious competing explanation is residual state rather than silicon: GPU 3 is
also the coolest die, consistent with it having been idle longest or sitting in
a deeper power state, and a single instantaneous sample cannot separate that
from a persistent per-die difference. Treating a 1.69x number from one sample as
a finding is exactly the error we criticised in the eight drafts.

**The experiment that would settle it**, costing one or two jobs:

1. **Matched load, not idle.** Run an identical vLLM instance and identical
   request stream on each die in turn, using the energy counter over a fixed
   window rather than instantaneous power.
2. **Repeated measures with randomised order.** Each die visited several times
   in a seeded random sequence, so thermal drift and ordering cannot masquerade
   as a die effect. Report per-die mean with 95% CI.
3. **Thermal equilibration.** A fixed warm-up before each measurement window,
   and record inlet temperature if exposed, so "cold die" is eliminated as the
   explanation.
4. **Identify dies by UUID, never by index.** Slurm and CUDA ordering are not
   stable across jobs; the UUIDs above are the keys.
5. **Cross-node replication.** Repeat on a second 4-GPU node, and on
   `frnt155` (8x RTX 6000) where slot-to-airflow variation should be larger if
   the effect is physical.
6. **Negative control.** The same analysis on one die measured repeatedly
   should produce a spread no larger than measurement noise. If between-die
   spread does not exceed within-die spread, the effect is not there.

**Why it is worth the jobs either way.** If a real per-die difference survives,
the energy scorer should key on GPU UUID rather than endpoint, which is a
cheap implementation change and a genuinely unclaimed routing signal. If it
does not survive, we have a recorded negative control that strengthens the main
measurements, since it demonstrates the harness can distinguish a real effect
from noise at this scale. That is the standing requirement from 13.3.

### 13.6 Deliverable split

The thesis and the paper fail for opposite reasons, so material is routed, not
duplicated:

| | Thesis | Paper |
|---|---|---|
| Question | descriptive: can it be built, what does it cost? | comparative: does it beat SLO-aware packing? |
| Design space (filters, SCI, carbon, KV-cache model) | Chapter 3, labelled implemented vs designed-only | out |
| Implementation + conformance | Chapter 4 | half a page + artifact |
| Measurements | Chapter 5 primary evidence | the whole paper |
| Risk if the gate fails | none: reports a negative result | paper is rescoped to measurement |

Thesis first; the paper is distilled from the same experiments afterwards.

### 13.7 Claims we will not make

Written down so the drafts' habits do not return: no "first energy-aware
scheduling", no carbon-awareness claim (one cluster shares one grid), no ASIC
or cross-vendor heterogeneity, no SCI novelty, no claim that rests on
simulation. Minimum publishable unit: characterisation on one pinned GPU type
plus a routing-policy comparison with confidence intervals.

### 13.8 Cloud rental: not needed

Rented GPUs (Massed Compute: A30 $0.35/hr, A100 $1.35/hr, H100 $2.73/hr, bare
metal available) were considered for single-tenancy, fixed hardware, root and
fleet size. The probe shows Frontenac already supplies the first two via
`--exclusive` and `-C`, supplies more GPU diversity than the rental menu, and
supplies 8-GPU nodes for fleet work. Only privileged power capping is missing,
and that is a CAC request rather than a purchase. Keep rental as contingency
only (if CAC refuses reservations, or for a Kubernetes-native demo).

### 13.9 Updated CAC ask

Added to the access request: enable `AcctGatherEnergyType` (IPMI) so `sacct`
reports per-job energy on the `power_ipmi` nodes; and grant, or pre-apply on a
reserved node, a lowered GPU power limit so the 150-250 W controlled
heterogeneity experiment becomes possible.

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
