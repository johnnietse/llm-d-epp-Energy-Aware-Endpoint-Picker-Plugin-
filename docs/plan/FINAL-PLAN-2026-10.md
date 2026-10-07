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
| **Novel** | Narrowly, and the window is closing; **narrower than first stated** | The idea that heterogeneity-aware placement saves inference energy is **not new**: Wilkins, Keshav and Mortier proposed it in 2024 (2407.00010, 7.5% CPU+GPU energy against a workload-unaware baseline) from offline workload energy models (2407.04014, HotCarbon 2024). Found 2026-10-07; see 12.2. What remains open is narrower and still real: a **measured, online** test inside a **production router's plugin API**, at matched SLO, by an **unprivileged** tenant, with a **matched homogeneous control** showing the sign reverses. Two agenda papers name that gap without filling it (2609.05565, 2603.21354) and vLLM semantic-router #2332 is building the telemetry contract for it. |
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

## 3.4 Working practice, mandatory

Standing instruction from the user, 2026-10-05, after a day in which several
avoidable round trips to the cluster cost more time than the measurements they
were waiting for.

1. **Fix a problem before reporting it.** Finding a defect and describing it is
   half a job. Diagnose it, fix it, verify the fix, and then report what was
   wrong and what was done. Do not hand back a problem that could have been
   solved.
2. **Try to work around it before escalating.** If the obvious fix is blocked,
   look for the alternative path first. Report only what is genuinely blocked
   on a decision or a permission that is not mine to give.
3. **Troubleshoot before acting again.** A failed command gets understood, not
   retried. Re-running something that failed for an unknown reason wastes the
   time twice and teaches nothing.
4. **Check an action for problems BEFORE running it**, especially anything that
   goes to the cluster. A job that fails after 40 minutes has cost 40 minutes
   plus the queue wait; the same defect found by reading the script costs
   seconds. This is the expensive asymmetry in this project and it has bitten
   repeatedly: an sbatch submitted without `--export=ALL`, a generator sized
   for a quarter of the offered load, a pre-warm globbing the wrong model, a
   curve that stopped below the concurrency the policy drives.

What this means concretely, as a pre-flight checklist for anything submitted:

* Syntax-check every script and every embedded language block.
* Confirm each quantity the job derives (capacity, load levels, SLO, worker
  count) is inside the range the apparatus can actually deliver, using measured
  numbers rather than estimates.
* Confirm the environment reaches the job: `--export=ALL`, and no reliance on
  anything the submitter has to remember.
* Test any assumption the job rests on with the cheapest possible probe, and
  prefer a three-minute probe to a five-hour allocation. Several assumptions
  this project held turned out false: that one `srun --overlap` step implies
  eight work, that `nvidia-smi` reports `CUDA_VISIBLE_DEVICES`, that an import
  check proves a library usable, that a 15-minute loop bounds 15 minutes.
* Verify the measurement instrument alongside the measurement: a tool that
  exits 0 has run, which is not the same as having worked.

**Known-bad patterns, do not repeat.** Each cost real time here:

| Pattern | Why it fails |
|---|---|
| Multi-line `wsl.exe -- bash -c '...'` | newlines become `""`, assignments merge and read back empty; use a script file |
| `ssh -S <dead socket>` without `BatchMode=yes` | ssh silently falls back to direct auth and hangs at an invisible prompt |
| `pkill -f <pattern>` under `srun` | the pattern is in the srun wrapper's own argv, so it kills its own job |
| `source .../profile/bash.sh` in a batch script | execs a replacement shell; everything after it is discarded, exit 1, empty log |
| Deriving load from server capacity alone | says nothing about what the client can emit; ask for the impossible and nothing warns |
| An outer `timeout` shorter than a script's own wait loop | SIGTERM, exit 143, and no result |
| Quoting a remote command containing `$VAR` through `wsl.exe` then `ssh` | three quoting layers, each entitled to one round of expansion. `squeue -u $USER` came back as `Invalid user: ohnnie`, the username with its first character eaten. Put the remote command in a file and run the file |
| Counting a bad state from a flag that older data does not carry | `het_final.sh` counted unusable cross-checks from `cross_check_usable`, a field added after job 12305232 ran. It reported "0 unusable" for a run in which all 25 cells are missing the engine ITL histogram. Count the absence of the *value*, so old and new data answer the same question |
| A verification check that greps for *how* a fix was written | it rots the moment the implementation improves, then reports FAIL against working code. `verify_fixes.sh` section 1 still grepped for `$STAGED_HF` and `${SLURM_TMPDIR:-/tmp}/hfstage` after the uniform-path rewrite replaced both, so it failed a staging block that provably works. Assert the observable property where possible; where you must grep for detail, read a FAIL as "the check or the code is wrong", never as "the code is wrong" |

