# Technical Plan: Making the Energy-Aware EPP Real (September 2026)

Status: superseded by `technical-plan-v2-2026-09.md`. Kept for the
repo audit (sections 1-2) and literature survey (section 3).

Original status: proposal. Based on a review of this repo at `fa06279`, upstream
`llm-d/llm-d-router` at `e149f34f` (2026-09-17), and a literature/project survey.

---

## 1. Where the project stands (verified, not assumed)

| Check | Result |
|---|---|
| `go test ./...` on `pkg/` | Passes. |
| `upstream-port/` built standalone | Fails: its `go.mod` declares no dependencies. |
| `upstream-port/` copied into current upstream tree | Fails: `scheduling.Metrics` is undefined, tests call the old 4-argument `Score`. `COMPATIBILITY.md` claiming "100% API compatible" is wrong. |
| `pkg/config/gie_adapter.go` target | `sigs.k8s.io/gateway-api-inference-extension` v1.5.0 interfaces. The EPP code has since moved into `llm-d/llm-d-router`; GIE now only hosts the `InferencePool` API. This adapter targets an abandoned location. |
| Energy/carbon work in upstream | None. No open issue proposes it. Closest: DCGM GPU-utilization source + extractor (#1895, merged 2026-07-21), generic `endpoint-attribute-scorer/filter` (#1904), accelerator-capability PR (#1873, open). `llm-d/llm-d#1831` (J/token observability) was closed. |

So the niche is still open, but the code that would fill it has to be rebuilt
on the current upstream framework.

## 2. Why the current direction is vague, and what to change

### 2.1 Telemetry through pod labels is the wrong channel
`upstream-port` reads power, tokens/s, and J/token from pod labels. Labels are
Kubernetes object metadata: every update is an API-server write and an informer
event to every watcher. Power changes every second; this does not scale and no
maintainer will accept it.

**Change:** use the upstream data layer (Source -> Extractor -> Attribute).
`dcgm-data-source` already scrapes DCGM Exporter per endpoint. Add an extractor
that publishes power and energy attributes. Keep labels only for static facts
(accelerator type, idle power, TDP).

### 2.2 Phase detection by `RequestSizeBytes > 4096` is unnecessary
Upstream runs P/D as separate scheduling profiles (`disagg-profile-handler`,
`prefill`/`decode` profiles, `prefix-based-pd-decider`). Each profile lists its
own plugin instances and weights. Multiple instances of one plugin type with
different parameters are supported.

**Change:** delete the phase heuristic. Configure the energy scorer with a
different weight in the `prefill` profile than in the `decode` profile. Phase
asymmetry becomes configuration, not code.

### 2.3 The carbon dimension is collinear with energy inside one cluster
All endpoints in one pool share the same grid. Carbon per token is
`EPT x CI` with the same `CI` for every endpoint, so after min-max
normalization the carbon ranking equals the energy ranking. The "carbon
weight" only re-weights energy.

**Change:** carbon is a *cross-location* or *cross-time* signal. It belongs in
(a) multi-cluster routing (upstream EPP "hub" deployments route across peer
clusters), or (b) a slow control loop (capacity, admission, weight tuning),
not in the per-request intra-pool scorer.

### 2.4 Static energy-per-token ignores batching (the biggest technical gap)
ML.ENERGY measurements show larger batch sizes cut J/token by 3-5x
(Chung et al., "Where Do the Joules Go?", 2026). A GPU's J/token is a
function of its current load, not a constant. The scorer's
`1/(1+EPT/5)` treats it as a constant and the scorer declares itself
`Distribution` (spread load). Spreading keeps more GPUs at low batch, which
is the least energy-efficient operating point.

**Change:** score by **marginal energy**: the extra joules the cluster spends
if this request goes to endpoint `e` given its current batch. Idle power of
a powered-on GPU is sunk, so the marginal model naturally prefers packing onto
already-busy efficient endpoints until latency headroom runs out. This is the
defensible research contribution (section 4).

### 2.5 The hardware story needs to match what can actually run
The headline results route prefill to H100 and decode to "Qualcomm QC-100
ASIC". vLLM P/D requires KV-cache transfer between the prefill and decode
engines (NIXL). NixlConnector supports heterogeneous TP and block sizes, and a
Trainium-to-NVIDIA path exists via LIBFABRIC, but an NVIDIA-to-Qualcomm path is
not a supported configuration. The 99.8% / 100% win rates come from a
simulation whose weights were chosen to produce that outcome, so they show the
code works as designed, not that energy was saved.

**Change:** target NVIDIA heterogeneity you can actually test (for example
A100 + L4, or H100 + A100, or the same GPU at different power caps). Replace
tautological win-rate numbers with measured J/token and SLO attainment against
baselines.

### 2.6 Duplicates of upstream features

| This repo | Upstream equivalent | Action |
|---|---|---|
| `SLOConstraintFilter` (TTFT/TPOT estimated from TDP) | `slo-headroom-tier-filter` + `latency-scorer` with the latency predictor | Use upstream. TDP is not a latency model. |
| `DCGMScraper` | `dcgm-data-source` | Use upstream source, add an extractor. |
| `ThermalThrottlingFilter` | `endpoint-attribute-filter` on a temperature attribute | Config only, once the extractor publishes temperature. |
| Per-pod power-cap part of `EnergyBudgetFilter` | `endpoint-attribute-filter` (`power / limit <= 0.9`) | Config only. |
| Latency sub-score inside the energy scorer | `load-aware`, `queue-depth`, `latency-scorer` combined by profile weights | Make the energy scorer single-objective; let profile weights do the multi-objective sum. |

### 2.7 Scope to drop from claims
`pkg/ebpf` (structural stub, no loader), `pkg/slurm`, `pkg/ray`, RDMA/NUMA and
KV-transfer "energy penalty" scorers have no measured basis. Move them to a
"future work" section. A narrow claim that is measured beats a broad claim that
is simulated.

## 3. What the literature and big projects already cover

| Work | What it does | Relation to this project |
|---|---|---|
| Splitwise (Patel et al., ISCA 2024) | Splits prefill/decode across machines; decode on lower-power HW. 1.76x throughput at 15% lower power. | The core motivation. Cluster *design*, not a production router. |
| DynamoLLM (Stojkovic et al., HPCA 2025) | Reconfigures instances, parallelism, GPU frequency under SLOs. 52% energy saved. | Control-plane knobs. Complementary. |
| throttLL'eM (Kakolyris et al., 2024) | Iteration-level DVFS + autoscaling with ML performance model. Up to 43.8% less energy. | DVFS, not routing. |
| DualScale (Basit et al., 2026) | Phase-aware placement + per-phase DVFS on 16 H100 nodes. Up to 39% (prefill) / 48% (decode) less energy vs DistServe. | Closest in spirit; homogeneous H100; no Kubernetes router. |
| Melange (Griggs et al., 2024) | ILP picks GPU mix by request size, rate, SLO. Up to 77% cost reduction. | Provisioning. Its request-size-to-GPU insight informs scoring. Used by AIBrix. |
| HexGen-2 (2025) | Disaggregated inference on heterogeneous GPUs. | Placement/parallelism across heterogeneous HW. |
| FREESH (He et al., 2025) | Routes across geo-distributed heterogeneous clusters with carbon/energy + DVFS. 28.6% energy, 45% emissions reduction. | Confirms carbon belongs at the cross-location level. |
| GAR (2026) | Carbon-aware routing as constrained optimization over per-request CO2 estimates. | Model-level routing, not endpoint picking. |
| ML.ENERGY Benchmark / Leaderboard v3 (Chung et al., NeurIPS 2025; 2026 analysis) | Measured J/token across H100/B200, batch sizes, precision. | Source of priors and the batch-size effect. HF dataset `ml-energy/benchmark-v3` is gated; request access. |
| Watt Counts (Fadel Argerich et al., 2026) | 5,000+ energy experiments, 10 NVIDIA GPUs, 50 LLMs. Up to 70% energy reduction via GPU choice. | Open dataset for calibrating per-GPU energy curves without owning the GPUs. |
| WattGPU (same authors, IJCAI-W 2026) | Predicts power and inter-token latency on unseen GPUs from public specs. | Fallback model for endpoints with no measured curve yet. |
| Kepler (CNCF, v0.11.4) | Per-pod/container energy exporter. | Alternative source for non-NVIDIA or CPU energy. |
| `llm-d-inference-sim` | vLLM-compatible simulator with TTFT/ITL/load latency models and P/D mode. | Scale testing of routing without GPUs. |

**Gap this project fills:** every system above optimizes energy at the
provisioning, placement, or DVFS level. None contributes *request-level
endpoint picking using live energy telemetry* to a production open-source
Kubernetes router, composed with that router's existing SLO and cache-affinity
scorers. That is a clear, narrow, publishable, upstreamable contribution.

## 4. Target design

```
dcgm-data-source ──> energy-extractor ──> attrs: GPUPowerWatts, GPUEnergyJoules (counter),
                                                  GPUTempC, PowerLimitWatts
metrics-data-source (vLLM) ──> core extractor ──> running/waiting requests,
                                                  generation/prompt token counters
                              │
                              v
                  energy-efficiency producer (per endpoint, online fit)
                  -> attr: EnergyModel{ idleW, slopeW_per_req, tokps(b) }
                              │
   request ──> filters: prefill/decode-filter, slo-headroom-tier-filter,
                        endpoint-attribute-filter (power/limit, temperature)
           ──> scorers: prefix-cache (affinity), latency/load, energy-scorer
           ──> max-score-picker
```

### 4.1 Energy extractor (first upstream PR, smallest useful change)
Extend or sit beside `dcgm-extractor` to publish power, cumulative energy,
temperature, and enforced power limit as `ScalarMetricValue` attributes, with
the same `pod`-label matching and `max`/`sum` aggregation across the pod's GPUs
(sum for power and energy; max for temperature).

Field names must be checked against the deployed `dcgm-exporter` counters CSV:
current DCGM docs deprecate `DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION` (mJ) in
favor of `DCGM_FI_DEV_GPU_ENERGY_JOULES_TOTAL` (field 1611, whole joules).
Prefer the energy counter's derivative over instantaneous power samples; the
counter integrates between scrapes, instantaneous power aliases.

### 4.2 Online energy model per endpoint
From the counters, per scrape window `w`:

- `P_e = dE_e / dt`
- `T_e = d(generated + prompt tokens) / dt`
- `b_e = vllm:num_requests_running` (mean over window)

Fit `P_e(b) = P_idle,e + k_e * b` with exponentially-weighted recursive least
squares (the Welford/EWMA code in `pkg/signals/energy_store.go` is reusable).
Seed `P_idle` and `k` from Watt Counts / ML.ENERGY curves, or from WattGPU, and
let online data take over.

### 4.3 Energy scorer (second PR)
Marginal energy of placing a request with expected token work `L` on `e`:

```
dE_e ~ (P_e(b_e + 1) - P_e(b_e)) * dur_e(b_e + 1, L)
     + b_e * (P_e(b_e)) * (dur slowdown imposed on co-running requests)
```

Start with the first term only (simple, testable), add the slowdown term if
evaluation shows it matters. `L` comes from `TokenizedPrompt.TokenCount()` for
prefill and a configurable expected-output prior for decode. Score is
`1 - normalized(dE)`. Category: `Balance` (it concentrates load until SLO
headroom runs out, which is neither pure Affinity nor Distribution).

Constraint handling (the "epsilon-constraint" of the thesis) is done by
running `slo-headroom-tier-filter` before the scorer: energy is minimized only
among endpoints predicted to meet TTFT/TPOT.

### 4.4 Configuration, not code, for phase and policy

```yaml
schedulingProfiles:
- name: prefill
  plugins:
  - pluginRef: prefill-filter
  - pluginRef: slo-tier
  - pluginRef: prefix-cache-scorer
    weight: 3
  - pluginRef: latency-scorer
    weight: 3
  - pluginRef: energy-scorer
    weight: 1          # prefill: latency-dominant
  - pluginRef: max-score-picker
- name: decode
  plugins:
  - pluginRef: decode-filter
  - pluginRef: slo-tier
  - pluginRef: prefix-cache-scorer
    weight: 2
  - pluginRef: energy-scorer
    weight: 4          # decode: energy-dominant
  - pluginRef: max-score-picker
```

### 4.5 Carbon and the adaptive controller (later, optional)
- Carbon: per-peer-cluster attribute from Electricity Maps
  (`/v3/carbon-intensity/latest`; CO2Signal is the legacy name, the repo's
  `api.co2signal.com/v1` endpoint should be migrated) consumed by hub-level
  routing.
- Adaptive FSM: profile weights are static config, so the controller cannot
  rewrite other scorers' weights. It can adjust the energy scorer's own
  aggressiveness (for example a required SLO-headroom margin before packing).

## 5. Roadmap with exit criteria

| Phase | Weeks | Work | Done when |
|---|---|---|---|
| 0. Reset | 1 | Fork `llm-d/llm-d-router`; retire `upstream-port/` and GIE adapters; free disk (C: had under 1 GB); mark eBPF/Slurm/Ray as future work; fix README/COMPATIBILITY claims. | Fork builds with `make presubmit`. |
| 1. Measure | 2-3 | On Frontenac (A100 via SLURM) and one other GPU type (cloud L4/A100, or A100 at two power caps via `nvidia-smi -pl` if permitted): run vLLM, sweep batch/concurrency, log NVML energy counter + vLLM token counters. Request ML.ENERGY access; pull Watt Counts data. | Per-GPU `P(b)` and `J/token(b)` curves with error bars; the batch-size effect reproduced on your own hardware. |
| 2. Extractor + model | 2 | `energy-extractor` and online model producer in the fork, unit tests using upstream test helpers and mock DCGM payloads. | Attributes visible in EPP debug output against a real `dcgm-exporter`. |
| 3. Scorer | 2 | `energy-scorer` (marginal energy), README in upstream plugin style, factory registration. | Unit tests + `make presubmit` green. |
| 4. Evaluate | 3-4 | (a) Kind + `llm-d-inference-sim` with per-endpoint latency profiles and a small power-emulating sidecar (DCGM-format metrics from the fitted `P(b)`) for scale. (b) Real 2-GPU-type run on GKE (repo has a walkthrough). Traces: Azure LLM inference trace, ShareGPT; load via `llm-d-benchmark`. Baselines: default llm-d config, GPU-utilization scorer (#1904), energy-scorer, energy-scorer without SLO filter. | Measured J/token, TTFT/TPOT p50/p99, SLO attainment, goodput per baseline; results reproducible from a script. |
| 5. Upstream | parallel from phase 2 | Open an issue first (upstream `AGENTS.md`: non-trivial work must be tracked; minimal PRs; DCO sign-off). PR 1: energy attributes in extractor. PR 2: energy scorer. PR 3: guide + example config. | Maintainer feedback on the issue before PR 2. |
| 6. Optional | - | Hub-level carbon routing; controller; coordination with DVFS (DualScale-style). | Thesis future-work chapter. |

## 6. Risks

- **No heterogeneous GPUs on hand.** Mitigate with power-capped identical GPUs
  (a real heterogeneity axis, used in DynamoLLM/throttLL'eM) plus simulation
  calibrated on public datasets.
- **Telemetry lag.** DCGM scrape at 1 s vs per-request decisions. Score on the
  fitted model plus live `num_requests_running` (fast signal), not raw power.
- **Packing vs tail latency.** Marginal-energy scoring concentrates load; the
  SLO filter must be on, and the evaluation must report p99, not only means.
- **Upstream appetite.** Issue first; keep PR 1 small and generally useful
  (power/energy attributes help observability even without the scorer).

## 7. Sources

- Splitwise: https://www.microsoft.com/en-us/research/wp-content/uploads/2023/12/Splitwise_ISCA24.pdf
- DynamoLLM: https://iacoma.cs.uiuc.edu/iacoma-papers/hpca25_2.pdf
- throttLL'eM: https://arxiv.org/abs/2408.05235
- GreenLLM: https://arxiv.org/pdf/2508.16449
- DualScale: https://arxiv.org/abs/2602.18755
- FREESH: https://arxiv.org/abs/2511.00807
- GAR: https://arxiv.org/pdf/2605.11603
- Melange: https://arxiv.org/abs/2404.14527
- HexGen-2: https://arxiv.org/pdf/2502.07903
- AIBrix: https://arxiv.org/pdf/2504.03648
- ML.ENERGY Benchmark: https://arxiv.org/abs/2505.06371
- Where Do the Joules Go?: https://arxiv.org/html/2601.22076v1
- Watt Counts: https://arxiv.org/abs/2604.09048
- WattGPU: https://arxiv.org/abs/2607.02391
- DCGM field identifiers: https://docs.nvidia.com/datacenter/dcgm/latest/reference/field-identifiers.html
- vLLM NixlConnector: https://docs.vllm.ai/en/stable/features/nixl_connector_usage/
- Electricity Maps API: https://app.electricitymaps.com/developer-hub/api/signals
- llm-d-router DCGM source (#1895), GPU-util scorer (#1904), accelerator capability (#1868/#1873), llm-d J/token issue (llm-d/llm-d#1831)
- Kepler: https://github.com/sustainable-computing-io/kepler
- llm-d-inference-sim: https://github.com/llm-d/llm-d-inference-sim
