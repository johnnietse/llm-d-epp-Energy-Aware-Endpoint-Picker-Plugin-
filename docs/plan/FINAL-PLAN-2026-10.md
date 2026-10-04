# Finalized plan (2026-10-03)

Authoritative. Supersedes the scope decisions in `technical-plan-2026-09.md`
(v1) and consolidates `technical-plan-v2-2026-09.md`,
`research-validity-review-2026-10.md` and `draft-assessment-2026-10.md`. Where
this document and an earlier one disagree, this one wins.

---

## 0. The finding that forced this document

A full audit on 2026-10-03 compared the plan against the repository. Result:

> **The plan and the code describe two different projects.** `pkg/` contains 45
> Go files that build cleanly and pass every test, and almost all of it
> implements the design the validity review already discarded. The direction the
> plan actually commits to has **no implementation at all**.

The plans mention `pkg/` four times in total, and the only substantive mention
is in the superseded v1. Nobody reconciled them. Concretely, the existing
`pkg/plugins/scorer/energy_aware_scorer.go`:

- scores with `w_latency*S_latency + w_energy*S_energy + w_carbon*S_carbon`,
  the weight-vector approach the draft assessment called a tautology
- uses **TDP as a proxy** for compute capability and again for carbon
  (`profile.TDP_Watts / 700.0`), when our measurements show active power is
  near-constant and TDP-proportional scoring has no measured basis
- targets `sigs.k8s.io/gateway-api-inference-extension v1.5.0`, not llm-d-router

So the repository's working code is evidence for a hypothesis we have refuted
with our own data. That is the single largest risk to the project: it is easy to
keep polishing code that cannot support the claim.

---

## 1. Research question and claim

**RQ.** On a shared, multi-tenant GPU cluster where the tenant has no
privileged control, does energy-aware **replica selection** inside a production
inference router reduce energy per SLO-satisfied request relative to
SLO-aware packing, and at what cost in tail latency?

**Claim, stated to survive review:**

> The first implementation of energy-aware **endpoint (replica) selection**
> inside a production open-source inference router (llm-d), composed with that
> router's existing SLO and prefix-cache plugins, evaluated on a shared cluster
> **without privileged control** (no DVFS, no MPS, no power capping, no root),
> with the artifact upstreamed.

Every clause is load-bearing. Two must be stated in the **first two sentences
of the abstract** or the paper is misread:

1. **Replica selection, not model selection.** Most 2026 energy-routing work
   (GreenServ 2601.17551, Measured Joules 2609.23085, survey 2603.04445) routes
   among *different models*. We route among interchangeable backends of *one*
   model. A reviewer who misses this files us under a crowded area.
2. **No privileged control.** Festina (2606.30391) achieves 56% but requires
   MPS and frequency control, i.e. root. What remains when clocks and power
   states are untouchable is exactly the placement decision, and nobody has
   isolated it.

**Out of scope, permanently:** carbon-aware routing (one cluster shares one
grid, so the carbon term is collinear with energy), SCI as a contribution,
cross-vendor or ASIC heterogeneity, DVFS/MPS/power-capping mechanisms, model
selection, autoscaling as a headline, and anything resting on simulation.

### 1.1 FINER assessment of the question

| Criterion | Verdict | Basis |
|---|---|---|
| **Feasible** | Yes, with one caveat | Hardware, telemetry and harness are all proven on Frontenac. The caveat is effect size: if Stage 2 shows the achievable saving is within noise, the comparative question becomes unanswerable on this cluster and the project pivots to measurement. |
| **Interesting** | To a systems-integration audience | A reviewer who values deployable artifacts will care. One who wants a new mechanism will not, because we deliberately claim no new mechanism. Venue choice must match. |
| **Novel** | Narrowly, and the window is closing | Two agenda papers name this gap without filling it (2609.05565, 2603.21354) and vLLM semantic-router #2332 is building the telemetry contract for it. Unimplemented today; not necessarily in six months. |
| **Ethical** | Yes | No human subjects, no dual use. AI assistance disclosed. |
| **Relevant** | Yes | Inference energy is the dominant and growing share of LLM energy use, and the unprivileged tenant case is the common one. |

The weakest criterion is **Novel**, and it is weak in a specific way: the
*measurement* is replication, the *mechanism* is deliberately absent, and the
*integration* is the contribution. That is a workshop paper. It becomes a full
conference paper only if Stage 5 produces a comparative result with
confidence intervals, or if the per-die heterogeneity result in Stage 6 lands.

---

## 2. Code disposition

Decided per package. **Nothing is deleted without being tagged first**
(`git tag pre-rescope-2026-10-03`), so the drafts' implementation stays
recoverable for the thesis design-space chapter.

| Path | Disposition | Reason |
|---|---|---|
| `pkg/signals/energy_store.go` | **KEEP** | Thread-safe EnergyStore with Welford/EWMA. Genuinely reusable, independent of the refuted model. |
| `pkg/metrics/prometheus_exporter.go` | **KEEP** | Exporter is orthogonal to the scoring question. |
| `pkg/plugins/filter/slo_constraint_filter.go` | **KEEP the concept, port it** | Epsilon-constraint SLO filtering is sound and matches how the upstream router composes filters. |
| `pkg/plugins/scorer/energy_aware_scorer.go` | **REWRITE from scratch** | Encodes TDP-proxy scoring and tunable weights. Refuted by our own measurements. |
| `pkg/adaptive/weight_controller.go` | **QUARANTINE** | Schmitt-trigger adaptive weights. A mechanism with no measured basis; thesis design-space only. |
| `pkg/plugins/scorer/carbon_intensity_scorer.go` | **QUARANTINE** | Carbon is collinear with energy within one cluster. |
| `pkg/signals/sci_calculator.go` | **QUARANTINE** | SCI demoted to an optional reporting metric, not a contribution. |
| `pkg/plugins/scorer/kv_cache_transfer_scorer.go` | **QUARANTINE** | The cache-versus-energy angle was disproved (metric artifact). Revisit only with matched prompt lengths. |
| `pkg/plugins/scorer/rdma_locality_scorer.go` | **QUARANTINE** | Out of scope. |
| `pkg/plugins/filter/thermal_filter.go` | **QUARANTINE** | No measured basis; thermal headroom was never shown to bind. |
| `pkg/plugins/filter/energy_budget_filter.go` | **QUARANTINE** | Unvalidated. |
| `pkg/ebpf/` | **QUARANTINE, and note the contradiction** | A kernel-level eBPF token tracker **requires privilege**, which contradicts the paper's central "no privileged control" framing. Shipping both in one artifact hands a reviewer an inconsistency. |
| `pkg/slurm/spank_adapter.go` | **QUARANTINE, same contradiction** | SPANK plugins are installed by cluster admins. Same problem as eBPF. |
| `pkg/ray/autoscaler_policy.go` | **QUARANTINE** | Autoscaling demoted; not reachable on a shared Slurm cluster. |
| `pkg/simulation/e2e_simulation_test.go` | **DELETE after tagging** | 390 lines of simulated end-to-end evaluation. The user's instruction is explicit: no simulation, because it is not real. Keeping it invites its numbers back into the paper. |
| `pkg/config/gie_adapter.go` | **REPLACE** | Targets GIE v1.5.0. The plan targets llm-d-router. |
| `upstream-port/` | **DELETE after tagging** | Does not build (`scheduling.Metrics` removed upstream, 4-arg `Score`). Dead weight that has already caused one false "100% API compatible" claim. |

**New code to write, and only this:**

```
cmd/energy-scorer/main.go          out-of-tree module importing llm-d-router's
                                   cmd/epp/runner, registering our plugin
pkg/scorer/activation.go           argmin over (active GPU-seconds + activation
                                   penalty), behind the existing SLO filter
pkg/scorer/activation_test.go      table tests against recorded attribute
                                   fixtures captured from real endpoints
```

The scorer is a **scheduling** rule, not a power model: prefer endpoints
already serving; penalise waking an idle endpoint by the measured activation
step; never model marginal power, because the measured slope is negative.

---

## 3. What the measurements established

From `experiments/h1-2026-10-03-frnt109/` (job 12303088, pinned, exclusive,
5 trials, trial 1 discarded as warm-up, sub-percent CIs):

| Fact | Value | Status |
|---|---|---|
| Active power across 32x load | 187-204 W, near-constant | solid |
| Throughput scaling | 20.7x | solid |
| `J/token = P_active / throughput` | falls 21.2x | solid |
| Activation step (resident-idle to serving) | **+149.64 W** | solid, and carries the whole routing argument |
| Marginal power per request | RTX 6000: negative slope. A30: +0.357 W/req | **architecture-dependent** (see 3.1); do not assume a positive term |
| Idle floor | 54.33 W = 27% of peak-load power | solid |
| Prefix caching | 2.6x better J/total-token, 1.32x more requests | the hypothesised conflict was a metric artifact |
| Cross-node offset, identical model and driver | ~6% at every level, 1.7x in bare idle | needs within-node design |

**Replication honesty:** the characterisation itself is replication.
2608.28044 (IISWC 2026) already published the fixed-plus-marginal decomposition
on H100/H200. Ours is calibration for our system, never a contribution.