---

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
| **N13** | **Does staging the model perturb the measurement?** | **closed 2026-10-05, by construction and by ordering.** The multi-node job copies the checkpoint to node-local storage before serving. Three reasons it cannot reach a measured quantity: (1) staging completes before any vLLM server starts, and every energy window opens only after all servers report ready, so no staging I/O falls inside a measured interval; (2) the per-node energy samplers are started *after* staging for exactly this reason - started before, the copy's CPU and disk time would appear in the RAPL CPU/DRAM figures, and that ordering is now asserted in the script with a comment saying why; (3) host page cache and local disk do not affect the GPU energy counter, which is the primary metric. One genuine consequence remains and is stated rather than hidden: the heterogeneous run reads weights from local xfs while the homogeneous runs read from GPFS, so **model-load time is not comparable across those runs**. Load time is not in any measured window, so no reported number is affected, but it must not later be compared across the two configurations. |
| **N14** | **Walltime was described as the control for a wedge; it is not** | **corrected 2026-10-05.** A process blocked in uninterruptible kernel I/O ignores SIGKILL until the I/O returns, so `scancel` cannot reap it and even Slurm's own reclaim waits on the same stuck I/O - that is why `frnt155` sat in COMPLETING for hours. The walltime only bounds how long the allocation is *held*; it neither prevents nor shortens a wedge. The real fix is upstream: node-local staging takes the shared filesystem out of every server's read path, so a GPFS stall cannot block a server at all. Walltime is the last line of defence, now 1h15m against a measured ~40 min run. |
| **N15** | **The two arms of the central comparison do not share a storage path** | **being closed 2026-10-07, job 12319815.** `stage2_real.sbatch` now carries the same staging block, per-node readability verification, `wait` and `exit 0` as the het script, enforced by `verify_fixes.sh` section 11 so the two cannot drift apart again. The matched 8-GPU control is running on `frnt155`. The original defect, for the record: `stage2_het.sbatch` stages the checkpoint to node-local disk; `stage2_real.sbatch`, which produced the homogeneous arm (12304137/12304138), has no staging block and served weights from GPFS. The claim "energy-aware routing pays off under heterogeneity and not under homogeneity" therefore compares two runs that differ in *two* ways, fleet composition and read path. The load-time effect is the large one and measurement starts after readiness, so this is unlikely to drive the result, but "unlikely" is not a control. Closing it requires re-running the homogeneous arm with staging; see tracker 21b. |
| **N16** | **`afterok` cannot chain heterogeneous jobs** | **resolved 2026-10-07, by abandoning the mechanism.** The fear was that the `wait`/`exit 0` fix might fail and leave a successful run marked `CANCELLED`. That fix works: the homogeneous control 12319815 recorded `COMPLETED 0:0`. But 12319685 was still recorded `CANCELLED by 6081`, which is our own uid, on *both* het components at an identical 42:25 elapsed, with all 25 cells complete and exit `0:0` on every component. The likely cause is Slurm tearing down sibling components once the first one finishes; that is an inference from the evidence, not something verified against Slurm's source. The consequence is not in doubt: a heterogeneous job will not satisfy `afterok` in practice, and 12319692 was dropped from the queue without running. Heterogeneous trials are now submitted independently, never chained. |
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
| **2407.00010** | Wilkins, Keshav, Mortier, "Hybrid Heterogeneous Clusters Can Lower the Energy Consumption of LLM Inference Workloads" (2024-04-25) | FETCHED (arXiv API, 2026-10-07) | **Closest prior art, missing from the plan until 2026-10-07.** Cost-based scheduling across accelerators of differing energy efficiency, deciding by input and output token counts; abstract reports **7.5%** lower CPU+GPU energy than a workload-unaware baseline. The abstract describes an "analysis of a representative LLM dataset", i.e. evaluated on a trace, not in a live router. Our difference: online, inside a router plugin API, at matched SLO, with a homogeneous control. Must be cited as the origin of the idea, not as a competitor we beat. |
| **2407.04014** | Wilkins, Keshav, Mortier, "Offline Energy-Optimal LLM Serving: Workload-Based Energy Models for LLM Inference on Heterogeneous Systems" (HotCarbon 2024) | FETCHED (arXiv API) | The measured models behind 2407.00010: per-LLM energy and runtime models with R^2 > 0.96 across prompt and output sizes, used for an **offline** energy-optimal scheduler. Our Stage 1 per-type curves are the same kind of object, measured per GPU type rather than per model. |
| **2511.00807** | He, Fang, Lian, Tsang, Zhang, Chen, "FREESH: Fair, Resource- and Energy-Efficient Scheduling for LLM Serving on Heterogeneous GPUs" (2025-11-02) | FETCHED (arXiv API) | Joint routing and scheduling across geographically distributed heterogeneous GPU data centres; **28.6%** energy and **45.45%** emissions reduction over a 1-hour production workload. Uses **dynamic GPU frequency scaling**, which requires the clock control Frontenac denies (tracker 31f), and spans multiple data centres. Different operating point: we are one tenant on one cluster with no privileges. |
| **2603.17280** | Chen, Liu, Liu, Jiang, He, Liu, "The 1/W Law: ... Context-Length Routing Topology and GPU Generation Gains for LLM Inference Energy Efficiency" (2026-03-18) | FETCHED (arXiv API) | Same vLLM semantic-router group as 2603.21354. Predicts about **2.5x** tok/W from two-pool routing over a homogeneous fleet. States: "no new hardware experiments were conducted" - analytical, calibrated to published H100 data. Our homogeneous-versus-heterogeneous sign reversal is measured evidence in the direction it models, at far smaller magnitude; cite as the model our data partly tests, never as a number to compare against. |
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

**FETCHED: 13 works + 1 GitHub epic + 4 standards/benchmark sources.
SEARCH remaining: 0.**

Verified 2026-10-04:

* **arXiv 2605.23057** - *RequestRouter: Request-Boundary Routing for
  Efficient Single-GPU LLM Inference* (Sunesh, Alshehhi, Dhakne; v1 2026-05-21,
  v2 2026-08-19). Selects an inference **configuration** per request (FP16,
  quantized, speculative decoding, prefix caching, continuous batching,
  hybrid) on a **single** A100 under vLLM: 2.10x mean latency speedup over
  FP16, 0.48x energy ratio, 99.6% of FP16 macro accuracy, 0.00475 ms mean
  routing overhead, 30,000 executions. Framing only, and usefully so: it is
  configuration selection on one device, not replica selection across a
  fleet, so it does not contest our claim.
* **arXiv 2603.04445** - *Dynamic Model Routing and Cascading for Efficient
  LLM Inference: A Survey* (Moslem, Kelleher; v1 2026-02-23, v3 2026-08-30).
  A survey of **model** selection. This is direct support for our framing
  point that the 2026 routing literature overwhelmingly selects models while
  we select replicas of one model.

**Four of our own claims were wrong and are now corrected:** 2604.04745's idle
figures, 2604.09048's A30 attribution, 2609.23085's "~23%", and GreenServ's
"LinUCB". Plus two usage corrections on 2312.02741 (venue, and which API it
criticises). Every one of those came from carrying a note forward without
fetching the record. The lesson is cheap to state and was expensive to learn:
**fetch before citing, every time.**

### 12.7 Standards and benchmark sources, and a fifth correction of our own

**We had been asserting that MLPerf Power establishes "<1% AC uncertainty".
That is wrong on three counts and is withdrawn.**

What the sources actually say, fetched 2026-10-04:

* **MLPerf Power** (arXiv 2410.12032, HPCA 2025; Tschand et al.; 1,841
  reproducible measurements from 60 systems) states **no percentage tolerance
  anywhere**. Its accuracy language is qualitative: systems "must meet
  stringent accuracy standards", edge systems "must employ SPEC-approved
  devices". Measurement location varies by scale: the inference/edge path uses
  a SPEC-certified analyser such as the Yokogawa WT310 measuring **AC wall
  power**, while datacenter and training submissions use "the submitter's own
  telemetry systems, such as IPMI or RedFish", or measure at the PDU. It talks
  to analysers through **PTD (Power-Thermal Daemon)** API calls - our notes
  called this "SPEC PTDaemon", which is the SPEC tool's name, not the term the
  paper uses in that sentence.
