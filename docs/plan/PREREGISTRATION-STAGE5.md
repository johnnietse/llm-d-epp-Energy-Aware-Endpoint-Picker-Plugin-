# Pre-registration: Stage 5, energy-aware replica selection in llm-d-router

| | |
|---|---|
| **Status** | **FROZEN 2026-10-09.** Drafted 2026-10-08; the author signed off all six decisions in section 14, each as recommended, on 2026-10-09. |
| **Freezing** | On sign-off, the commit containing this file, `experiments/scripts/prereg_analysis.py` and `experiments/scripts/power_analysis.py` is tagged `prereg-stage5-v1` and pushed. The tag's commit hash and date are the registration record. |
| **Data rule** | No Stage 5 trial may run before the tag exists. Stage 2 data (jobs 12305232, 12319685, 12321476, 12321478) informed every choice below, so it is **pilot data and can never be confirmatory**. |
| **Authority** | Where this conflicts with `FINAL-PLAN-2026-10.md`, this document governs Stage 5. Section 13 records each conflict and its resolution. |
| **Amended** | **2026-10-10, before any Stage 5 trial: section 15, tagged `prereg-stage5-v2`.** Where section 15 conflicts with sections 1 to 14, section 15 governs. `prereg-stage5-v1` is unmoved. |

## 1. Question

From plan section 1: on a shared GPU cluster where the tenant has no privileged
control, does energy-aware **replica selection** inside a production inference
router reduce energy per SLO-satisfied request relative to SLO-aware packing,
and at what cost in tail latency?

Stage 2 narrowed this. The benefit appears on a fleet mixing GPU types and
reverses on a fleet of one type (plan 12.13a). Stage 5 therefore tests the
claim on a mixed fleet, inside llm-d-router rather than in a Python load
generator, and tests the reversal as a separate hypothesis.

## 2. Hypotheses

All three are directional and fixed here. The arms they name are defined in
section 4.

**H1 (primary).** On the mixed fleet, routed by llm-d-router, `energy_consolidate`
achieves higher SLO-goodput per joule than `slo_packing`, each at its own best
feasible operating point. Equivalently, it achieves lower energy per
SLO-satisfied request: the two metrics are exact reciprocals (checked on Stage 2
records, for example 2.8359 J = 1/0.3526).

**H2 (secondary).** On a same-size fleet of one GPU type, `energy_consolidate`
does **not** beat `round_robin`. A trial counts as a reversal when
`energy_consolidate` has no feasible operating point, or its best feasible
SLO-goodput per joule is below `round_robin`'s.

**H3 (secondary).** On the mixed fleet, `energy_consolidate` beats
`energy_greedy`. The two differ by one rule: consolidate prefers an endpoint
that is already busy and wakes an idle one only when no busy endpoint meets the
SLO. H3 therefore isolates that rule, the "activation term" of plan section 6.

H3 was found after the fact in Stage 2: per-trial margins of +0.415%, +0.415%
and +0.490%, consistent but tiny, from a test chosen after seeing the data. It
is registered here precisely so that it can be confirmed or refuted cleanly.

## 3. Outcomes

**Primary outcome:** SLO-goodput per joule (requests that met the SLO, per joule
of GPU energy), equivalently energy per SLO-satisfied request.

- **Operating point:** for each arm in each trial, the offered load among the
  swept levels that maximises SLO-goodput per joule, among levels where SLO
  attainment is at least **95%**. This is `stage2_analyse.best_feasible`
  unchanged.
- **SLO:** end-to-end latency at most **2.0 s**, fixed. In Stage 2 it was
  recomputed per run as twice the slowest type's median single-request latency
  and came out at 2.0 s every time. Fixing it removes a moving part. The
  measured single-request latency is still recorded as a check.
- **Energy:** GPU-package energy from NVML's hardware energy counter, summed
  over all GPUs of the fleet, across each 60 s measurement window. It is **not
  system energy**; plan section 5.1 lists the exclusions, and every published
  number carries that label.
- **Margin:** per trial, `(arm - baseline) / baseline x 100` on the primary
  outcome.

**Secondary outcomes, all reported, none tested:** J per generated token, J per
total token processed, TTFT and ITL at p50, p95, p99 and max, mean TPOT, SLO
attainment per load level, per-GPU energy split, activation counts, EPP decision
time (`request_processing_duration_seconds`), and generator CPU time.

## 4. Design

**Fleets.**