---

### 3.1 Second architecture (A30, job 12303200) — three corrections

Run on `frnt140`, **same driver 610.43.02** as the RTX 6000 run so GPU model is
isolated from driver. Full write-up:
`experiments/h1-2026-10-03-frnt140-a30/README.md`.

**(a) "H1 is refuted" was too broad.** The linear model `P = P_idle + k_b*b`
fits the A30 at **R^2 = 0.85** (max residual 4.1 W) with a *positive* slope,
against **R^2 = 0.17** and a *negative* slope on the RTX 6000. The model form is
an architecture-dependent empirical question. That is a better claim than
either "it works" or "it is refuted", and it still forbids a scorer that
assumes a positive marginal-power term, because on one of two architectures
measured that term is negative.

**(b) The A30 Pareto-dominates the RTX 6000, which reshapes Stage 2.** Same
driver, model and workload: the A30 uses **2.32x less energy per token** at
c=32 (0.0317 vs 0.0735 J/token, and 0.43-0.51x across every level) while also
delivering **1.81x the throughput** and **1.82x lower p95 latency**, on a 165 W
limit against 250 W.

This is dominance, not a trade-off. Consequence the plan did not anticipate:
if one GPU type is better on both energy and latency, energy-aware routing
degenerates to "prefer the A30s" whenever any are free, and an oracle will
simply pack A30 first. **The interesting regime is where the dominant hardware
is saturated or SLO-bound, so the Stage 2 trace replay must be designed to
reach that regime** or it will measure something trivially true. Added to the
Stage 2 exit criteria.

**(c) The activation penalty must be per-architecture.** The cost of holding a
model resident differs by **17x**:

| | RTX 6000 | A30 |
|---|---|---|
| Bare idle | 13.10 W | 25.49 W |
| Idle, model resident | 54.33 W | 27.87 W |
| **Model-resident overhead** | **+41.2 W** | **+2.4 W** |
| Activation step to c=1 | +149.64 W | +116.58 W |
| Idle floor, share of peak | 27% | 18% |

Note the inversion: the A30 draws more power doing nothing, yet far less
holding a model. So "avoid waking idle GPUs" is a strong lever on the RTX 6000
and a weak one on the A30, and a single global activation constant would be
wrong on both.

**What reproduced unchanged:** the warm-up transient (trial 1 low at every
level on both architectures, always outside the others' interval — now a
protocol requirement rather than a judgement call), and the prefix-cache metric
artifact (per total token, shared prefix is 2.5x better on A30 against 2.6x on
the RTX 6000, with 1.25x more requests completed).

### 3.2 Stage 1 complete: four configurations, two further findings

Full table in `experiments/STAGE1-SUMMARY.md`. Run D (7B) shares GPU UUID
`GPU-7fae90e9-...` with run A (1.5B), so model size was the only variable.

| | RTX 6000 1.5B | A30 1.5B | L4 1.5B | RTX 6000 7B |
|---|---|---|---|---|
| idle, model resident | 54.33 W | 27.87 W | 27.46 W | **54.87 W** |
| activation step | +149.6 W | +116.6 W | +44.4 W | +168.0 W |
| J/token at c=32 | 0.0735 | **0.0317** | 0.0351 | 0.2992 |
| tok/s at c=32 | 2704 | **4908** | 2048 | 723 |
| p95 at c=32 | 1.526 s | **0.840 s** | 2.008 s | 5.704 s |
| linear-model `R^2` | 0.17 | **0.85** | 0.14 | 0.20 |

**(d) Holding a model costs the same regardless of its size.** Same die:
54.33 W resident at 1.5B against 54.87 W at 7B - **1% apart for a 4.9x larger
model** - with the activation step rising only 149.6 to 168.0 W. So the idle
floor is a property of the GPU, not of what is loaded on it. **You cannot cut
idle power by keeping a smaller model resident**, which removes a whole class
of routing ideas before any code was written for them.

**(e) Energy per token scales sub-linearly with parameters.** 4.9x the model
costs 3.74-4.21x the energy per token, stable across all six load levels, while
throughput and p95 both move 3.74x. The penalty lands on latency and
throughput, not on disproportionate energy.

**The power-model question is now settled as a hardware property.** Turing's
non-monotonic shape appears at *both* model sizes on the same die. Across four
configurations the linear model is refuted three times - negative slope on
Turing at 1.5B and 7B, zero slope on the power-capped L4 - and holds only on
the A30 at `R^2` 0.85.

### 3.3 The project's central difficulty, stated plainly

The A30 Pareto-dominates all three other configurations at c=32: better energy
**and** throughput **and** latency simultaneously. That is dominance, not a
trade-off, so **energy-aware routing on this cluster degenerates to "prefer the
A30s" whenever any are free**, which is almost trivially correct and not worth
a paper.

Therefore **the research question lives entirely in the saturated regime**,
where the dominant hardware is full and a policy must choose among the
remainder under an SLO. Stage 2 measured is built to reach that regime, and the
honest possibility - which must be stated in the thesis either way - is that
there is no useful headroom once it does.

**The one hopeful counterexample is the L4.** It reaches nearly A30 efficiency
(0.0351 against 0.0317 J/token) on a **72 W** budget rather than 165 W, at 2.4x
the latency. A fleet of many L4s under a loose SLO is the configuration in
which an energy-aware policy could beat packing outright. Frontenac has exactly
two L4s, so this is a limitation to name rather than an experiment we can run
at scale - and it is the strongest argument for the CAC power-limit request,
which would let us synthesise the same effect on RTX 6000s at 150 W.

## 4. Measurement protocol, mandatory

Non-negotiable, because three variables were found to be non-uniform *within*
one cluster (`experiments/instruments-2026-10-03/`):

1. **Pin the node** (`-w`) and take it **`--exclusive`**. Not `-C` alone:
   driver version varies between nodes of the same GPU model.
2. **Record per run** in `instruments.txt`: GPU model and UUIDs, driver
   version, kernel, `RmProfilingAdminOnly`, power-limit range, node features,
   and a co-tenancy snapshot. Already implemented in `h1_sweep.sbatch`.
3. **Discard trial 1** as a warm-up transient, or lengthen warm-up and prove
   stationarity first.
4. **Compare within a node**, or treat node as an explicit blocking factor.
5. **NVML is the measurement source.** DCGM energy (field **156**, mJ) and
   power (155) work unprivileged and may serve as a cross-check, but DCGM reads
   the same NVML counter, so it is not independent. Nothing may depend on DCGM
   profiling fields: they are denied on 13 of 15 nodes surveyed.
6. **Randomise trial order with a recorded seed.** Include a **random-routing
   negative control** in every policy comparison; if the harness cannot
   separate it from the good policy, the measurement is not sensitive enough to
   support any claim.
7. **The load generator is an instrument and is verified like one.** Every cell
   records offered rate, **achieved rate**, rate fidelity, and dispatch-delay
   percentiles. A cell whose dispatch delay p99 exceeds 5% of the SLO is marked
   `client_limited` and the job aborts: the generator fell behind its own
   arrival schedule, so the offered rate is fiction. A shortfall in completions
   with *small* dispatch delay is marked `server_saturated` and is a valid data
   point, because that is genuine overload. These two are separated
   deliberately - completion rate alone cannot distinguish them, and only the
   first invalidates a result.
8. **Offered load is bounded by measured capacity, never by an estimate.** Load
   levels come from the Stage 1 curve for the GPU type and model actually being
   served. If no matching curve exists, the job refuses to run.
9. **Cells are sized by window length, not request count**, so every load
   level gets the same measurement window and all of them sit far above the
   measured counter floor.

Items 7 to 9 exist because job 12303327 violated all three and produced a
clean, complete, entirely invalid 8-GPU policy comparison. The energy
instruments were all verified; the thing feeding them was not, so the gate
passed and the result looked publishable. The generalisation: **a measurement
pipeline must verify the apparatus that generates the load, not only the
apparatus that observes it.**

---

## 5. Metrics, fixed in advance

Because we proved that two defensible denominators can invert a ranking, the
primary metric is declared now and not chosen after seeing results.

- **Primary: energy per SLO-satisfied request** (joules per request that met
  its TTFT/TPOT target). This is the only metric that cannot be gamed by
  trading latency for energy or by processing more prompt tokens.
- **Secondary, both always reported:** J per generated token (user-facing cost)
  and J per total token processed (system efficiency).
- **Mechanism:** active GPU-seconds, and count of activation events.
- **Tail:** p95 and p99 TTFT and TPOT, plus SLO attainment rate.
- EDP may appear as a summary, never as the sole headline.

---

### 5.1 What to measure, grounded in the literature rather than invented

The question "which factors should we even measure?" was open and being
answered by intuition. Researched 2026-10-03; the field has a settled answer,
and we were missing part of it.

**The convention.** Three operational metrics define LLM serving: **TTFT**
(time to first token, prefill-dominated), **TPOT / ITL** (time per output token
or inter-token latency, decode-dominated), and **goodput** (completed requests
per second that also meet their SLO). The llm-d sustainability agenda paper
(2609.05565) - the same work that names our research gap - specifies the
reporting set for energy-aware serving: **SLO-goodput per joule**, accompanied
by TTFT, TPOT/ITL, P50/P95/P99 end-to-end latency, request success rate, cache
hit rate, input/output token throughput, accelerator utilisation and power.
Following that set makes positioning against them straightforward.