* **The 1% figure belongs to SPEC, not MLPerf**, and it is an uncertainty
  budget rather than a tolerance on AC power. SPECpower_ssj2008 Run and
  Reporting Rules section 2.13.2: *"Measurements must be reported by the
  analyzer with an overall uncertainty of 1% or better for the ranges measured
  during the benchmark run"*, where *"Overall uncertainty means the sum of all
  specified analyzer uncertainties for the measurements made during the
  benchmark run."* It is explicitly range-dependent: *"a power analyzer may
  meet these requirements when used in some power ranges but not in others"*,
  and *"the usage of power analyzer's auto-ranging function is discouraged."*
  Note for anyone re-checking this: the PDF versions of the SPEC setup guide
  and acceptance process both extracted as "+/-2% of the measured load", and
  that extraction is unreliable - the PDFs are compressed and the parser said
  so. The HTML run-reporting rules are the clean source and say 1% overall
  uncertainty. Cite the HTML.
* **ML.ENERGY Benchmark** (arXiv 2505.06371; Chung, Ma, Wu, Liu, Kweon, Xia,
  Wu, Chowdhury; v1 2025-05-09, v2 2025-10-16). 40 model architectures across 6
  tasks, with automated optimisation reaching "sometimes more than 40%" energy
  savings. Grew out of the Zeus energy measurement library from the same group.
  **Its measurement level and tool are not stated in the abstract**, so we do
  not assert NVML or Zeus for it until the full paper is read.
* **Green500** (TOP500/Green500, biannual). Ranks TOP500 systems by
  **GFLOPS/Watt**, computed from HPL Rmax over average power across the whole
  HPL run, and critically **"limited to the total power consumed by all compute
  nodes involved in computing the benchmark, excluding the power consumed by
  the storage nodes and front nodes"**. That scoping precedent is directly
  useful to us: a respected list defines its boundary explicitly and excludes
  parts of the machine, which is the same move as our GPU-package labelling.
  The EEHPC Working Group measurement levels (1/2/3) are referenced in the
  Green500 power-measurement tutorial but we have **not** verified their
  definitions, so nothing may rest on them yet.

**This is the fifth citation error we have found in our own notes**, after
2604.04745's idle figures, 2604.09048's A30 attribution, 2609.23085's "~23%",
and GreenServ's "LinUCB". Every one came from carrying a note forward without
fetching the record. The MLPerf case is the worst of the five because the
number was plausible, specific, and attached to the wrong authority - which is
exactly the kind of claim a reviewer checks.

---

### 12.8 STAGE 2 RESULT, measured 2026-10-04

Jobs **12304137** (seed 7) and **12304138** (seed 11), 4x Quadro RTX 6000,
Qwen2.5-1.5B-Instruct, 60 s cells, 12 generator workers, routing grounded in
the c=256 curve from job 12304133. 38 usable cells after excluding 6 in which
every policy was inactive. Zero client-limited cells, worst dispatch delay p99
0.0060 s, telemetry perturbation +0.98% and +0.40%.

At 120 req/s, means across both trials:

| policy | J/req | SLO% | SLO-goodput/J | p95 / SLO |
|---|---|---|---|---|
| **round_robin** | **6.71** | **100.0** | **0.1491** | 0.947 |
| least_loaded | 7.18 | 100.0 | 0.1392 | 0.939 |
| slo_packing | 7.45 | 50.0 | 0.0670 | 1.012 |
| energy_greedy | 7.46 | 56.8 | 0.0762 | 1.012 |
| energy_consolidate | 7.48 | 55.9 | 0.0747 | 1.013 |

**The three policies that consult the energy curve have no feasible operating
point at any swept load level.** None reaches 95% SLO attainment anywhere from
120 to 180 req/s. The two that ignore the curve entirely are both feasible, and
plain `round_robin` is the best measured policy on SLO-goodput per joule while
also using the least energy per request.

The mechanism is in the last column. At the lowest swept load the consolidating
policies already sit at p95 = 1.012-1.013 x SLO, just outside, while
`round_robin` is at 0.947, inside. Concentrating load to improve J/token pushes
p95 past the deadline **before the energy saving can be collected**. The
extended curve shows why this is structural rather than a tuning error: on this
GPU, p95 first exceeds 2.0 s at concurrency 96, while J/token keeps improving
all the way to 256. The efficient concurrency and the serviceable concurrency
do not overlap.

**This is a negative result for energy-aware routing on a homogeneous fleet,
and it is the honest headline.** It was reproduced across four independent runs
(two seeds x two submissions) with the ordering identical every time.

What it does **not** establish: that energy-aware replica selection is useless.
The fleet used here is six identical Turing cards, and the per-type curves
measured the same day show that is the worst possible setting for the idea -
see 12.9.

### 12.9 Why the question moves to a heterogeneous fleet

Per-GPU-type curves, all at concurrency 128, same model, same window:

| GPU | req/s | power | J/gen-token | tok/J | p95 |
|---|---|---|---|---|---|
| A100-PCIE-40GB | 146.1 | 247.6 W | 0.0132 | 75.5 | 0.904 s |
| L40S | 99.9 | 314.5 W | 0.0246 | 40.6 | 1.503 s |
| A30 | 94.8 | 163.8 W | 0.0135 | 74.1 | 1.401 s |
| RTX 8000 | 54.6 | 221.6 W | 0.0318 | 31.5 | 2.363 s |
| **RTX 6000** | 52.2 | 235.3 W | **0.0353** | **28.4** | 2.511 s |
| L4 | 45.2 | 71.9 W | **0.0124** | **80.5** | 2.899 s |

Two facts reframe the Stage 2 result:

1. **Every Stage 2 measurement so far used the least efficient GPU in the
   fleet.** RTX 6000 is 2.7x worse on J/token than A100, A30 or L4. A policy
   choosing *between* replicas has nothing to exploit when all replicas are the
   same bad card.
2. **Efficiency and throughput are nearly inverted across types.** L4 is the
   most efficient per joule and the slowest; A100 is the fastest and second
   most efficient; L40S buys throughput at roughly half A100's efficiency. L4
   cannot hold a 2 s p95 past concurrency 32, where A100 is still at 0.904 s.
   That is a real trade-off for a router to arbitrate, and it does not exist
   within one GPU type.

