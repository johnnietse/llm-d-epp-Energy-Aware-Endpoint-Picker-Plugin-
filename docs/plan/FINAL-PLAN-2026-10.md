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
| Marginal power per request | negative slope, indistinguishable from zero | **H1 refuted; do not report a ratio** |
| Idle floor | 54.33 W = 27% of peak-load power | solid |
| Prefix caching | 2.6x better J/total-token, 1.32x more requests | the hypothesised conflict was a metric artifact |
| Cross-node offset, identical model and driver | ~6% at every level, 1.7x in bare idle | needs within-node design |

**Replication honesty:** the characterisation itself is replication.
2608.28044 (IISWC 2026) already published the fixed-plus-marginal decomposition
on H100/H200. Ours is calibration for our system, never a contribution.

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
| **2. GATE: offline bound** | Replay Azure arrivals over the measured curves: round-robin vs SLO-aware packing vs post-hoc oracle | **oracle beats packing by >=5% on energy per SLO-satisfied request, or STOP** and write the measurement/negative-result paper | 1 wk |
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

## 10. One-line status

Measurement apparatus: **sound and reproducible.** Topic: **still open, window
narrowing.** Claim: **narrow but defensible.** Code: **misaligned with the
plan, rescope first.** Blocking gap: **no baselines.**
