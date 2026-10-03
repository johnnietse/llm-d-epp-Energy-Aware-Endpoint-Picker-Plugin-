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

## 6. Step-by-step path, with gates

| Stage | Work | Exit criterion | Est. |
|---|---|---|---|
| **0. Rescope the code** | Tag `pre-rescope-2026-10-03`; quarantine per section 2; delete `pkg/simulation` and `upstream-port`; stand up the out-of-tree module against llm-d-router | module builds and registers against current llm-d-router | 2-3 d |
| **1. Characterise** | Sweeps on A30 (`frnt140-147`) and L4 (`frnt201`), plus a 7B model, each pinned by node and driver | per-configuration `P_active` and throughput curves with CIs | 1-2 wk |
| **2. GATE: offline bound** | Replay Azure arrivals over the measured curves: round-robin vs SLO-aware packing vs post-hoc oracle. **Load must be high enough to saturate the dominant GPU type**, or the result is trivially "prefer A30" (see 3.1b) | **oracle beats packing by >=5% on energy per SLO-satisfied request in the saturated regime, or STOP** and write the measurement/negative-result paper | 1 wk |
| **3. Pre-register** | Commit hypotheses, primary metric, policies, trial count from a power analysis on measured variance, and the analysis script, timestamped in-repo before any comparative run | pre-registration committed and pushed | 2 d |
| **4. Build the scorer** | `pkg/scorer/activation.go` + tests behind the SLO filter | unit tests pass against recorded fixtures; p99 scorer CPU time recorded | 2 wk |
| **5. The real experiment** | One node, exclusive, open-loop Poisson from the trace, >=5 trials, 5 arms: stock llm-d, round-robin, SLO-aware packing, ours, ours-without-activation-term, plus random control | all metrics in section 5 with 95% CIs | 2-3 wk |
| **6. Secondary results** | Per-die heterogeneity (section 13.5 design); matched-prompt-length cache experiment if time allows | either a measured effect or a clean null with the within-die control | 1 wk |
| **7. Write and upstream** | Thesis first, paper distilled from the same experiments; submit the artifact PR regardless of outcome | PR open; thesis chapter draft | 3-4 wk |

**Stage 2 is the honest decision point.** With active power near-constant and
the marginal term at zero, routing-only savings may be small once SLO
constraints bind. Finding that out offline costs a week; finding it out after
building costs two months.

---


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
| B3 | Underpowered, one model, one output length, closed-loop | partly closed (5 trials, CIs); model size, output length and open-loop remain |
| B4 | Co-tenancy | **closed** by `--exclusive` with a recorded guard |
| S1 | Prefix-cache result backwards | **closed** — metric artifact, resolved |
| S2 | No sensor characterisation | open; DCGM cross-check available, but it is the same counter |
| S3 | Activation cost imprecisely defined | now operational: power at c=1 minus power at c=0 with model resident |
| S4 | Per-request attribution under batching | open, stated as an assumption |
| **N1** | **"No privileged control" is partly an artifact of our account** | open. Mitigation: argue from the measured permission non-uniformity that a tenant genuinely cannot rely on privilege. |
| **N2** | Effect size may be too small to matter | open. This is what Stage 2 exists to settle. |
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

## 12. One-line status

Measurement apparatus: **sound and reproducible.** Topic: **still open, window
narrowing.** Claim: **narrow but defensible.** Code: **misaligned with the
plan, rescope first.** Blocking gap: **no baselines.**