**Caveat that must travel with the L4 and L40S rows:** the container's torch
2.13.0+cu130 was compiled for sm_75, sm_80, sm_86, sm_90, sm_100 and sm_120
(job 12304136). `sm_89` is absent, so Ada cards run sm_86 Ampere cubins through
minor-version compatibility rather than native kernels. The L4's
best-in-fleet efficiency is therefore probably understated.

**V100 is excluded, not missing.** `sm_70` is absent from the same build, so
job 12304130 died with `cudaErrorNoKernelImageForDevice`. A CUDA 12 container
would run it but would produce numbers from a different kernel set and vLLM
build, so they would not be comparable to the rest. Exclusion is the correct
methodological choice here rather than a convenience.

---

### 12.10 The frnt155 failure mode, and what actually fixes it

Worth recording in full because it shaped several scripts and because the first
three answers to it were mitigations mistaken for fixes.

**What happened.** Job 12303653 launched eight vLLM servers on one node. All
eight read the same 2.88 GiB checkpoint from GPFS simultaneously, cold. At
least one blocked in uninterruptible kernel I/O (process state D), which
ignores SIGKILL until the I/O returns. The job wrote nothing further for two
hours; `scancel` registered but could not reap it; the node stayed in
COMPLETING. `frnt155` is the cluster's only 8x RTX 6000 node, so that single
wedge also blocked every subsequent 8-GPU RTX 6000 run.

**Three things that help but do not fix it.**

1. *Staggered launches* (8 s apart). Every single-node run after this change
   started cleanly - ready in 111 s. But it reduces concurrency at the
   filesystem, it does not remove the filesystem.
2. *Page-cache pre-warm*: read the checkpoint once sequentially, then let the
   servers hit warm cache. Better, still a mitigation - the first read is still
   a cold GPFS read, and a stall there wedges the job just as well. (The first
   implementation also globbed every `*.safetensors` under the cache, which
   matches the 7B model too and would have read 18 GB to warm 2.88 GB.)
3. *Shorter walltime*. This was described as "the control" and that was wrong,
   see threat N14. It bounds how long a wedge holds the allocation. It does not
   prevent one, and it does not shorten one.

**What actually fixes it.** Take GPFS out of the read path. Job 12304897
established that `$SLURM_TMPDIR` is `/lscratch/...`, xfs, genuinely node-local,
463 GiB free, and that eight concurrent readers there sustain 3931 MiB/s. The
multi-node job now copies the served model to local disk once per node and
points `HF_HOME` at the copy, with `HF_HUB_OFFLINE=1`. After that no server
touches shared storage, so a GPFS stall cannot block one.

Staging failure is fatal rather than falling back to GPFS: a silent fallback
would restore the exact hazard while reporting success, which is the pattern
that cost this project most of a day elsewhere.

**Residual risk, stated honestly.** Node-local staging removes GPFS from the
*serving* path, not from the *staging* path - the copy itself still reads GPFS
once per node. That read is sequential and single-threaded, which is the
filesystem's best case rather than its worst, and it happens before any
measurement window. It is not zero risk; it is a single cold sequential read
instead of eight concurrent ones.

---

**Resolution, 2026-10-07.** `frnt155` reports `State=IDLE` again: the wedge
cleared without intervention once the stuck I/O finally returned, so no CAC
admin action was needed for it and the node is usable again. This does not
retire the fix. The wedge was a *symptom* of GPFS sitting in the serving read
path, and node-local staging removes that path whether or not any single node
is currently healthy. Treat the recovery as luck, not as evidence that the
hazard is gone; the item on the CAC request that concerned `frnt155` can be
dropped, the other six stand.

### 12.11 Stage 2 replication, launched 2026-10-07

The single heterogeneous trial in 12.8 cannot carry Stage 3. Two further
trials are queued, chained so they cannot race each other:

| Job | Seed | Hold | Purpose |
|---|---|---|---|
| **12319685** | 11 | none | does the +2.0% margin of `energy_consolidate` over the next policy replicate at a different seed |
| **12319692** | 13 | `afterok:12319685` | third point, so the margin has a spread rather than a difference of two numbers |

`afterok` rather than `afterany` deliberately: if trial one fails, the second
allocation should not be spent reproducing the same failure before anyone has
read the log. `DEP` is also the only thing that relaxes `het_submit.sh`'s
duplicate guard, and only because a job held by a dependency cannot race the
job it waits for - which is exactly what the guard exists to prevent.

Both runs also carry the corrected vLLM histogram names
(`vllm:inter_token_latency_seconds` and the `request_`-prefixed TPOT), so the
first thing to check in the output is that `server_itl_mean_s` is non-null.
If it is null, `cross_check_usable` will say so explicitly rather than
reporting a silent `engine 0.0000` comparison against nothing.

What a pass needs: `energy_consolidate` must win in **every** trial, not on
average across them. (This sentence originally added "and the margin must stay above the 2.0% threshold"; the gate has no such threshold, see the correction in 12.13.) The
caveat recorded in 12.8 survives a pass: the three curve-using policies
cluster within 1.6-2.0% of each other, so a win is evidence for
heterogeneity-awareness, not for the energy objective in particular.

### 12.12 The matched homogeneous control, job 12319815

The heterogeneous result in 12.8 is compared against a homogeneous arm
(12304137/12304138) that differed from it in **three** ways, not one:

| | Heterogeneous (12305232) | Old homogeneous (12304137/8) | New control (12319815) |
|---|---|---|---|
| Fleet | 4 A100 + 4 RTX 6000 | 4x RTX 6000 | 8x RTX 6000 |
| GPU count | 8 | **4** | **8** |
| Read path | node-local xfs | **GPFS** | **node-local xfs** |
| Offered rates | 200-600 req/s | derived from `PEAK_RPS` | **200-600 req/s, pinned** |

Only the first row should differ if the claim is about heterogeneity. The
control removes the other two, so a surviving effect is attributable to fleet
composition rather than to fleet size or to storage. `RATES` is pinned rather
than derived from this node's own `PEAK_RPS` for exactly this reason: a
capacity-derived ladder would hand each arm a different demand and make the
cells incomparable.

The node is pinned with `-w frnt155`, not selected with `-C`, because driver
version, profiling permission and idle power were each measured to vary
between nodes of the same GPU model. `real_submit.sh` additionally refuses to
submit onto a node in `COMPLETING`, which is the wedge state, and refuses to
submit at all if the staging block is absent from `stage2_real.sbatch`.