| Fleet | Hardware | For |
|---|---|---|
| Mixed | 4x NVIDIA A100-PCIE-40GB (one node) + 4x Quadro RTX 6000 (one node), as in Stage 2 | H1, H3 |
| Homogeneous | 8x Quadro RTX 6000 on `frnt155` | H2 |

Nodes are pinned with `-w`, per plan section 4. Stage 2's mixed trials did not
pin the RTX 6000 node (12319685 ran on frnt151, 12321476 on frnt149); Stage 5
must (decision D6).

**Arms.** Every arm routes through the same path: client, Envoy 1.39.2, then the
llm-d-router v0.11.0 EPP in file-discovery mode, then vLLM 0.30.0. So any
difference between arms comes from the routing decision, not from
infrastructure. This follows the plan's adopted anti-pattern rule: isolate the
algorithmic change from engineering effort.

| Arm | Role | Implementation |
|---|---|---|
| `energy_consolidate` | **ours** | Go scorer, Stage 4 |
| `energy_greedy` | ablation without the activation term (H3) | Go scorer, Stage 4 |
| `slo_packing` | baseline (H1) | Go scorer, Stage 4 |
| `round_robin` | load-agnostic reference (H2) | Go, Stage 4 |
| `random` | negative control | upstream `random-picker` |
| `stock_llmd` | what an operator gets by default | upstream default scheduling profile at v0.11.0, configuration frozen in the materials addendum |

The three energy-curve arms use the same per-type curves Stage 2 used: A100 from
`h1-12304125` and RTX 6000 from `h1-12304133`. They also use the EPP's own count
of in-flight requests (`inflight-load-producer`), which needs no metrics polling
(plan 12.14b). The EPP runs with `dataLayer.injectDefaults: false`, except in the
`stock_llmd` arm, which keeps upstream defaults.

**Workload.** It is the same as Stage 2, because the variance the sample size
rests on was measured on it:
- open-loop Poisson arrivals;
- prompt lengths from `make_prompt(index, seed)`;
- a fixed 128 output tokens, temperature 0;
- Qwen2.5-1.5B-Instruct;
- offered loads 200, 300, 400, 500 and 600 req/s on the mixed fleet, and 100, 150, 200, 250 and 300 req/s on the homogeneous fleet (inside its capacity, plan 12.13);
- 60 s measurement windows.

**Order and warm-up.** In every trial, a discarded warm-up run precedes **each**
load level, because job 12321497 showed a first-at-new-rate transient. Within
each load level, the arm order is a random permutation seeded by the trial seed,
so slow drift cannot favour an arm that always runs first.

**Seeds, fixed now.** Mixed fleet: trials 1 to 16 use seeds 501 to 516.
Homogeneous: trials 1 to 6 use seeds 601 to 606. Replacement trials (section 7)
use the next unused seeds in sequence: 517 onward and 607 onward.

## 5. Sample size

Computed by `experiments/scripts/power_analysis.py` from the measured Stage 2
margins (`docs/figures/measured/stage2_gate_margins.csv`).

- **Pilot:** three trials, `energy_consolidate` vs `slo_packing` margins +1.982,
  +1.193 and +0.955%; mean +1.377%, SD 0.538.
- **Why not size on 0.538:** an SD from three trials has two degrees of freedom.
  Its 80%, 90% and 95% upper confidence bounds are 1.139, 1.657 and 2.375.
  Sizing on the point estimate would plan an underpowered experiment in most
  plausible worlds.
- **Design target:** detect a true margin of **+1.0%**, below the observed mean,
  with power **0.90** at one-sided alpha 0.025, assuming an SD at its 80% upper
  bound (1.14). This gives **n = 16 mixed-fleet trials**.
- **Robustness of n = 16** at a true margin of +1.0%: power 0.96 if SD = 1.0,
  0.91 if SD = 1.14, 0.70 if SD = 1.5, 0.62 if SD = 1.66.
- **H2:** an exact one-sided binomial test needs all trials to reverse. Six of
  six gives p = 0.0156; five of five gives only 0.031. This gives **n = 6
  homogeneous trials**. Nine trials would tolerate one non-reversal (decision D2).
