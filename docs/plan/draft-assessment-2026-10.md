# Assessment of the eight existing drafts (2026-10-03)

Eight zips were supplied. They are versions of one document, not eight papers.
Extracted to `C:\Users\Johnnie\paper-drafts\`.

## 1. Inventory

| Draft | Live body | Bibitems | Verdict |
|---|---|---|---|
| `new_new_new___June_4_latest` | 1209 lines, ~25k words raw | 37 | **Most complete body.** Canonical for prose. |
| `Energy` | 888 lines | 34 | Earlier version of the same body (425 differing lines). |
| `New_New_New_...` | 849 lines | 34 | Earlier still (518 differing lines). |
| `Energy_Aware_..._Research_Paper` | 398 lines | **92** | Condensed IEEE-style variant. **Best bibliography** (throttLL'eM, Perseus, Zeus, Splitwise; 44 refs from 2024, 16 from 2026). |
| `New_New_...`, `New_...`, `ieee_research_report`, `new` | 222-972 lines | few | Fragments and early cuts. Archive only. |

Note: every `main.tex` carries a large commented-out older article version
above the live thesis. That is dead weight and a merge hazard.

**Consolidation decision:** body from `June_4_latest`, bibliography from the
92-ref variant. Everything else is history.

## 2. What the drafts claim

Hypothesis: phase decomposition plus epsilon-constraint Pareto optimisation lets a
Kubernetes-native scheduler cut energy-per-token and SCI "without violating
deterministic bounds on TTFT and TPOT", with an adaptive FSM responding to grid
carbon signals.

Five stated contributions: phase-aware energy scoring; epsilon-constraint SLO
filtering; disaggregated KV-cache energy model; "first known" Kubernetes-native
SCI implementation; adaptive weight controller with Schmitt-trigger hysteresis.

## 3. The problem

**The evidence base is simulation, and the drafts say so.**

- Line 1045: physical access to diverse accelerators is "financially
  prohibitive", so hardware power characteristics are *calibrated profiles*.
- Line 1205, limitations: "Simulation Dependency ... evaluations rely on
  calibrated simulation profiles rather than a massive, physical multi-node
  datacenter deployment."
- Line 1886: the headline evaluation is a "1000-cycle routing simulation
  (99.8% prefill, 100% decode accuracy)".

Being explicit about this is to the drafts' credit. But the 99.8%/100% figures
are not findings: the weight vectors were chosen so that high-TDP GPUs win
prefill and low-power parts win decode, and the simulation then reports that
they do. A reviewer will read it as a tautology, and Levin and Redell's test
("is the system real?") is answered unfavourably.

**Three claims are now contradicted or pre-empted by evidence we collected
since:**

| Draft claim | Current evidence |
|---|---|
| Phase-aware weights over latency/energy/carbon sub-scores, with TDP as a latency proxy | Measured: active power is near-constant (202 +/- 8 W over a 32x load range). TDP-proportional scoring has no measured basis; `J/token = P_active / throughput` does. |
| Linear energy modelling per endpoint | `P_idle + k_b*b` fits our data at R^2 = 0.37. Refuted. |
| "First known" Kubernetes-native SCI / energy-aware scheduling contribution | arXiv 2609.05565 proposes exactly this control plane for llm-d (agenda, unimplemented); Festina (2606.30391) already does energy-aware request routing with consolidation, 56% saved; 2608.06188 publishes the same concurrency-sweep characterisation (28-32x). See `research-validity-review-2026-10.md`. |

**Carbon:** the drafts lean heavily on carbon (139 occurrences) and an FSM
reacting to grid signals. Within one cluster every endpoint shares a grid, so
the carbon term is collinear with the energy term; it only separates across
regions or over time. The FSM is a weight-scheduling mechanism, not a measured
result, and nothing in our data supports or refutes it yet.

## 4. What is salvageable

- The **implementation and architecture chapters** describe a real Go plugin
  and a real integration surface. That is the surviving contribution per the
  validity review, and it is already written.
- The **92-item bibliography** is a genuine asset; it covers throttLL'eM,
  Perseus, Zeus and Splitwise.
- The **epsilon-constraint framing** (SLO as a hard filter, energy optimised
  within the feasible set) is sound and matches how the upstream router
  actually composes filters and scorers.
- **Figures and diagrams** are reusable where they describe architecture, not
  results.

## 5. What has to change before submission

1. **Replace simulated results with the hardware measurements.** We now have
   real numbers from `frnt152`/`frnt140`: idle 22.0 W bare, 54.6 W model
   resident, ~190-212 W active, J/token 1.65 -> 0.078 across concurrency 1-32.
   Delete the 1000-cycle win-rate evaluation entirely; it cannot be defended.
2. **Restate the hypothesis** around the measured cost structure: activation
   dominates (+135 W) versus marginal concurrency (+0.46 W), so the lever is
   placement, not weight tuning.
3. **Drop or demote** the ASIC/Qualcomm heterogeneity story, the carbon FSM,
   and SCI as headline contributions. Keep SCI as an optional reporting metric.
4. **Rewrite related work** against the 2026 literature (Festina, SICP agenda,
   TokenPowerBench, Watt Counts, the characterisation papers). The current
   related work predates all of it.
5. **Re-scope the claim** to what the validity review concluded: energy-aware
   endpoint selection inside a production open-source router, composed with its
   SLO and prefix-cache plugins, under no privileged control, upstreamed.
6. **Strip the commented-out article version** from the canonical `main.tex`.

## 6. Recommendation on running the full ARS pipeline now

**Do not run the full six-phase pipeline yet.** It would produce a polished
report over an evidence base that cannot support the claims, and the expensive
agents (synthesis, report compiler, editor) would be re-run from scratch once
the real evaluation lands.

Sequence that wastes nothing:

1. **Now:** consolidate to one canonical draft (done, see repo `paper/`), and
   run the *targeted* parts of the pipeline only - `lit-review` to rebuild
   related work against 2026 sources, and `review` on the implementation
   chapters, which are already final.
2. **After Stage 2 of the plan** (the go/no-go gate in
   `technical-plan-v2-2026-09.md`): the claim is either confirmed or becomes a
   negative result. Only then does the hypothesis stop moving.
3. **After Stage 4** (the real experiment with baselines and CIs): run
   `ars-full` on the complete material. That is when the report compiler and
   editor-in-chief passes pay for themselves.

The binding constraint on this paper is evidence, not prose.