**What this run can and cannot settle.** If `energy_consolidate` wins on the
heterogeneous fleet and does not win here, at matched GPU count and matched
read path, that is the cleanest evidence the project can produce on this
cluster. It still cannot separate the energy objective from
heterogeneity-awareness in general, because the three curve-using policies
cluster within 1.6-2.0% of each other; that separation needs a policy that is
heterogeneity-aware but energy-blind, which is a Stage 3 design question.

### 12.13 Replication and matched-control results, 2026-10-07

**Heterogeneous replication, seed 11 (job 12319685).** Integrity is clean:
25 cells, none client-limited, none ungrounded, none missing energy.
Goodput per joule:

| policy | 200 | 300 | 400 | 500 | 600 | pooled |
|---|---|---|---|---|---|---|
| round_robin | 0.1069 | 0.1364 | 0.1031 | 0.1191 | 0.1308 | 0.1193 |
| least_loaded | 0.0925 | 0.1557 | 0.2024 | 0.2341 | 0.2113 | 0.1792 |
| slo_packing | 0.1655 | 0.2601 | 0.3189 | 0.3550 | 0.3393 | 0.2878 |
| energy_greedy | 0.2066 | 0.2625 | 0.3208 | 0.3578 | 0.3384 | 0.2972 |
| energy_consolidate | 0.2116 | 0.2643 | 0.3233 | 0.3593 | 0.3392 | **0.2995** |

The ordering seen in 12305232 reproduces. **CORRECTED 2026-10-07, see the
gate result below:** this paragraph first said the pooled margin over
`slo_packing` was +4.07% and that it "clears the +2.0% gate". Both halves were
wrong. +4.07% is `compare_runs.py`'s mean across load levels, not the gate's
statistic; the pre-registered gate (`stage2_analyse.py`) compares each policy
at its own best feasible operating point and gives **+1.2%** for this trial.
And there is no +2.0% gate: the pass rule (`stage2_analyse.py:445`) is
sign-consistency, a win in every trial by any positive margin. "+2.0%" was the
first trial's margin, which hardened into a "threshold" in our own prose. Two
further qualifications travel with this trial.
The margin over `energy_greedy` is only **+0.78%**, so consolidate against
greedy is not resolved. And at 600 req/s `energy_consolidate` loses to
`slo_packing` by 0.03%: the advantage is concentrated at low and middle load
and is gone at saturation. The claim the data supports is that
curve-using policies beat SLO-only packing by a small, consistent margin
(gate, three trials pooled: **+1.4%**, see 12.13a) and round-robin by far more
on a heterogeneous fleet. It is not "consolidate is the best policy".

**Matched homogeneous control (job 12319815): a sign reversal.** At
200 req/s, the one load level where both fleets have slack:

| | heterogeneous 4+4 | homogeneous 8x RTX 6000 |
|---|---|---|
| round_robin | 0.1069 | 0.1377 |
| energy_consolidate | 0.2116 | 0.0699 |
| energy policy against round_robin | **+98%** | **-49%** |

The energy-aware policy nearly doubles goodput per joule on the heterogeneous
fleet and halves it on the homogeneous one. That is a stronger finding than
"no benefit under homogeneity": with every GPU identical there is no efficient
tier to consolidate onto, so consolidation only adds queueing. It agrees with
the earlier homogeneous result (`round_robin` wins, 12304137/12304138), now at
matched GPU count and matched read path. In the control, `round_robin` or
`least_loaded` wins every interpretable load level.

**The control has a flaw, and it is our design.** `RATES` was pinned to the
heterogeneous ladder so that offered load would match. At 400 req/s and above
the 8x RTX 6000 fleet is so far past saturation that goodput per joule falls
to about 0.0001, and those cells say nothing about routing. The control's
pooled column is therefore meaningless and must not be quoted. Matching
offered load bought comparability at low load and destroyed it at high load.
Tracker 21c is the fix: a ladder inside the homogeneous fleet's own capacity,
with the comparison reported only over the region where both fleets are
feasible.

**The generator-accuracy question is answered.** The engine ITL histogram
populated for all 25 cells, and the two values were confirmed to come from
independent sources: `s_itl` is a Prometheus histogram delta and
`client_itl_mean` is computed from client token timestamps. They agree within
**0.6%** (0.0062 against 0.0062, 0.0088 against 0.0088). A Python generator is
not costing per-token accuracy. The +16 to 27% on TTFT is the cross-node hop
and client-side queueing, and exact ITL agreement is what rules out generator
jitter as the cause.

**Tooling defects found while producing these numbers**, all of the silent
kind described in 12.15:

- `compare_runs.py`: `glob` does not expand `~`, so a tilde path matched
  nothing and printed "no usable cells", exactly what a refused run prints.
- `compare_runs.py`: the cell filter treated `router_ungrounded_frac` as a
  flag when it is a fraction, so any non-zero value vetoed the cell and all 25
  were dropped. It now reports what it drops and why.
- `het_status.sh` filtered on the `stage2-het` job name, so the control was
  invisible to it and to the waiter built on it.
- `fr-hetwait.sh` counted lines matching `stage2-het`, which also matched a
  section header, so the count never reached zero and every wait ran to its
  deadline without collecting a verdict. It now counts named job ids through a
  `QUEUED_COUNT=` line, and treats a missing count as a failed poll rather
  than as zero.

### 12.13a Three seeds and the capacity-matched control, judged by the gate

All figures below are from the pre-registered gate, `stage2_analyse.py`: each
policy at its own best feasible operating point (SLO attainment >= 95%),
compared on SLO-goodput per joule. `compare_runs.py`'s means across load levels
are descriptive only and are not quoted as results.

**Heterogeneous fleet, seeds 7, 11, 13 (jobs 12305232, 12319685, 12321476).**
All 75 cells clean: none client-limited, none ungrounded, none missing energy,
and the engine ITL histogram populated in every cell.

| policy | best feasible point | gp/J | vs `slo_packing`, pooled | per trial |
|---|---|---|---|---|
| energy_consolidate | 500 req/s | 0.3574 | **+1.4%** | +2.0%, +1.2%, +1.0% |
| energy_greedy | 500 req/s | 0.3559 | +0.9% | +1.6%, +0.8%, +0.5% |
| slo_packing | 500 req/s | 0.3526 | baseline | |
| least_loaded | 500 req/s | 0.2323 | -34.1% | |
| round_robin | 200 req/s | 0.1096 | -68.9% | |

**GATE PASSED**: `energy_consolidate` beats `slo_packing` in all three trials.