- **Budget:** about 16 x 50 min of a two-node allocation (six arms instead of
  Stage 2's five, plus per-level warm-ups), and 6 x 55 min on `frnt155`.

## 6. Analysis

The analysis is `experiments/scripts/prereg_analysis.py`, frozen with this file.
It reuses `stage2_analyse.load` and `stage2_analyse.best_feasible`.

| | Test | Alpha |
|---|---|---|
| H1 | one-sample t-test on per-trial margins, one-sided (mean > 0) | 0.025 |
| H2 | exact binomial on reversals vs 0.5, one-sided | Holm with H3, family alpha 0.025 |
| H3 | one-sample t-test on per-trial `energy_consolidate` vs `energy_greedy` margins, one-sided | Holm with H2 |

H1 is reported with its mean margin and two-sided 95% confidence interval
whatever the verdict. Every arm, load level, cell, exclusion and secondary
outcome is reported, not only the tested contrasts.

**Interpretation, fixed now.** If H1 is supported, the claim is that
energy-aware replica selection in llm-d-router improves energy per
SLO-satisfied request on a mixed fleet, by the estimated margin with its
interval. It says nothing about fleets or models not tested. If H1 is not
supported, that is the result, and Stage 7 writes it up as such. It is not a
reason to retune and rerun.

**Pilot run of the analysis on Stage 2 data**, to show the script works. This is
not confirmatory:

```
H1  n=3  mean +1.377%  95% CI [+0.040, +2.713]  t=4.43  one-sided p=0.02366
H3  n=3  mean +0.440%  95% CI [+0.333, +0.547]  t=17.77 one-sided p=0.001576
H2  1 of 1 reversed   one-sided binomial p=0.5   (n=1 cannot pass)
```

## 7. Exclusions and replacement

- **Invalid cell:** client-limited; more than 2% of router picks ungrounded (no
  measured curve for the concurrency); or no energy measurement. These are the
  criteria `stage2_analyse.py` already enforces.
- **Excluded trial:** any invalid cell for an arm that the hypothesis compares
  excludes that trial from that hypothesis. A trial whose baseline has no
  feasible point is excluded, because the comparison is undefined. A trial
  where the tested arm has no feasible point but the baseline does counts at
  **-100%**, the conservative choice against H1 and H3.
- **Replacement:** an excluded trial is replaced with the next pre-listed seed.
  **At most 4 replacements** on the mixed fleet and 2 on the homogeneous one. If
  more are needed, collection stops and the study is reported as a protocol
  failure with its reasons, rather than replacing until it works.
- **Infrastructure failures** (a job that dies, a node that wedges) are
  re-submitted with the **same** seed, and the failure is logged. A completed
  trial is never re-run.

## 8. Stopping

The sample size is fixed. There is no interim test of any hypothesis. During
collection only integrity outputs may be acted on: whether a job completed,
whether cells are valid, and whether records were fetched. Per-cell results will
be visible in job logs, and no decision to stop, extend, exclude or change
anything may use them. Any such decision outside the rules in section 7 is a
deviation (section 9).

## 9. Deviations

Any change after the tag is recorded in a "Deviations" section appended to this
file, with date, what changed, why, and whether it could affect a verdict. The
tag is never moved.

**Materials addendum, the one permitted change before trial 1.** Stage 4 builds
what this design needs: the Go arms, the EPP configs, router mode in the
generator, arm-order randomisation and per-level warm-up. These are committed as
an addendum, tagged `prereg-stage5-v1-materials`, **before trial 1**. The
addendum may add implementations and configs only. It may not change
hypotheses, outcomes, operating-point rule, SLO, alpha, sample size, seeds,
exclusion rules or analysis code.

## 10. What Stage 4 must deliver before trial 1

1. Go scorers for `energy_consolidate`, `energy_greedy`, `slo_packing` and
   `round_robin`, consuming the per-type curves and the EPP's in-flight count.
2. A fidelity test: on recorded fixtures (endpoint states plus curves), each Go
   scorer picks the same endpoint as the Python policy in `policy_harness.py`.
   This shows the router delivers the rule Stage 2 measured, not a lookalike.
3. Router mode in the generator: every request goes to the Envoy listener, and
   the EPP chooses. Per-GPU energy is still taken on each node.
4. Seeded per-level arm-order randomisation and per-level warm-up.
5. The `stock_llmd` configuration, recorded verbatim.

## 11. Threats this design does not remove

Stated now so they cannot be discovered later as excuses:
- GPU-package energy only, not system energy.
- One model, one output length and synthetic prompt lengths. The trace replay
  the plan names was never built (decision D1).
- Two GPU types from one vendor.
- Static endpoints: no pods joining or leaving.
- Loopback and in-cluster networking.
- The generator shares a node with servers (plan threat N9), measured through
  `generator_cpu_s`.
- `stock_llmd` and `random` are references, not tested hypotheses.
- Slurm records heterogeneous jobs as `CANCELLED` even when complete (plan N16).
  Validity is judged from records, never from Slurm state.

## 12. Data and code

- Raw records are committed under `experiments/cluster-records/` using the
  existing fetch path.
- `make_figures.py` and `prereg_analysis.py` run from the committed records with
  no cluster.
- The EPP binary is built reproducibly by `router-plugin/build.sh`, and its
  sha256 is recorded per job.

## 13. Conflicts with the plan, resolved

| Plan says | Resolved as | Why |
|---|---|---|
| Stage 5 on "one node, exclusive" | two nodes: A100 + RTX 6000 | Frontenac nodes hold one GPU type each, and in-node heterogeneity via clocks is denied (tracker 31f). The effect needs a mixed fleet. |
| Primary metric "energy per SLO-satisfied request" (section 5); the gate uses SLO-goodput per joule | both; they are exact reciprocals | checked on Stage 2 records |
| ">= 5 trials" | 16 mixed, 6 homogeneous | power analysis, section 5 |
| Arms include "ours-without-activation-term" | `energy_greedy` | that is exactly consolidate minus the activation rule (`policy_harness.py`) |
| "Open-loop Poisson from the trace" | Poisson with the Stage 2 prompt generator; trace deferred | no trace is specified or implemented, and the variance was measured on this workload (decision D1) |
| SLO stated as TTFT/TPOT targets (section 5) | end-to-end 2.0 s | what every Stage 2 result used; TTFT and TPOT reported as secondary |

## 14. Decisions, signed off by the author on 2026-10-09

Every decision was accepted as recommended. The design above already reflected
the recommendations, so signing off changed no other part of this document.

| | Decision | Adopted |
|---|---|---|
| D1 | Workload: the Stage 2 generator (as drafted), or specify and build trace replay first | **Stage 2 generator.** The variance and n rest on it. Trace replay as a separately registered follow-up. |
| D2 | H2 trials: 6 (all must reverse) or 9 (tolerates one) | **6.** The observed reversal is total: the energy arms were infeasible. |
| D3 | One-sided alpha 0.025 | **Yes.** It equals two-sided 0.05 and suits directional hypotheses. |
| D4 | Every arm through the router, which means Stage 4 implements four Go scorers | **Yes.** Otherwise router overhead and algorithm are confounded. |
| D5 | Include `stock_llmd` and `random` (adds about 8 min per trial) | **Yes.** They are the reference points a reviewer will ask for. |
| D6 | Pin the RTX 6000 node, choosing frnt149 or frnt151, alongside A100 on frnt154 | **Pin both.** If a pinned node is unavailable, wait. Substituting is a deviation. |

## 15. Amendment 1, 2026-10-10, before any Stage 5 trial

**Status: FROZEN by tag `prereg-stage5-v2`.** Sections 1 to 14 are the v1
registration, unchanged except for the "Amended" row of the header table.
Where this section conflicts with them, this section governs. No Stage 5
trial had run when this was written or tagged, so it is an amendment, not a
deviation (section 9). Tag `prereg-stage5-v1` stays where it is. Every
choice below was made by the author before the data that tests it; the plan
(`FINAL-PLAN-2026-10.md`, 12.14d) records each one with its commit.

### 15.1 Why

The audit of 2026-10-09 found four problems with the v1 design.

1. **Unequal binding constraints.** On the mixed fleet the A100 curve
   stopped at 128 concurrent requests, so packing there was capped near
   0.9 s. On the one-type fleet the RTX 6000 curve reached 256, so packing
   ran until predicted latency equalled the 2.0 s SLO, and every packer,
   `slo_packing` included, missed the SLO for 17-70% of requests. H2 would
   have tested that zero-margin aim, not fleet homogeneity.
2. **The latency model was blind to queueing.** Closed-loop curves hold
   concurrency fixed. Under Poisson arrivals near vLLM's batch limit the time
   goes to TTFT, which they never see. A first calibration on closed-loop
   curves (rule a21651b, three seeds from b0e5356) found no qualifying
   headroom at all (records 0ad7dee).
3. **The baseline's tie-break favoured the A100s.** Python's `max` and `min`
   return the first of equals, and the fleet lists the A100s first. So the
   energy-blind `slo_packing` filled A100s from list order alone, and the
   Stage 2 +1.4% was measured against a baseline that order helped.
4. **Section 4 misstates the one-type fleet's capacity.** It calls 100-300
   req/s "inside its capacity". By the SLO, the fleet holds about 265 req/s
   (about 33 req/s per RTX 6000 at p95 = 2.0 s); 300 req/s is beyond it. That
   figure came from the RTX 6000's stationarity limit (about 61 req/s per GPU)
   where the SLO limit applies.

### 15.2 Changes

**B1. Router latency model: open-loop curves, routing on p95 (approach A,
author decision 6c0deae).** Each GPU type is measured under Poisson arrivals
at fixed rates (`openloop_curve.sbatch`). Each rate gives mean in-flight
(Little's law, from the realised rate) and p95 end-to-end latency. A packing
policy admits an endpoint while the p95 interpolated at its next in-flight
level is at most (1 - h) x 2.0 s. A curve ends at the first rate any trial
could not keep up with; above its last stationary point an endpoint is
infeasible. The router never counts on more than **256** in flight per
endpoint (`--max-inflight 256`). This replaces the closed-loop model for
`energy_consolidate`, `energy_greedy` and `slo_packing`.

**B2. Curves.** The energy-curve arms use:
- **A100:** `olc-12325349` (frnt154, 6 trials, seed 701, 4-202 req/s,
  steady to 128 req/s at p95 1.20 s);
- **RTX 6000:** `olc-12325350` (frnt149, 6 trials, seed 701, 1-74 req/s,
  steady to about 61 req/s).

These replace section 4's `h1-12304125` and `h1-12304133`. The closed-loop
curves `h1-12324871`, `h1-12324872`, `h1-12325153` and `h1-12325154` are kept
as records and are not used.

**B3. vLLM batch limits pinned.** Every server runs with
`--max-num-seqs 256 --max-num-batched-tokens 2048`. These are vLLM 0.30.0's
own defaults for GPUs under 70 GB, now set explicitly. A job aborts unless
each server's own log reports both values. The curve selector accepts only
curves measured with the same limits. The vLLM-limit sensitivity study
(`SENSITIVITY-VLLM-LIMITS.md`) is exploratory and cannot change these
values.

**B4. Headroom h = 0.** The packers admit up to (1 - h) x 2.0 s with
**h = 0**.
- **Calibration v3** (`headroom_calibrate.py`, seeds 911-913; one-type jobs
  12325359/62/65, mixed 12325360/63/66) chose the smallest qualifying h. Every
  h qualified, and at h = 0 all 36 combinations met the SLO for 100% of
  requests with no saturated or ungrounded picks (records ad2b6bc).
- **Validation, rule v1** (`validate_h0.py`, d4029c3) **FAILED**, 81 of 90
  (records 93516d7). It failed only on the one-type fleet at 300 req/s,
  because its premise used the stationarity limit (15.1, item 4). That
  verdict stays on record.
- **Validation, rule v2** (`validate_capacity.py`, ebaeac8, committed before
  its reference runs) **PASSED** (records 6cfd543). At 300 req/s on the
  one-type fleet, `round_robin` and `least_loaded` met the SLO for only
  12-26% in all three seeds (jobs 12330546/47/48), so that cell is beyond
  fleet capacity. All 81 other combinations passed at h = 0.
- **Limitation, recorded:** calibration covered the mixed fleet only at 300
  and 400 req/s, where the packers used only A100s. The validation covered
  200-600 req/s, where both types carry traffic.

**B5. Random tie-break, all arms.** Every minimum or maximum pick among tied
endpoints is uniform over the tied set, from a stream seeded by the trial
seed (`--tiebreak random`, d4029c3). On the real curves over 200 seeds,
`slo_packing` then first picked an A100 107 times and an RTX 6000 93 times,
against 200 of 200 by list order. The energy arms still picked A100 200 of
200, because they choose by energy, not by order.

**B6. Load ladders unchanged; capacity stated correctly.** The ladders stay
200-600 req/s mixed and 100-300 req/s one-type, the levels the pilot
variance was measured on.
- **Mixed fleet:** about 640 req/s of SLO capacity (4 x 128 + 4 x 33), so
  all five levels are within it.
- **One-type fleet:** about 265 req/s, so 300 req/s is beyond it. It stays
  because the operating-point rule takes each arm's best feasible level and
  never selects a level by its result. The level marks where every arm's
  frontier ends.

This corrects the wording of section 4 and changes no rule.

**B7. llm-d's own SLO-packing baseline.** A seventh arm, `llmd_latency_least`:
- **What it is:** llm-d-router v0.11.0's `slo-headroom-tier-filter` with
  `latency-scorer`, strategy `least` ("prefer endpoints closest to SLO"), fed
  by the `llm-d-latency-predictor` service.
- **SLO split:** its per-request TTFT and TPOT SLOs satisfy
  TTFT + 127 x TPOT = 2.0 s. The split follows Stage 1's median TTFT share
  of end-to-end latency at concurrency 1 on the RTX 6000. It is recorded in
  the materials addendum before trial 1.
- **If it cannot run:** if the predictor service cannot run on Frontenac, the
  arm and H4 are dropped **before trial 1**, the reason is recorded in the
  materials addendum, and nothing else changes.

**B8. New secondary hypothesis H4.** On the mixed fleet, `energy_consolidate`
beats `llmd_latency_least` on SLO-goodput per joule, each at its best
feasible point. It is tested like H3, by a one-sided t-test on per-trial
margins, and joins the secondary family: **Holm over {H2, H3, H4}** at family
alpha 0.025. If B7 drops the arm, the family is {H2, H3} as in v1.

**B9. Nodes.** The mixed fleet is frnt154 (A100) plus frnt149 (RTX 6000), and
the one-type fleet is frnt155, all pinned. This settles D6's "frnt149 or
frnt151".

**B10. Sample size: 25 mixed-fleet and 25 one-type trials** (author decision
2026-10-09). This replaces section 5's 16 and 6. `power_analysis.power` at a
true margin of +1.0% and one-sided alpha 0.025:

| SD | n = 16 (v1) | n = 25 |
|---|---|---|
| 1.14 (80% upper bound) | 0.91 | 0.99 |
| 1.50 | 0.70 | 0.89 |
| 1.66 (90% upper bound) | 0.62 | 0.82 |

The smallest margin detected with power 0.90 at SD 1.14 falls from 0.99% to
0.77%.

For H2, the exact binomial over 25 trials needs at least 19 reversals at
Holm's strictest step (alpha/3), tolerating 6 non-reversals, or 18 at its
last step (alpha), tolerating 7. Six trials needed all six.
- **Seeds:** mixed trials 501-525, one-type trials 601-625.
- **Replacement seeds:** continue from 526 and 626.
- **Replacement caps:** **6 per fleet**, about v1's proportion of 4 in 16.

**B11. What Stage 4 must also deliver** (adds to section 10).
- **The Go scorers implement B1, B4 and B5:**
  - interpolated open-loop p95;
  - infeasible above a curve's last stationary point;
  - the 256 cap;
  - h as a parameter, run at 0;
  - the seeded random tie-break.
- **The fidelity test checks** that, on recorded fixtures, the Go pick equals
  the Python pick when there is no tie, and lies in the Python tied set when
  there is one.
- **The `llmd_latency_least` configuration and its SLO split** are recorded
  verbatim in the materials addendum.

**B12. Pilot data.** None of the following is ever confirmatory, like
Stage 2:
- the curves;
- every calibration, validation and capacity-reference job;
- the vLLM-limit sensitivity study.

### 15.3 What does not change

- H1, H2 and H3 as worded.
- The primary outcome, the operating-point rule and the 2.0 s SLO.
- One-sided alpha of 0.025 for H1.
- The workload, per-level warm-up and arm-order randomisation.
- The exclusion criteria (only the replacement caps change, B10).
- The stopping rule and the materials-addendum procedure.

The SD is not re-estimated. The pilot SD came from the old router model, and
the new design has no trial-to-trial variance yet; estimating it would mean
running confirmatory-style trials before the freeze. n = 25 keeps power at or
above 0.82 up to the SD's 90% upper bound. If the true SD is larger still,
the result is reported as underpowered, not re-run.

### 15.4 Analysis

`prereg_analysis.py` gains the H4 comparison and the three-member Holm
family in the commit tagged `prereg-stage5-v2`. H4 joins the family exactly
when the arm is present in the data, and B7 settles that before trial 1. The
H1 path is unchanged.

Checked before tagging:
- **Pilot data:** on the Stage 2 pilot (mixed 12305232, 12319685 and
  12321476; one-type 12321478), the script reproduces section 6's output
  exactly.
- **H4 path:** run once on a throwaway copy of those records with one arm
  relabelled. It produced margins and a three-member Holm family. That copy
  is a code test, not data, and was not kept.