**The defect this exposed.** Our harness sent `stream: false`, so it could only
time end-to-end latency - **TTFT and TPOT were unmeasurable**. For an SLO-based
study that is disqualifying, because TTFT and TPOT are precisely the two
dimensions a routing policy trades against each other, and a single end-to-end
number hides the trade. Fixed: the harness now streams and records per-token
timestamps.

**Metric set now collected per policy cell:**

| Class | Metrics |
|---|---|
| Energy | J/request, J/generated-token, J/token-processed, **goodput per joule** |
| Latency, prefill | TTFT p50 / p95 / p99, mean |
| Latency, decode | TPOT mean, **ITL p50 / p95 / p99 and max** |
| Latency, end-to-end | p50 / p95 / p99 |
| Service | SLO attainment, goodput (req/s meeting SLO), errors |
| Mechanism | activation count per endpoint, per-GPU energy split |

**Why ITL max and p99, not just mean TPOT.** "On Evaluating Performance of LLM
Inference Serving Systems" (arXiv 2507.09019, Agrawal et al., 2025) catalogues
evaluation anti-patterns in three classes - baseline fairness, evaluation
setup, and **metric design**, where normalisations "obscure generation stalls
and variability in token generation". A mean TPOT can look healthy while a
policy stalls generation periodically. Recording the ITL distribution and
maximum is the defence, and it is a direct requirement from that paper.

**The limit we must state, not hide.** MLPerf Power - the field's gold standard
- measures **at the wall** with a SPEC PTDaemon-certified analyser at under 1%
AC uncertainty, dividing integrated system power by the number of inferences.
We measure **GPU-package energy only**, which excludes CPU, DRAM, fans and PSU
losses, so our joules are a *subset* of system energy and are **not comparable
to an MLPerf Power figure**. Two consequences:

1. Every energy number we publish must be labelled **GPU-package energy**, not
   system energy, with the exclusions listed explicitly.
2. This is the strongest argument yet for the **IPMI** request. Node-level
   energy is the closest thing to the MLPerf methodology available on this
   cluster, and the only measurement that would let us state a system-level
   figure at all. It is promoted from "useful independent check" to "the only
   route to a comparable number".

**Anti-pattern checklist, adopted as a requirement** (from 2507.09019):
isolate the algorithmic change from engineering effort; use workloads
representative of production rather than convenient ones; never normalise in a
way that hides stalls or variance. Our concrete answers are, respectively, the
random-routing negative control, the Azure trace in Stage 5, and the ITL
distribution above.