**Homogeneous 8x RTX 6000, in-capacity ladder 100-300 req/s (job 12321478).**
`round_robin` best at 250 req/s, 0.1682 gp/J; `least_loaded` 0.1664. **No
feasible point** for `energy_consolidate`, `energy_greedy` or `slo_packing`: all
three concentrate load and break the 95% SLO before the saving can be
collected. **GATE FAILED, informatively.** This replicates the earlier
homogeneous result (12304137/12304138) at matched GPU count, matched read path,
and now a load ladder the fleet can actually serve. A descriptive table showed
energy policies ahead at 100 req/s; those cells miss the SLO and the gate
correctly discards them, which is why the descriptive table is never quoted.

**What this supports.** The policy ranking reverses with fleet composition,
measured by one instrument: on a heterogeneous fleet the energy-curve policies
are the best feasible policies, and on a homogeneous fleet they are not
feasible at all. That is the result Stage 4 is built on.

**What it does not support, yet.**

- **The margin is small and its uncertainty unknown.** +1.0% to +2.0% per
  trial. Three trials all positive is what a symmetric null produces with
  probability 1/8, so sign-consistency alone is weak evidence. Stage 3 must set
  the trial count from a power analysis on the measured between-trial variance
  (roughly 0.5 percentage points here), not from the three we happen to have.
- **Consolidate against greedy is not resolved.** It leads in every trial, by
  +0.4, +0.4, +0.5 points. Consistent and tiny; a claim that consolidation
  specifically beats greedy energy placement needs Stage 5's trial count.
- **Fleet-to-fleet ratios are not routing effects.** The heterogeneous fleet's
  best (0.3574) is about 2.1x the homogeneous fleet's best (0.1682), but the
  fleets differ in hardware - A100s are more efficient per joule - so that
  ratio mixes hardware and routing and must not be quoted as either.

**Slurm detail, now seen twice.** 12321476 was recorded `CANCELLED by 6081`
on both components, like 12319685, with complete data and exit `0:0`. Every
heterogeneous run is affected; never chain one with `afterok`.

### 12.14 Which upstream code this project needs, verified 2026-10-07

Answered from the code and the upstream repositories, not from memory.

| Component | Needed? | When | Basis |
|---|---|---|---|
| vLLM **source** (`vllm-project/vllm`) | **No** | never, unless we patch vLLM | Every run uses the official image `images/vllm-v0.30.0.sif` (8.0 GB) via `apptainer exec ... vllm serve`. We modify nothing in vLLM; we read its Prometheus metrics. The version pin matters (metric names differ across versions, see the TPOT defect in 12.15), so the record to keep is the image and its digest, not a source tree |
| llm-d umbrella (`llm-d/llm-d`) | **No** | reference only | Its own description: "Achieve state of the art inference performance with modern accelerators on Kubernetes". It is the deployment layer (guides, Docker, docs, `COMPONENTS.md`). Frontenac has no Kubernetes and grants no privileges, and our artifact is a scorer plugin, which plugs into the router, not the umbrella |
| llm-d router (`llm-d/llm-d-router`) | **Yes, from Stage 4** | Stages 4 and 5 | The plugin is built against it, and Stage 5's "stock llm-d" arm runs its EPP. Checkout on the cluster: `main` at `297bfb0` (2026-10-02), clean, never built |

**Stages 1-2 deliberately do not use llm-d at all.** The routing policies live
in the Python load generator (`policy_harness.py`, rationale at its top): a
placement rule can be tested in ~100 lines without a Go plugin against an
upstream API that churns, and only a rule that wins is worth building. The
consequence must be stated wherever results are quoted: **the Stage 2 numbers
show that the placement rule helps; they do not yet show that an llm-d plugin
delivers it.** The EPP adds its own decision latency, a metrics-scrape
staleness the harness does not have, and an Envoy hop. Stage 5 is where that
is measured, and Stage 4's fixture tests are where the Go scorer is shown to
make the same decisions as the Python one.

**Stage 5 is feasible on Frontenac without Kubernetes.** The router documents
it directly (`docs/discovery.md`, "Running EPP with file discovery (no
Kubernetes)"): an `epp` binary built with `go build -o epp ./cmd/epp`, Envoy
v1.31 or later, a static `endpoints.yaml` listing the vLLM servers, and
`--config-file` naming the scheduling plugins. No `InferencePool` CRD. This
removes what would otherwise have been the largest feasibility risk in the plan.

**The three gaps before Stage 4, closed 2026-10-07.**

1. **Module retargeted.** `go.mod` at the repository root required
   `sigs.k8s.io/gateway-api-inference-extension v1.5.0`. That dependency is not
   wrong in itself: llm-d-router v0.11.0 requires the same module for its API
   types. The real defect was narrower and worse. The router registers plugins
   into **its own** registry
   (`github.com/llm-d/llm-d-router/pkg/epp/framework/interface/plugin`), and the
   existing scorer implemented no framework `Score` interface at all; it is the
   TDP-proxy code section 2 already marks REWRITE. New out-of-tree module
   `router-plugin/` (`github.com/johnnie/energy-aware-epp/router-plugin`) pins
   **llm-d-router v0.11.0**, the latest release, not `main`, which moves daily.
   Its `cmd/epp` is the upstream runner unchanged plus our `Register` calls, so
   any behavioural difference from stock llm-d comes only from plugins a config
   selects. It ships one plugin, an **inert plumbing probe**
   (`energy-epp-plumbing-probe`) that scores every endpoint 1.0 and counts its
   calls in `energy_epp_probe_score_calls_total`. It refuses parameters and is
   registered Alpha, so it cannot be mistaken for a tunable policy or loaded
   without `--allow-experimental-plugins`. `go vet` clean; 4 unit tests pass.
   The real scorer is still Stage 4 and still waits for Stage 3
   pre-registration.
2. **No Go toolchain needed on the cluster.** The router is pure Go (no cgo, no
   `replace` directives), so the EPP is cross-compiled here:
   `CGO_ENABLED=0 GOOS=linux GOARCH=amd64`, Go 1.26.6 (the router requires
   >= 1.26.6; Go's toolchain switching fetched it). Result: a statically linked
   ELF, sha256 `f3f2aa63...2acf8`, with `llm-d-router v0.11.0` and its module
   hash embedded. The job refuses to run any binary whose hash differs.
3. **Envoy is 1.39.2**, read inside a job: `/usr/local/bin/envoy version:
   50d48c6c.../1.39.2/Clean/RELEASE/BoringSSL`. The router needs >= 1.31. This
   could not be checked from the login node, which **disables user namespaces
   and so cannot run any container** - a cluster fact worth keeping, since it
   means every container check must be a job.

**Found by running the binary locally before spending cluster time**, each of
which would have failed the first cluster attempt:

- `--pool-name` is **required** at v0.11.0 in file-discovery mode
  (`either pool-name or endpoint-selector must be set`), although
  `docs/discovery.md` on `main` calls it optional. Documentation tracks `main`;
  behaviour tracks the release we pin.
- `--secure-serving` defaults to **true**, while the documented Envoy config
  speaks plaintext gRPC to the EPP. Must be `false` here.
- `--metrics-endpoint-auth` defaults to **true** and authenticates through a
  Kubernetes API. Must be `false` without Kubernetes.
- The EPP **injects a `utilization-detector` filter** by default. Every llm-d
  arm in Stage 5 will carry it; it must be named in the method, not discovered
  by a reviewer.

**End-to-end smoke test:** `experiments/scripts/router_smoke.sbatch` runs
curl, then Envoy, then the EPP with the probe, then two vLLM servers, and counts
evidence twice: the probe's counter and each vLLM server's own access log.
**PASSED twice.** Job 12321494: 40 of 40 requests returned 200, the
probe's `Score()` was called exactly 40 times, and vLLM's own access logs show
19 and 21 completions on the two servers, `COMPLETED 0:0` in 2 min 46 s. It
also logged OpenTelemetry export timeouts, which is how `--tracing` defaulting
to true was found. Job 12321494's predecessor 12321493 failed in 4 s at the
Envoy version gate because the version parse took the last line of output; the
gate refusing an unreadable version was the intended behaviour. Job 12321496,
identical but with `--tracing=false`, so that the committed script is the one
that passed: 40 of 40, 40 calls, 17 and 23, zero trace errors, `COMPLETED 0:0`
in 3 min 17 s. The router path from client to vLLM through our plugin works on
Frontenac with no Kubernetes.

### 12.14a Is this work built on Kubernetes?

Short answer: **the artifact targets a Kubernetes-native project; the
contribution and the measurements do not depend on Kubernetes.**

What Kubernetes does inside llm-d, from the router's own source
(`cmd/epp/runner/runner.go`, v0.11.0, the comment beginning "File mode runs
without a controller manager"):

| Kubernetes provides | Without it (file discovery) | Touches our scorer? |
|---|---|---|
| Endpoint discovery: an `InferencePool` selects pods; the EPP watches them | A static `endpoints.yaml`; `watchFile` can reload it | No - the scorer receives the same `[]Endpoint` either way |
| `InferenceObjective` reconciler: per-request priority | Inactive; priority falls back to `Director.defaultPriority` | Indirectly, only if flow control queues by priority |
| `InferenceModelRewrite` reconciler: model-name rewriting and traffic splits | Inactive | No |
| `k8s-notification-source` data-layer plugins | Cannot bind | No; vLLM metrics are scraped over HTTP in both modes |
| Deployment, scaling, networking (Helm charts, Services) | Slurm launches the processes | No |
| Security defaults: TLS serving, metrics auth via the Kubernetes API | Disabled explicitly (`--secure-serving=false`, `--metrics-endpoint-auth=false`) | No |

The scheduling pipeline - filters, scorers, picker, and the data layer that
scrapes vLLM's Prometheus endpoint - is the same code in both modes. A scorer
plugin is an in-process Go value called with a request and a list of
endpoints; nothing in its interface names a Kubernetes type.

**What a reviewer can still say, and the honest answer.** Production llm-d
runs on Kubernetes, so our evaluation exercises the scheduler but not the
control plane. Three things differ in production and are untested here:
endpoints appear and disappear as pods scale, whereas ours are static;
`InferenceObjective` priorities can reorder admission ahead of scoring; and
pod networking adds latency our loopback setup lacks. None changes what the
scorer decides for a given request and endpoint set; all can change the
request mix it sees. Recorded as a threat to external validity, not hidden.

**Why this is a strength for the paper's framing, not a weakness.** The plan's
central claim is *unprivileged* energy-aware routing: what a tenant who cannot
touch clocks, power limits or cluster configuration can still do. HPC centres
like Frontenac run Slurm, not Kubernetes, and grant no privileges. That llm-d's
scheduler runs unmodified in its documented non-Kubernetes mode on such a
cluster is evidence for the framing.

**Comparable systems, for positioning only** (GitHub descriptions as fetched
2026-10-07, not further verified): `vllm-project/production-stack` describes
itself as "K8S-native"; `vllm-project/router` as "a high-performance and
light-weight router for vLLM"; `ai-dynamo/dynamo` as "a Datacenter Scale
Distributed Inference Serving Framework"; `kubernetes-sigs/gateway-api-inference-extension`
is the upstream llm-d-router's EPP derives from. llm-d remains the right target
because the agenda papers name *its* plugin API as the gap.

**Hugging Face resources that bear on method, not on routing.**
`ml-energy/benchmark-v3` (dataset) and the `AIEnergyScore` organisation
(leaderboard Space plus per-task datasets, including `text_generation`)
publish per-model inference energy. Neither routes requests. Their use here is
an external sanity check: if either reports Qwen2.5-1.5B on A100 or RTX 6000,
our Stage 1 joules per token should land in the same range, and a large
disagreement would point at our instrument before at theirs.

### 12.15 Engineering defect log, 2026-10-04 to 2026-10-07

Every defect below was found and fixed in this project's own measurement
code, not in llm-d. They are recorded because several produced *clean,
publishable-looking numbers* that were wrong, and that is the failure mode
this project is least able to afford. Entries already covered by threats
N4-N16 or by the known-bad table in 3.4 are not repeated here.

| Defect | How it surfaced | Evidence | Fix |
|---|---|---|---|
| Energy policies fell through to index order | `or list(range(n))` then `min(..., key=_jtok)` with every candidate `+inf`: a no-op comparison that returns the first element, so the policy silently became round-robin-by-index while reporting itself active | found by reading, after `interp` clamping was fixed and the policy still behaved oddly | falls back to least-loaded and records that it did, so an inactive policy is visible in the output rather than impersonating a decision |
| `cp -rL` copied the checkpoint twice | staged 5910 MiB for a 2944 MiB model; `-L` dereferences `snapshots/` symlinks that already point into `blobs/`, so both copies land | staging log size | copy `refs/` and `snapshots/` only, and verify the resolved size |
| Every measurement cell refused on a window-boundary race | `t_energy_end = time.time()` could be up to one sampler interval ahead of the newest sample, so the aggregator saw an uncovered window and correctly refused all 25 cells | job 12305215, all cells refused with full samplers | wait `2 x` interval, allow a `3 x` interval tolerance, and report `window_clamped_start_s` / `window_clamped_end_s` so a clamp is never silent |
| TPOT histogram name did not exist | `vllm:time_per_output_token_seconds` is not a metric in vLLM 0.30.0, so the cross-check read `None`, printed `engine 0.0000`, and read as perfect agreement against nothing | **job 12305248** inspected the installed package's metric names directly rather than guessing | real name is `vllm:request_time_per_output_token_seconds`; added `vllm:inter_token_latency_seconds`, which is the engine's own between-token gap and the correct counterpart to client timestamps; `cross_check_usable` makes the no-data state explicit |
| A successful run recorded `CANCELLED` | background `srun` steps were still alive when the batch script exited, so Slurm recorded `CANCELLED 0:15` for a job that produced 25 valid cells | job 12305232 | signal recorded PIDs, `wait`, explicit `exit 0`. Load-bearing for the `afterok` chain, see N16 |
| The verification suite reported FAIL against working code | `verify_fixes.sh` section 1 still grepped for `$STAGED_HF` and `${SLURM_TMPDIR:-/tmp}/hfstage`, both removed by the uniform-path rewrite | PASS=31 FAIL=1 with staging provably live at `stage2_het.sbatch` lines 218, 262, 263, 282 | check rewritten against the current design, plus a new check that per-node readability is verified. PASS=33 FAIL=0 |
| The report could not show the fix it was testing | `het_final.sh` read `server_tpot_mean_s` alone, so a populated engine ITL histogram would never have appeared in any output | found by reading the reporter before the trials finished, not after | prints TTFT, ITL and TPOT; prints `engine ABSENT` rather than `0.0000`; counts missing ITL from the value, not from a flag absent in older runs |
| Status script claimed zero results for a complete run | `het_status.sh` globbed `cell-*.json`; the real layout is one `policies-rate<N>.json` per load level | reported `0 cell file(s)` for 12305232, which has all 25 cells | glob corrected; verified it now reports `5/5 rate file(s), 5 with energy` |

**The pattern worth naming.** Six of these eight were *silent*: they produced
output that looked like a result. The thread-pool ceiling, the `interp` clamp,
the index-order fallback, the absent TPOT histogram, the `CANCELLED` status and
the stale verification check all reported success or agreement. Only the window
boundary and the double-copy announced themselves. That ratio is the argument
for every refusal in the harness and for `verify_fixes.sh` existing at all: the
default failure mode of a measurement pipeline is not a crash, it is a clean
number that means nothing.

**Housekeeping.** GitHub reports one moderate Dependabot alert on the
repository's default branch. It is in dependency metadata for the quarantined
Go tree, touches nothing on the measurement path, and is noted here so it is
not rediscovered as news.

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
| 16 | Verify 2605.23057 and 2603.04445 (framing-only) | **done 2026-10-04**, both fetched; see 12.3 |
| 17 | Cite SPEC PTDaemon, ML.ENERGY, Green500 | **done 2026-10-04**, see 12.7 |
| 18 | Confirm MLPerf PTDaemon / 1% AC figures | **done 2026-10-04 - our claim was WRONG and is withdrawn.** MLPerf Power states no percentage; the 1% is SPEC's overall-uncertainty budget. See 12.7 |
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
| 31b | Re-run Stage 2 with the grounded curve | **DONE 2026-10-04**, jobs 12304137/12304138. Verdict: **GATE FAILED informatively** - every curve-using policy is infeasible, `round_robin` wins. See 12.8 |
| 31c | Repeat trials | **done** - two seeds x two submissions, four runs, ordering identical in all. Formal CIs still to compute for the paper |
| 31g | Node-local model staging (removes the frnt155 hazard) | **done 2026-10-05**, verified by job 12304897: `$SLURM_TMPDIR` is node-local xfs, 3931 MiB/s with 8 readers |
| 31h | Fleet self-balances to the smaller component | **done** - refusing on unequal counts was brittle; `--exclusive` makes unequal the normal case |
| 31i | Stage 2 replication at seeds 11 and 13 | **DONE 2026-10-07.** Seeds 7, 11, 13 are jobs 12305232, 12319685, 12321476. Pre-registered gate: **PASSED**, `energy_consolidate` beats `slo_packing` in all three trials, +2.0%, +1.2%, +1.0%, pooled +1.4%. Small margins; see 12.13a for what three trials can and cannot support |
| 21b | **Re-run the homogeneous arm at 8 GPU on `frnt155`, with staging** | **DONE 2026-10-07, job 12319815, with a design flaw of our own.** `COMPLETED 0:0`, all 25 cells with energy, matched GPU count and matched read path, so N15 is closed. But pinning `RATES` to the heterogeneous ladder drove 8x RTX 6000 far past saturation at 400 req/s and above, where goodput per joule fell to about 0.0001; those cells carry no information. Only 200 req/s, and marginally 300, can be interpreted. See 12.13 and 21c |
| 21c | **Capacity-matched homogeneous control** | **DONE 2026-10-07, job 12321478**, 100-300 req/s on frnt155. Gate FAILED, informatively: every energy-curve policy, and `slo_packing`, has **no feasible point**; `round_robin` is best (0.1682 gp/J at 250 req/s). See 12.13a |
| 31j | Port staging/`wait`/`exit 0` into `stage2_real.sbatch` | **done 2026-10-07.** Both scripts now report `staging=1 wait=1 exit0=1`. Locked in by `verify_fixes.sh` section 11, which fails if either arm loses staging, the offline flag, the fatal-on-failure refusal, the `wait`, or the explicit `exit 0`. Suite now PASS=43 FAIL=0 |
| 31d | Heterogeneous-fleet Stage 2 | **open and now the critical path.** Per-type curves measured (12.9); blocked on multi-node allocation with cross-node energy collection, since NVML is node-local and in-node clock control is denied |
| 31e | Per-GPU-type curves to c=128+ | **done** - A100, A30, L4, L40S, RTX 8000, RTX 6000 (to c=256). V100 excluded, sm_70 absent from the container build |
| 31f | In-node heterogeneity via clock control | **closed - NOT POSSIBLE.** `-pl` and `--lock-gpu-clocks` denied; `--lock-memory-clocks` and `-ac` accept and do nothing (job 12304132: clamped GPU within 1% of an untouched control, reverted run had the lowest clock of the four) |
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