**Still not measured, and worth deciding on later:** cache hit rate (available
from vLLM's own metrics endpoint), accelerator utilisation during policy runs,
and output determinism across endpoints. The first two are cheap scrapes of
`/metrics`; the third matters only if a reviewer questions whether routing
changes answers, which it should not, since every endpoint serves the same
model at temperature 0.

## 6. Step-by-step path, with gates

| Stage | Work | Exit criterion | Est. |
|---|---|---|---|
| **0. Rescope the code** | **DONE 2026-10-03** (commit `baef80d`). Tagged `pre-rescope-2026-10-03`; moved nine components to `legacy/` with its own go.mod; root build clean, all tests pass. The out-of-tree llm-d module is deferred to Stage 4, because Stage 2 no longer needs it. | met | done |
| **1. Characterise** | **DONE 2026-10-03** (commit `f49a179`). Four configurations: RTX 6000 / A30 / L4 at 1.5B, plus 7B on the same RTX 6000 die. All pinned, exclusive, 5 trials, sub-percent CIs. See `experiments/STAGE1-SUMMARY.md`. A100, L40S, RTX 8000, V100 remain available and unmeasured. | met | done |
| **2. GATE: MEASURED, not modelled** | One vLLM server per GPU on a single exclusive multi-GPU node; real open-loop arrivals; the **policy lives in the load generator**, not in a plugin. Five policies measured with NVML per-device energy. Load swept through saturation of the dominant type. Scripts: `experiments/scripts/{policy_harness.py,stage2_real.sbatch}`. See 6.2. | **some policy beats SLO-aware packing on energy per SLO-satisfied request, measured, at matched SLO attainment, in the saturated regime - or STOP** and write the measurement/negative-result paper | 1 job + analysis |
| **3. Pre-register** | Commit hypotheses, primary metric, policies, trial count from a power analysis on measured variance, and the analysis script, timestamped in-repo before any comparative run | pre-registration committed and pushed | 2 d |
| **4. Build the scorer** | Out-of-tree module against llm-d-router, plus `pkg/scorer/` and tests behind the SLO filter. **Implement ONLY a rule Stage 2 measured as a winner** - not `energy_greedy` as originally specified, which the modelled gate already showed is indistinguishable from packing. | module registers against current llm-d-router; unit tests pass against recorded fixtures; p99 scorer CPU time recorded | 2 wk |
| **5. The real experiment** | One node, exclusive, open-loop Poisson from the trace, >=5 trials, 5 arms: stock llm-d, round-robin, SLO-aware packing, ours, ours-without-activation-term, plus random control | all metrics in section 5 with 95% CIs | 2-3 wk |
| **6. Secondary results** | Per-die heterogeneity (section 13.5 design); matched-prompt-length cache experiment if time allows | either a measured effect or a clean null with the within-die control | 1 wk |
| **7. Write and upstream** | Thesis first, paper distilled from the same experiments; submit the artifact PR regardless of outcome | PR open; thesis chapter draft | 3-4 wk |

**Stage 2 is the honest decision point.** With active power near-constant and
the marginal term at zero or negative, routing-only savings may be small once
SLO constraints bind. Finding that out costs one job; finding it out after
building costs two months.

### 6.0 Telemetry is mandatory, in two passes

Every Stage 2+ job runs three phases and cannot skip any of them.

| Phase | Script | Contents |
|---|---|---|
| **Pass 0** gate | `telemetry_check.sh` | Verifies NVML energy counter + power, `nvidia-smi` provenance, and DCGM fields **156**/**155**. **Aborts the job** if any is missing, so numbers can never come from a degraded instrument set. Records kernel-gated sources as data. |
| **Pass A** measurement | `policy_harness.py` | The energy numbers. **No profiling tool runs here.** |
| **Pass B** mechanism | `mechanism_pass.sh` | CUPTI tracing, CUPTI counter probe, Nsight Systems trace + `nsys stats`, Nsight Compute, DCGM DCP fields 1002/1005, `nvidia-smi` high-rate sampling. |

**Why two passes rather than everything at once.** Two measured reasons, not
preference:

1. **Profiling perturbs what it measures.** Nsight Compute serialises kernels
   and can slow them by an order of magnitude; CUPTI counter collection adds
   overhead. Energy recorded while profiling is not the energy of normal
   serving, so mixing them would invalidate the headline figures.
2. **Counter access is denied on most of this cluster.**
   `RmProfilingAdminOnly=1` on **13 of 15 nodes** surveyed, where CUPTI
   counters, Nsight Compute and DCGM DCP fields return `Result: -29`. Requiring
   them everywhere would make the experiment unrunnable on 87% of Frontenac,
   including every A30 and the L4.

The split delivers full tool coverage in every job while keeping the energy
measurement clean. Where a tool is denied, the job **records the denial as a
result** rather than skipping silently - and that per-node inhomogeneity is one
of our own findings (3.1.1, 3.1.2).

What each source is actually for:

- **NVML** - the measurement. The only hardware *energy* counter, works
  unprivileged everywhere. It does **not** expose instruction counts, cache hit
  rates, warp occupancy or pipeline stalls, and we never claim otherwise.
- **DCGM 156/155** - a second reader of the same NVML counter (verified: its
  value fell between two NVML readings taken either side of it), plus the
  integration surface upstream llm-d scrapes. Not an independent sensor.
- **nvidia-smi** - provenance and high-rate sampling. It is NVML underneath.
- **CUPTI / Nsight Systems** - tracing. Answers "which kernels, in what order",
  available even where counters are denied.
- **Nsight Compute / DCGM DCP** - the actual hardware performance counters
  (SM activity, DRAM throughput, occupancy). These are what NVML cannot give,
  and they are exactly what this cluster withholds on 13 of 15 nodes.
- **IPMI** - node-level energy, the only genuinely *independent* check on the
  GPU counter. Device exists, root-only; pending the CAC request.

#### 6.0.1 The telemetry must not cost performance, and that is verified

Mandatory instrumentation is only acceptable if it is free. Three design rules
and one measured check enforce that.

**Rule 1 - Pass A carries no profiling tool.** The energy measurement runs with
NVML counter reads (two per window), a 4 Hz power poll, and a DCGM host engine
idle in the background. No CUDA interception, no kernel serialisation, no
tracing. Nothing in that set touches the critical path of a request.

**Rule 2 - Pass B runs strictly after Pass A, with a 60 s settle.** The
profiling tools that *do* perturb (Nsight Compute serialises kernels; CUPTI
counter collection adds overhead) cannot overlap the measurement even
accidentally, because they start only once every policy cell has completed.

**Rule 3 - no tool may be promoted into Pass A to "get better coverage".** If a
source cannot be read without perturbation, it belongs in Pass B or is recorded
as denied. Coverage never outranks validity.

**The measured check - a mandatory control arm.** Every Stage 2 job re-runs
`slo_packing` at the busiest load with the power poll **disabled**
(`--poll-interval 0`, counter reads only) and compares:

```
perturbation_check.py  pass-a.json  control-counteronly.json
  full telemetry : X J/req   poll=0.25s
  counter only   : Y J/req   poll=0s
  energy difference / p95 difference / completed difference
```

**Acceptance rule:** if the energy difference is under 1%, the instrumentation
is free and Pass A stands unqualified. If it exceeds 1%, **the telemetry is
trimmed and the job re-run** - the result is not accepted with a caveat. That
ordering matters: we fix the instrument rather than annotate the number.

**Cost accounting, for the record:**

| Phase | Added cost | On the measurement path? |
|---|---|---|
| Pass 0 gate | ~30 s once per job | no, runs before the servers take load |
| Pass A telemetry | 2 counter reads per window + 4 Hz poll | yes, and verified immaterial by the control |
| Pass A-control | one extra policy cell | no, it *is* the check |
| 60 s settle | 60 s once | no |
| Pass B | minutes, deliberately perturbing | no, strictly after all measurement |

So the mandatory-everything requirement is met without trading away the
fidelity of the numbers or the speed of the serving path. The only cost is
wall-clock time on an exclusive node we hold anyway, which is the cheapest
resource in this project.

#### 6.0.2 Could a better tool replace NVML? No - for energy it is the ceiling

Asked directly, and worth recording because NVML's well-known limitations are
about a *different* quantity than the one we measure.

| Tool | Measures energy? | Verdict for our use |
|---|---|---|
| **NVML** `nvmlDeviceGetTotalEnergyConsumption` | **Yes - hardware counter integrated in GPU firmware** | The only true energy counter. Irreplaceable. |
| DCGM field 156 | Yes, but it **is** that same counter | Verified: its reading fell between two NVML readings taken either side. A second *reader*, not a second *sensor*. Keep it for the upstream integration surface, not for accuracy. |
| CUPTI | **No energy counter at all** | Time and kernel counters. A downgrade for joules. |
| Nsight Systems | Only by sampling NVML power | Strictly worse than reading the counter, plus overhead. |
| Nsight Compute | No | Kernel counters, serialises execution. |
| `nvidia-smi` | Yes - it *is* NVML | Same numbers, worse interface. Keep for provenance. |
| **IPMI** | Yes, node-level, **genuinely independent** | The only real cross-check. Root-only here, hence the CAC ask. |

NVML's real limitations - no instruction counts, cache hit rates, warp
occupancy or pipeline stalls - are about *explaining* power, not *quantifying
energy*. Those live in Pass B, where CUPTI and Nsight belong. For joules there
is nothing better to switch to.

**The limitation that does bite, and was unaddressed.** The counter's own
sampling behaviour. The SC24 result we cite (arXiv 2312.02741) found A100/H100
sample power only ~25% of the time, so a short-window counter read can
quantise. Our 75 s windows should make this immaterial - but we had never
measured it on our GPUs, which is validity defect **S2**, open since the first
review. "Should" is not a measurement.

`experiments/scripts/counter_characterisation.sbatch` closes S2 per GPU type:

1. **Counter update period and quantum**, from 1 ms polling - establishes the
   floor on trustworthy window length.
2. **Three estimates of the same energy** over identical load: counter delta,
   integral of instantaneous power, and integral of the firmware-averaged
   field `NVML_FI_DEV_POWER_AVERAGE` - a less noisy source than
   `nvmlDeviceGetPowerUsage` that we were not using.
3. **The same under a 2 Hz square wave**, where instantaneous sampling should
   alias and the counter should win. If it does, that is direct evidence the
   protocol picked the right instrument.
4. **The shortest window agreeing with a 60 s reference to within 1%**, which
   becomes an enforced protocol minimum rather than a guess.

Run it once per GPU type before Stage 5. It is its own job, so it perturbs
nothing, and it converts "we trust the counter" into "we measured the counter".

### 6.1 Thesis and paper split

They fail for opposite reasons, so material is routed rather than duplicated.
**Thesis first; the paper is distilled from the same experiments afterwards.**

| | Thesis | Paper |
|---|---|---|
| Question | descriptive: can it be built, what does it cost? | comparative: does it beat SLO-aware packing? |
| Design space (carbon, SCI, thermal, KV-cache, adaptive weights) | Chapter 3, labelled **implemented-but-withdrawn** with the measured reason, drawing on tag `pre-rescope-2026-10-03` | out |
| Implementation and conformance | Chapter 4 | half a page plus the artifact |
| Measurements | Chapter 5, primary evidence | the whole paper |
| Deployment heterogeneity (driver, permission, idle power) | Chapter 5 section | a named secondary contribution |
| Risk if Stage 2 fails | none: reports a negative result, which the thesis can absorb | rescoped to a measurement paper |

The quarantined packages are an asset for the thesis and a liability for the
paper. That asymmetry is why they are tagged rather than deleted.

### 6.2 Why Stage 2 is measured rather than modelled

The gate was originally an offline replay over the measured curves, and it ran
(`experiments/stage2-gate-2026-10-03/`). It is now **retired in favour of a
measured run**, for a reason worth recording:

**You do not need the llm-d plugin to test a placement rule. Put the rule in
the load generator.** One vLLM server per GPU on an exclusive node, real
open-loop arrivals, and the client picks the endpoint by policy. That gives
real queueing, real continuous batching, real contention and real joules from
the per-device NVML counter, for about 100 lines of Python instead of a Go
plugin against an upstream API that churns. It costs roughly one job on an
8-GPU node, and Frontenac has four: `frnt155` (8x RTX 6000) and
`frnt154`/`frnt190`/`frnt191` (8x A100).

So the measured version is both cheaper and stronger. Only a rule that wins
there is worth writing Go for, which is why Stage 4's scope now depends on
Stage 2's result.

**What still cannot be measured:** the lower bound. A bound is a computation by
definition - "what is the cheapest this work could possibly be". But it is
computed *from the measured curves*, not from modelled physics, which is what
any paper would do. So: **policies measured, bound computed from measurements.
No simulation enters the result.**

**What the modelled gate earned before retirement**, both of which now shape
the measured design:

1. It located saturation (~77 req/s for the A30s alone, ~161 req/s for a 2+4
   fleet), so the measured run knows which load levels matter.
2. It proved that comparing joules-per-SLO-request across policies at
   *different* SLO attainment is invalid - its own first version "passed" by
   36% purely because the winner served 41% of its SLO against packing's 22%.
   Hence the measured run calibrates the SLO from the node's own
   single-request latency and compares only at matched attainment.

**Policies measured in Stage 2:** `round_robin`, `least_loaded`,
`slo_packing` (the baseline to beat), `energy_greedy` (the rule this plan
originally proposed), and `energy_consolidate` (new - prefer an already-busy
endpoint of the most efficient type and wake an idle one only when no busy
endpoint is SLO-feasible). The last exists because the modelled gate showed
that choosing by instantaneous J/token converges to the same decisions as
packing; beating packing requires doing something packing cannot.

**Execution order:** a 2-GPU smoke run on `frnt140` first (~20 min, catches
launcher bugs cheaply), then the real 8-GPU run on `frnt155`.

---


## 7. Venues

- **HotCarbon** (~5 pp) — best fit: integration, constrained setting, and the
  deployment-heterogeneity finding. **Verify dates at hotcarbon.org/cfp
  directly**; a search on 2026-10-03 returned inconsistent dates and I will not
  assert them.
- **ACM SIGENERGY / Workshop on Sustainable Computer Systems** — same community.
- **IISWC** — the right home if Stage 2 fails and this becomes a
  characterisation paper; 2608.28044 landed there.
- **EuroMLSys / MLSys** — short systems papers.
- **Hedge:** contribute the energy observation contract to **both** llm-d and
  vLLM semantic-router (issue #2332, whose contract already names "energy/power
  evidence and its measured/modeled provenance"). Two production routers are
  circling this gap; contributing to both is a timestamp and insurance.

### 7.1 Which research skills to run, and when

The ARS pipeline is expensive and its expensive stages are worthless before
the evidence settles. Sequence:

| When | Skill / mode | Why now |
|---|---|---|
| Now | `deep-research` in `lit-review` mode | Rebuild related work against 2026 sources. The current related work predates Festina, the two agenda papers, GreenServ and the IISWC characterisation. |
| Now | `fact-check` on every identifier before it enters a bibliography | One figure was already recorded wrongly (2604.04745). Re-verify at submission time too. |
| After Stage 2 | `deep-research` in `socratic` or `full` | Only after the gate does the hypothesis stop moving. If the gate fails, the research question changes, and anything written before is wasted. |
| After Stage 5 | `academic-research-skills:ars-full` | The report compiler and editor-in-chief passes pay for themselves only over a complete evidence base. Running them now would polish prose over claims that cannot be defended. |
| Before Stage 5 | `academic-paper` preregistration template | Stage 3 output; must be timestamped in-repo before the comparative runs. |
| At write-up | `academic-paper` with the handoff materials | RQ brief, methodology blueprint, bibliography, synthesis. |

Do **not** run `ars-full` yet. That decision was already made in
`draft-assessment-2026-10.md` section 6 and it still holds.

---

## 8. Threats to validity, and which are still open

| # | Threat | Status |
|---|---|---|
| B1 | Hardware varies between runs | **closed** by `-w` pinning; extended to driver version |
| B2 | **No baselines** | **OPEN — the single blocking gap.** Stage 2 then 5. |
| B3 | Underpowered, one model, one output length, closed-loop | partly closed (5 trials, CIs); **open-loop discharged 2026-10-04, see N4**; model size and output length remain |
| B4 | Co-tenancy | **closed** by `--exclusive` with a recorded guard |
| S1 | Prefix-cache result backwards | **closed** — metric artifact, resolved |
| S2 | No sensor characterisation | **addressed**: `counter_characterisation.sbatch` measures update period, quantum, counter-vs-integrated agreement, aliasing under square-wave load, and the minimum trustworthy window, per GPU type. Run before Stage 5. |
| S3 | Activation cost imprecisely defined | now operational: power at c=1 minus power at c=0 with model resident |
| S4 | Per-request attribution under batching | open, stated as an assumption |
| **N1** | **"No privileged control" is partly an artifact of our account** | open. Mitigation: argue from the measured permission non-uniformity that a tenant genuinely cannot rely on privilege. |
| **N2** | Effect size may be too small to matter | open. This is what Stage 2 exists to settle. |
| **N4** | **Load generator was not open-loop** | **closed 2026-10-04.** `one_request()` issued blocking urllib through the default asyncio executor, capping in-flight requests at `min(32, cpu_count+4)` = 32 on a 32-core node, so offered load above ~27 req/s was fiction. Job 12303327's entire 8-GPU, 5-policy, 4-load sweep was client-limited and is discarded. Fixed with httpx async streaming; the generator is now gated as an instrument in Pass 0, and every cell records `achieved_rate_rps` and `rate_fidelity`. This is B3's "open-loop remains" clause, discharged. |
| **N5** | **TTFT was measured after the client's own queue wait** | **closed 2026-10-04.** TTFT was timed inside the worker thread, so it excluded dispatch delay and read 0.028 s while end-to-end p99 was 23 s. The SLO argument leans on TTFT, so the misleading number was the reassuring one. TTFT and latency are now timed from the scheduled arrival; `ttft_from_send` keeps the server-side view and `send_delay` is the gap. |
| **N10** | **The router extrapolated its energy and latency model** | **closed 2026-10-04.** `interp` clamped above the top measured concurrency level. Stage 1 stopped at 32; job 12303355 ran at ~66 in flight per endpoint. So `_jtok` returned `power(32)/tok_s(32)` = 0.0784 J/token for every endpoint at c >= 32 - all tied, `min()` fell through to index order, and `energy_greedy` was bin-packing by endpoint index with no energy signal. `_proj_latency` predicted 1.99 s at c=42 where measured p95 was 30.97 s, optimistic by 10-15x. `interp` now returns None above the measured range, the router treats that as infeasible, and every cell reports `router_out_of_range`. |
| **N11** | **Curve selection picked the worst available curve per GPU type** | **closed 2026-10-04.** First match from a lexically sorted glob means the oldest wins. The A30 curve in use was `h1-12302437` with `levels=1,4` - two points - while `h1-12303200` has six. It did not affect the homogeneous RTX 6000 run but would corrupt the heterogeneous comparison the research question is about, and it would have silently discarded the extended 128-level curve as a duplicate of the one it replaces. Selection is now by widest measured coverage, tie-broken on newest job. |
| **N12** | **An instrument probe tested the wrong thing** | **closed 2026-10-04.** `h1_sweep.sbatch` chose its Python with `python3 -c "import pynvml"`. pynvml imports from `~/.local` even when `libnvidia-ml.so.1` is unreachable, so job 12303357 passed the probe and then died on `nvmlInit`. The probe now performs import, `nvmlInit` and one counter read, and falls back to the container Python. |
| **N9** | Deep-overload cells may reflect **CPU contention, not GPU saturation** | open. The generator reached 9.8 of the node's 32 cores at 590 req/s while sharing the node with 8 vLLM servers, so server-side degradation at the top of the range is partly confounded. In the measurement region (240-360 req/s) it is 4.8-6.2 cores. Mitigations if the top cells are ever load-bearing: pin generator and servers to disjoint cores, or move the generator to a second node. |
| **N7** | **RAPL CPU+DRAM includes the load generator itself** | **open, now quantified.** The generator runs on the same node as the servers, so its CPU time is inside the RAPL package energy. Sharding the generator across processes makes this larger. GPU-package energy, the primary metric, is unaffected. Every cell now records `generator_cpu_s` and `generator_cpu_cores_mean`, so the contamination is measured rather than unknown. Any CPU/DRAM figure must be reported with that caveat, or measured with the generator on a separate node. |
| **N8** | Prompt mix was not reproducible from the seed | **closed 2026-10-04.** Prompt length came from an rng shared by all coroutines, so the draw order depended on asyncio scheduling and the seed did not reproduce a workload. Now derived from (seed, request index), identical under any worker count or interleaving. |
| **N6** | Measurement window shrank as offered load rose | **closed 2026-10-04.** A fixed 600-request cell is a 12 s window at 50 req/s but 4.4 s at 137.5 req/s, so the high-load cells that the research question is about had the shortest energy windows. Cells are now sized by `DURATION` (default 60 s), and the counter-only control uses the same window as the Pass A cell it is compared against. |
| **N3** | Artifact self-contradiction: `pkg/ebpf` and SPANK require privilege | closed by quarantining both. |

---

## 9. Research integrity

- AI assistance was substantial (measurement scripts, analysis, plan drafting,
  literature verification) and must be disclosed in any submission.
- Three errors were caught and corrected on 2026-10-03 and are left visible in
  the repository rather than edited away: "DCGM is unusable without root"
  (wrong, bad `dcgmi` argument order plus a single-node generalisation), "the
  permissive node is behind on patching" (refuted by the cluster survey), and a
  misrecorded figure for 2604.04745 (we had "53% to 96%"; the paper says 19.7%
  of time and 10.7% of energy). Keeping the corrections visible is what makes
  the negative results credible.
- All arXiv identifiers were verified against the live record on 2026-10-03.
  Re-verify before any bibliography is finalised.
- No human subjects, no dual-use concern.

---


## 10. Decision log

Kept so that reversals are visible and so the same ground is not re-litigated.

| Date | Decision or correction | Reason |
|---|---|---|
| 2026-09 | Out-of-tree plugin module, no fork | upstream llm-d-router changes too fast to maintain a fork |
| 2026-10-03 | H1's linear power model **refuted** | measured slope negative; power non-monotonic in concurrency |
| 2026-10-03 | Marginal-energy term and its ratios **withdrawn** | fitting noise around a flat curve; two runs gave 0.46 W and 0.24 W |
| 2026-10-03 | Cache-versus-energy conflict **withdrawn** | metric artifact; per total token, caching helps energy and goodput together |
| 2026-10-03 | "DCGM unusable without root" **retracted** | wrong: bad `dcgmi` argument order plus a single-node generalisation |
| 2026-10-03 | "Permissive node is behind on patching" **refuted** | cluster survey: `frnt110` is permissive on the same kernel five restricted nodes run |
| 2026-10-03 | 2604.04745 figures **corrected** | we had "53% to 96%"; paper says 19.7% of time, 10.7% of energy |
| 2026-10-03 | No simulation, no cloud rental | user instruction plus the measured inventory: 3x 8-GPU A100 nodes exist |
| 2026-10-03 | Primary metric fixed before results | two denominators were shown to invert a ranking |
| 2026-10-03 | Code rescoped away from the drafts' design | plan-code divergence audit, section 0 |
| 2026-10-03 | Claim restated as **replica** selection | most 2026 energy-routing work is model selection |
| 2026-10-03 | Stage 0 and Stage 1 **complete** | `legacy/` rescope committed; four measured configurations |
| 2026-10-03 | Stage 2 changed from **modelled to measured** | the real version costs one job on an 8-GPU node; put the policy in the load generator, not the plugin |
| 2026-10-03 | Modelled gate **retired, not published** | it located saturation and proved attainment-mismatched comparisons are invalid, then its job was done |
| 2026-10-03 | Stage 4 scope now **conditional on Stage 2** | build only a rule measured as a winner; `energy_greedy` as specified was indistinguishable from packing |
| 2026-10-03 | Idle floor is a **GPU property, not a model-size property** | 54.33 W at 1.5B vs 54.87 W at 7B on the same die; kills the smaller-resident-model idea |
| 2026-10-03 | **Verification debt cleared**: 11 of 13 works fetched | four of our own claims were wrong (2604.04745 idle figures, 2604.09048 A30 attribution, 2609.23085 "~23%", GreenServ "LinUCB") plus two usage errors on 2312.02741 |
| 2026-10-03 | **Per-request attribution claim SURVIVES**, sharpened against TokenPowerBench | they do phase attribution by tagging samples with the active stage; per-request under multiplexing is explicitly not addressed |
| 2026-10-03 | **RAPL added** for CPU+DRAM energy | TokenPowerBench pairs it with NVML; we were GPU-package only. May be root-only per CVE-2020-8694 |
| 2026-10-03 | Energy labelled **GPU-package** on all published results | MLPerf comparability |
| 2026-10-03 | **Per-request attribution - superseded by the row above** | TokenPowerBench (AAAI'26) attributes energy to prefill/decode per request; read it before Stage 3 and drop the claim if sound |
| 2026-10-03 | 2312.02741 criticises **nvidia-smi polling, not the energy counter** | so it supports our counter-over-polling choice rather than threatening it; also it is not an SC24 paper, as we had been asserting |
| 2026-10-03 | **Reference list consolidated with verification status** | 7 fetched, 6 search-sourced, 2 inherited-unverified; 2312.02741 and 2604.09048 are load-bearing and unverified, which is exactly how 2604.04745's wrong figures survived for weeks |
| 2026-10-03 | Metric set **grounded in literature**; harness switched to streaming | TTFT and TPOT were unmeasurable with stream:false; ITL distribution added per arXiv 2507.09019's metric-design anti-pattern |
| 2026-10-03 | Energy relabelled **GPU-package, not system** | MLPerf Power measures at the wall; ours excludes CPU, DRAM, fans, PSU, so it is a subset and not comparable |
| 2026-10-03 | **NVML confirmed irreplaceable for energy**; its limits are about kernel counters, not joules | DCGM 156 is the same counter; CUPTI/Nsight have no energy counter; IPMI is the only independent sensor |
| 2026-10-03 | Counter characterisation added to **close defect S2** | the SC24 ~25% sampling result was cited but never tested on our GPUs; also adds the unused firmware-averaged power field |
| 2026-10-03 | Telemetry overhead **verified, not assumed** | mandatory counter-only control arm per job; >1% difference trims the telemetry rather than caveating the result |
| 2026-10-03 | All telemetry **mandatory, split into two passes** | every tool used on real hardware every job; profiling perturbs energy, and counters are denied on 13 of 15 nodes, so they cannot share a run with the measurement |
| 2026-10-04 | **Job 12303327 discarded in full** | the 8-GPU, 5-policy, 4-load sweep completed cleanly and read as a result (`energy_consolidate` -25% J/req at matched SLO), but every cell was client-limited: 112.5 req/s offered, 26.7 achieved. Nothing in the pipeline flagged it. No number from this job appears anywhere |
| 2026-10-04 | Load generator reclassified as a **measurement instrument** | it failed silently and produced a plausible result, which is the same failure mode as a miscalibrated power sensor. It is now checked in the Pass 0 gate and the job aborts if `httpx` is missing from the image |
| 2026-10-04 | `client_limited` and `server_saturated` **separated** | completion-rate shortfall alone cannot tell a broken generator from genuine overload, and only the first invalidates a cell. Dispatch delay is purely client-side, so it is the discriminator: budget 5% of the SLO, floored at 25 ms |
| 2026-10-04 | Offered **and achieved** rate reported for every cell | a result that reports only offered load cannot be checked for this class of error at all. This is the durable fix; the thread pool was only the instance |
| 2026-10-04 | Capacity derived from the **measured Stage 1 curve**, not a tokens/s constant | the old estimate `NGPU * 2000/128` gave 125 req/s for 8x RTX 6000; measured single-GPU peak is 21.1 req/s at p95 1.53 s, so the real figure is ~169 req/s. The guess was 26% low, which would have put the swept range below the SLO knee even with a working generator. Absent a matching curve the job now refuses to run rather than invent a figure |
| 2026-10-04 | Cells sized by **window length**, not request count | equal windows across load levels, and every cell far above the measured counter floor (1.0 s A30, 0.5 s RTX 6000) |
| 2026-10-04 | ~~**SLO knee located between 67.8 and 118.6 req/s**~~ **RETRACTED same day** | job 12303350 showed attainment falling to 66% at 118.6 req/s and 2.1% at 169.5 req/s. That was not the servers: it was the single-process client's dispatch delay (p99 0.189 s and 1.97 s) inflating latency measured from scheduled arrival. The same artifact as the thread-pool ceiling, one level up, and it fooled us a second time because the number moved in the direction we expected |
| 2026-10-04 | **SLO knee is at or beyond 271 req/s**, measured with a verified generator | job 12303353, 8 worker processes, dispatch delay p99 0.001-0.007 s: attainment is 100% through 220.3 req/s and 96.2% at 271.2 req/s. The 2.0 s SLO is generous against a ~0.05 s TTFT, so the trade-off region is further out than any estimate so far suggested |
| 2026-10-04 | **SLO knee measured: between 271 and 350 req/s, and it is a cliff** | job 12303354 with a verified generator (dispatch delay p99 <= 0.042 s throughout): attainment 97.1% at 271.2 req/s, 7.6% at 350, 1.8% at 430, 0.2% at 510, 0.0% at 590. e2e p99 moved only 2.012 -> 2.225 s across the 97%-to-8% collapse |
| 2026-10-04 | **An end-to-end SLO on a fixed output length is a disguised TPOT threshold** | service time is about TTFT + 128*TPOT, so 0.049 + 128(0.0149) = 1.96 s at 271 req/s (inside the 2.0 s SLO) and 0.057 + 128(0.0161) = 2.12 s at 350 (outside). The whole distribution steps across together, so an 8% TPOT change swings attainment by 90 points. Consequence: **"matched SLO attainment" is structurally brittle in this configuration** and attainment alone says nothing about how much headroom a policy had. Cells now also report `slo_margin_p50`, `slo_margin_p95` and `frac_within_10pct_of_slo` |
| 2026-10-04 | **Goodput per joule peaks exactly at the knee** | 0.174 J^-1 at 271 req/s, falling to 0.0167 at 350 and 0.049 at 67.8. The energy-efficient SLO-respecting operating point is the knee itself, which is the regime the research question targets. Stage 2 load levels are therefore 240/271/300/330/360 req/s, bracketing it, rather than spanning decades where every cell reads 100% or 0% |
| 2026-10-04 | Energy per request **falls monotonically with load** | 20.44 J at 67.8 req/s down to 5.53 J at 271.2 req/s, goodput/J rising 0.049 to 0.174, with SLO attainment still at or near 100%. Fixed idle power amortises over more requests, so on this hardware the energy-efficient operating point is high load. Any energy-aware policy has to beat that, and consolidation is working with the same effect |
| 2026-10-04 | Generator **sharded across processes**, routing state genuinely shared | one asyncio process was measured at ~115 req/s achieved, with dispatch delay already at the budget by 67.8 req/s, so a single process cannot cover the knee. Per-token stream parsing is CPU-bound in the event loop. Critically, every policy except round_robin routes on GLOBAL in-flight counts, so the counters live in shared memory under a lock: giving each worker its own view would leave the policies running on 1/W of the picture and still producing numbers - the same silent-substitution failure as the thread pool |
| 2026-10-04 | Achieved rate **collapses** beyond the generator's ceiling | 146 req/s achieved at 169.5 offered, then 121 at 220.3, then 104 at 271.2. More concurrent connections means more event-loop work per request, so pushing harder makes the client slower. A naive sweep would read this as the servers degrading |
| 2026-10-04 | Tuple seeds for `random.Random` **are invalid on Python 3.11+** | caught locally before submission; the container runs 3.12, so it would have raised on every request |

## 11. Calendar

Anchored at 2026-10-03. Durations from section 6; dates assume part-time work
and no cluster outage.

| Stage | Target window |
|---|---|
| 0. Rescope the code | 2026-10-04 to 2026-10-07 |
| 1. Characterise (A30, L4, 7B) | 2026-10-07 to 2026-10-20 |
| 2. **GATE: offline bound** | 2026-10-20 to 2026-10-27 |
| 3. Pre-register | 2026-10-27 to 2026-10-29 |
| 4. Build the scorer | 2026-10-29 to 2026-11-12 |
| 5. The real experiment | 2026-11-12 to 2026-12-03 |
| 6. Secondary results | 2026-12-03 to 2026-12-10 |
| 7. Write and upstream | 2026-12-10 to 2027-01-07 |

Submission target depends on the venue's actual dates, which must be checked
directly rather than taken from this document. The artifact PR goes upstream
at the end of Stage 4, independent of any paper deadline, because it is both
the contribution and the timestamp.

Dependencies outside our control, all of which can move these dates: the CAC
access request (group restore, GPU association, reservations, IPMI accounting,
power-limit permission), cluster availability for `--exclusive` jobs, and
whether llm-d-router's plugin API churns again.

## 12. References, verified 2026-10-03

Verification debt cleared except two framing-only entries. Status values:
**FETCHED** = arXiv record retrieved and read this session; **SEARCH** = from a
search result only, not confirmed. The rule is that unverified counts as FAIL,
because this project has already been bitten three times.

### 12.1 The gap: our topic, named and unfilled

| ID | Work | Status | Why it matters |
|---|---|---|---|
| **2609.05565** | Sisodia, "Toward Sustainable Distributed LLM Inference: ... Energy-, Carbon-, and Cache-Aware llm-d Control Plane" (2026-09-03) | FETCHED | Design proposal, **no experiments**, names energy-aware endpoint selection as future work. Our strongest evidence the gap is real, and the source of our reporting set (5.1). |
| **2603.21354** | Chen, Liu, He et al., "The Workload-Router-Pool Architecture ... Vision Paper from the vLLM Semantic Router Project" (2026-03-22, rev 04-08) | FETCHED | Second agenda paper, 21 directions, **no measured energy**. |
| **semantic-router#2332** | "[Epic] Connect semantic routing to inference-aware backend selection" | FETCHED | **Open** epic; contract explicitly includes "energy/power evidence and its measured/modeled provenance". A second production router building this plumbing. |

### 12.2 Closest competitors

| ID | Work | Status | Relation |
|---|---|---|---|
| **2606.30391** | Wang, Rattihalli, Dhakal, Shangguan, Milojicic, "Energy-Aware Scheduling for Serverless LLM Serving on Shared GPUs" (Festina, 2026-06-29) | FETCHED | Up to **56%** energy saved, SLO within 2% - but needs MPS and frequency control, i.e. **root**. Our no-privilege clause is the distinction. |
| **2608.06188** | Bernhard, Yardimci, "Routing LLM Inference to the Cleanest Grid in Real Time" (2026-08-06) | FETCHED | Region-level carbon routing. ~51% headline is a **year-long historical replay**, stated as an upper bound; only steering ran live. |
| **2601.17551** | Ziller, Ilager, Tundo, Bartocci, Mariani, Brandic, "GreenServ: Energy-Efficient Context-Aware Dynamic Routing for Multi-Model LLM Inference" (2026-01-24, rev 02-27) | FETCHED | **Multi-armed bandit** (the abstract does **not** say LinUCB - an earlier note of ours claimed it; corrected). **16 models**, 5 tasks, RouterBench: +22% accuracy, **-31% energy vs random routing**. **Model** selection, not replica selection. |
| **2609.23085** | Siddiqui, Rojas, Yang, Cui, Shi, Chen, "Measured Joules, Learned Routes: Learning to Route for Energy-Efficient LLM Serving" (2026-09-19) | FETCHED | Routes among **different models** from a fixed candidate pool. Abstract claims an improved accuracy-energy tradeoff and a "sharp accuracy-energy phase transition", **no specific percentage** - an earlier note of ours cited "~23%"; **withdrawn as unsupported**. |
| **2605.23057** | "RequestRouter: Request-Boundary Routing for Efficient Single-GPU LLM Inference" | **SEARCH** | Intra-GPU scheduling on one A100. Framing only; verify before citing. |
| **2603.04445** | "Dynamic Model Routing and Cascading for Efficient LLM Inference: A Survey" | **SEARCH** | Related-work framing only; verify before citing. |

### 12.3 Characterisation we replicate rather than contribute

| ID | Work | Status | Relation |
|---|---|---|---|
| **2608.28044** | Vellaisamy, Lam, Blanton, Shen, "Characterization of Request and Token Energy Costs for LLM Inference Workloads on GPU Platforms" (2026-08-28, **IISWC 2026**) | FETCHED | Fixed prefill + marginal per-token decomposition, H100/H200, 7.46 to 0.72 J/token as output grows 10 to 512. **Our H1 work replicates this.** Calibration, never contribution. |
| **2512.03024** | Niu, Zhang, Li, Zhao, Wang, Wang, Chen, "TokenPowerBench: Benchmarking the Power Consumption of LLM Inference" (2025-12-02, **AAAI'26 main track**) | FETCHED | **See 12.3.1 - this one costs us a claimed contribution and offers us a method.** |
| **2604.04745** | Lei, Fernandez, Kypriotis, Skarlatos, Strubell, Sherry, Vosler, "The Energy Cost of Execution-Idle in GPU Clusters" (2026-04-06) | FETCHED, **previously misquoted by us** | Execution-idle is **19.7% of execution time, 10.7% of energy**. Our notes had said "53% to 96%", which is **not in the paper**. Our 27% idle floor is not corroborated by it. |
| **2604.09048** | Fadel Argerich, Fürst, Patiño-Martínez, "Watt Counts: Energy-Aware Benchmark for Sustainable LLM Inference on Heterogeneous GPU Architectures" (2026-04-10) | FETCHED, **previously misattributed by us** | **50 LLMs across 10 NVIDIA GPUs**, batch and server scenarios; "optimal hardware choices vary significantly across models and deployment scenarios". It does **NOT** mention the A30 or claim any GPU is unusually efficient for small/medium models - our note claiming that is **withdrawn**. The paper is still highly relevant, as independent support for our heterogeneity and A30-dominance results. |

#### 12.3.1 TokenPowerBench, read 2026-10-03: our attribution claim survives, sharpened

Fetched the full paper to settle whether it had already solved what plan 13.4
and validity defect S4 call our possible methodological contribution.

**It has not, and the distinction is now precise.** TokenPowerBench does
**phase** attribution, not **per-request** attribution. Its mechanism, quoted:
*"Each power sample is tagged with the stage that is active at that moment"*,
then *"integrate these tagged samples to obtain two clear numbers: energy
consumed during prefill and energy consumed during decode."* Under continuous
batching many requests are in flight at once, so a stage tag yields aggregate
prefill-versus-decode energy for the **server**, not a figure for an individual
request. The paper is explicit about the limits: it does not address
*"request attribution precision under heavy multiplexing"*, gives no
synchronisation mechanism, and states no sampling rate.

So our claim stands, but it must be stated against theirs rather than in a
vacuum:

> Phase-level energy attribution exists (TokenPowerBench). **Per-request**
> attribution under continuous batching, where many requests overlap within a
> single power sample, does not. That is the open problem, and the scorer needs
> exactly that quantity because marginal energy is an attribution question.

That is a narrower and better-defended claim than "per-request attribution is
unsolved", and it now cites the nearest prior work instead of ignoring it.

**Their "system level without specialised hardware" is IPMI, so there is no
shortcut.** Their stack is: GPU via *"NVML/DCGM"*, CPU and DRAM via *"Intel
RAPL"*, full node via *"IPMI or a rack-mounted PDU"*. The claim means
"vendor-native telemetry instead of a wall meter", which is precisely the IPMI
route we had already identified. **The CAC IPMI ask is not reducible** - it
remains the only route to a node-level figure here.

**But RAPL is a free coverage gain we had missed, and it is now instrumented.**
We were measuring GPU-package energy only. Intel/AMD RAPL exposes CPU and DRAM
energy through `/sys/class/powercap/*/energy_uj`, needing no privilege in
principle. Added to `telemetry_check.sh` as a recorded-not-required probe and
to `policy_harness.py` as a per-cell measurement.

One caveat, recorded in advance so a denial is not a surprise:
**CVE-2020-8694 (Platypus)** caused many distributions to restrict `energy_uj`
to root, so this may read as DENIED on Rocky 8. If it is readable, our energy
coverage goes from GPU-package to GPU + CPU + DRAM, which is materially closer
to a system figure. If it is denied, that is one more entry in the
permission-inhomogeneity finding.

**Also now instrumented, from the 5.1 gap list:** cache hit rate and queue
depth, scraped from each vLLM server's own `/metrics`
(`gpu_prefix_cache_hit_rate`, `gpu_cache_usage_perc`, `num_requests_running`,
`num_requests_waiting`, token counters). Those close two items of the
2609.05565 reporting set that no GPU tool can supply.

### 12.4 Measurement methodology

| ID | Work | Status | How we use it |
|---|---|---|---|
| **2312.02741** | Yang, Adamek, Armour, "Part-time Power Measurements: nvidia-smi's Lack of Attention" (2023-12-05, rev 2024-12-12) | FETCHED | Verbatim: "on the A100 and H100 GPUs only 25% of the runtime is sampled for power consumption, during the other 75% of the time, the GPU can be using drastically different power". Corrective practices cut error by 35% on average, up to 65%. **Two corrections to our own usage follow - see 12.4.1.** |
| **2410.12032** | Tschand, Rajan, Idgunji et al. (26 authors), "MLPerf Power: Benchmarking the Energy Efficiency of Machine Learning Systems from Microwatts to Megawatts for Sustainable AI" (2024-10-15, rev 2025-02-06) | FETCHED | 1,841 reproducible measurements from 60 systems; "rules and best practices to ensure comparability across diverse architectures". **Caveat: the SPEC PTDaemon requirement and the 1% AC / 1.5% DC uncertainty figures came from secondary sources, not this record. Verify in the full paper before citing those specifics.** |

#### 12.4.1 We had been citing 2312.02741 slightly wrongly, in our own favour

1. **It is not "SC24".** We repeatedly called it an SC24 paper. The record shows
   an arXiv submission of 2023-12-05 revised 2024-12-12, with no venue stated
   there. Stop asserting the venue until confirmed.
2. **Its target is `nvidia-smi` polling, not the energy counter.** The title is
   explicit. The 25% duty-cycle criticism lands on **sampled power**, which is
   the `nvmlDeviceGetPowerUsage` path - *not* on
   `nvmlDeviceGetTotalEnergyConsumption`, which the firmware integrates
   continuously. So the paper is better read as **support for our instrument
   choice** than as a threat to it: it is an argument for preferring the
   counter over polling, which is what our protocol already does.

This refines rather than removes the concern. The counter could still quantise,
which is why `counter_characterisation.sbatch` measures update period and
quantum directly instead of inferring them from a paper about a different API.

### 12.5 Non-arXiv references still to pin down

SPEC PTDaemon, the ML.ENERGY leaderboard, and the Green500 FLOPS/W convention
are used in our reasoning with no citation recorded. Resolve before the
bibliography is final.

### 12.6 Verification scoreboard

**FETCHED: 11 works + 1 GitHub epic. SEARCH remaining: 2** (2605.23057,
2603.04445, both framing-only).

**Four of our own claims were wrong and are now corrected:** 2604.04745's idle
figures, 2604.09048's A30 attribution, 2609.23085's "~23%", and GreenServ's
"LinUCB". Plus two usage corrections on 2312.02741 (venue, and which API it
criticises). Every one of those came from carrying a note forward without
fetching the record. The lesson is cheap to state and was expensive to learn:
**fetch before citing, every time.**

## 13. Progress tracker

Updated 2026-10-04. One line per item so nothing silently drops.

| # | Item | State |
|---|---|---|
| 1 | Measurement apparatus + protocol | **done**, validated |
| 2 | Stage 0 code rescope to `legacy/` | **done** `baef80d` |
| 3 | Stage 1: RTX 6000 / A30 / L4 at 1.5B, 7B on same die | **done** `f49a179` |
| 4 | Modelled gate, then retired | **done** `42bd624`, superseded by measured Stage 2 |
| 5 | Stage 2 harness, measured, 5 policies | **written** `c581f3a`, not yet run |
| 6 | Mandatory telemetry, two passes + fail-fast gate | **done** `e7738ad` |
| 7 | Telemetry-overhead control arm | **done** `a7b4f17` |
| 8 | Counter characterisation (closes S2) | **written** `0bce8f6`, not yet run |
| 9 | Metric set grounded in literature; streaming TTFT/TPOT/ITL | **done** `610179e` |
| 10 | Reference list with verification status | **done** `c0c7f43` |
| 11 | Verification debt cleared (11/13 fetched) | **done** `f8c45bb`, 4 own claims corrected |
| 12 | TokenPowerBench read; attribution claim sharpened | **done**, see 12.3.1 |
| 13 | RAPL (CPU+DRAM) probe and per-cell measurement | **done**, pending a node to test on |
| 14 | Cache hit rate + queue depth from vLLM `/metrics` | **done**, pending a run |
| 15 | GPU-package energy labelling on all published results | **done** |
| 16 | Verify 2605.23057 and 2603.04445 (framing-only) | **open**, low priority |
| 17 | Cite SPEC PTDaemon, ML.ENERGY, Green500 | **open** |
| 18 | Confirm MLPerf PTDaemon / 1% AC figures in the full paper | **open** |
| 19 | Run: counter characterisation | **done** - jobs 12303200 (A30) and 12303324 (RTX 6000); S2 closed on both |
| 20 | Run: Stage 2 smoke, 2 GPU | **done** job 12303326 on `frnt155`; pipeline proved end to end, but see item 21 |
| 21 | Run: Stage 2 real, 8 GPU on `frnt155` | **DISCARDED** job 12303327. Completed clean, every cell client-limited (112.5 offered / 26.7 achieved). See threats N4-N6 |
| 22 | Stage 3 pre-registration | **blocked** on Stage 2 result |
| 23 | Stage 4 scorer, only for a rule Stage 2 proved | **blocked** on Stage 2 |
| 24 | CAC request (7 asks incl. IPMI, power limit) | **drafted, unsent** - user's call |
| 25 | Rotate two exposed CAC passwords | **open** - user action |
| 26 | A100 / L40S / RTX 8000 / V100 sweeps | **optional**, hardware available |
| 27 | Open-loop load generator (httpx), two-clock timing, rate-fidelity reporting | **done** `44013f2` |
| 28 | Load generator gated as an instrument in Pass 0 | **done** `44013f2` |
| 29 | Capacity derived from the measured Stage 1 curve; cells sized by window length | **done** |
| 30 | Run: generator calibration, single process | **done** job 12303350. Ceiling ~115 req/s achieved; SLO knee located between 67.8 and 118.6 req/s |
| 30a | Sharded generator (8 processes, shared routing state) | **done** job 12303353. Dispatch delay p99 0.001-0.007 s, 259.5 req/s achieved, no client-limited cell |
| 30c | Extend calibration past 271 req/s to find the real knee | **done** job 12303354. Knee is 271-350 req/s and sharp |
| 30d | SLO-brittleness diagnostic (margin percentiles, fraction near boundary) | **done** |
| 30b | Generator CPU cost recorded per cell (quantifies N7) | **done** |
| 31 | Stage 2 real, verified load levels | **RUN, VERDICT REJECTED** job 12303355. Apparatus sound (25 cells, 0 client-limited, dispatch p99 0.0051 s, perturbation -0.14%) but routing was ungrounded (N10) and the apparent +9.9% round_robin win was an SLO-boundary artifact: p50 1.946/1.956/1.968 s against a 2.0 s SLO gave 99.0/94.3/90.0% attainment |
| 31a | Extend RTX 6000 curve to concurrency 128 | **running** job 12303358 on `frnt153` (12303357 was lost to N12) |
| 31b | Re-run Stage 2 with the grounded curve | **blocked** on 31a |
| 31c | Repeat trials + confidence intervals at the knee | **open** - one trial per cell cannot support a sub-percent latency ranking |
| 31d | Heterogeneous-fleet Stage 2 (the actual research question) | **open** - see status note |
| 32 | Locate the SLO knee | **partly done** - NOT between 67.8 and 118.6 (that reading was a client artifact, retracted). With a verified generator: 100% through 220.3 req/s, 96.2% at 271.2. Knee is at or beyond 271 req/s; needs a sweep past the current top rate |
| 33 | Report CPU/DRAM energy with the generator-contamination caveat, or move the generator off-node | **open** - see threat N7 |

Blocking path: 31a, then 31b, then 31c, then 22. Items 21 and 31 are run and rejected, not pending.
Everything else is either done or not on the critical path.

## 14. One-line status

Measurement apparatus: **sound for energy; the load generator was not, and is
now fixed and gated.** Stage 1: **complete, four configurations, unaffected -
single-stream, no generator involved.** Stage 2: **one full sweep run and
discarded** (job 12303327, client-limited in every cell); re-run blocked on
calibration job 12303350. Topic: **still open.** Claim: **narrow but
defensible.** Code: **rescoped (`legacy/`), builds clean.** Blocking gap:
**still no baselines.** Biggest risks, in order: **(1) "matched SLO attainment" is structurally
brittle here - a fixed output length makes the end-to-end SLO a TPOT threshold,
so attainment is a near-step function and an 8% TPOT change moves it 90 points;
the comparison has to lean on margin and energy, not attainment alone;
(2) energy per request falls monotonically with load, so "run hot" is already
the efficient strategy and an energy-aware policy has to beat it at the knee;
(3) the A30 dominates, so there may be no useful headroom outside saturation;
(4) CPU/DRAM energy is contaminated by the co-located load generator (N7), so
only GPU-package energy is clean.** The knee itself is now **measured**:
271-350 req/s, with goodput per joule peaking there.

Five defects this session shared one shape: a component answering a question
it had no data for, plausibly. The thread pool reported an offered rate it
never delivered. TTFT reported a latency excluding its own queue. The curve
reported J/token for concurrencies nobody measured. The curve *selector* picked
the narrowest coverage while reporting a choice. The NVML probe reported a
usable interpreter after testing only the import. Each produced clean, monotone,
publishable-looking output, and one of them was believed again after the first
had been diagnosed.

The countermeasure is not closer reading. It is that each component now states
its own domain beside its answer: achieved rate beside offered, dispatch delay
beside TTFT, out-of-range count beside the routing decision, chosen levels
beside the chosen curve. A number that cannot be checked against the conditions
it was produced under is not yet evidence.

**Where the question actually lives.** On a homogeneous 8x RTX 6000 fleet the
three load-balancing policies came within +-1% of each other on J/req at every
load level. If that survives a grounded curve, it says routing barely matters
when every replica is identical - which is the expected result, and it points
at heterogeneous replicas as the only place an energy-aware scorer can earn its
keep. Frontenac has seven GPU types but one type per node, so this needs either
a multi-node allocation or an explicit statement that the claim is scoped to
heterogeneous fleets and untested here. That decision is now on the critical
path, ahead of Stage 4.

The lesson from 12303327 is worth keeping in front: a pipeline that fails
loudly is cheap, and this one failed silently and handed back a publishable
-25% energy result. Every number now carries the measurement that would have
caught it.
