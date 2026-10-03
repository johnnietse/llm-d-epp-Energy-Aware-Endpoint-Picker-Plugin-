# Research Validity Review (2026-10-03)

Scope: is the current setup valid for a publishable paper, is the topic still
open, and is the approach sound? Based on the measurements in
`experiments/h1-2026-10-03/` and a literature check run the same day.

Verdict in one line: **the engineering is sound and the topic is still open,
but the contribution as currently framed is mostly replication. The claim has
to be narrowed to the integration, not the measurement.**

---

## 1. Literature check: what already exists

| Work | What it does | Overlap with us |
|---|---|---|
| "Toward Sustainable Distributed LLM Inference ... llm-d Control Plane" (arXiv 2609.05565) | Agenda/synthesis paper proposing a Sustainable Inference Control Plane for **llm-d**. States plainly: "this section is a design proposal ... not a description of functionality that is already implemented in llm-d", contains **no experiments**, and lists **energy-aware endpoint selection** as future work. | **Our exact topic, unimplemented.** This is the strongest citable statement that the gap is real, and the clearest warning that others are circling it. |
| Festina, "Energy-Aware Scheduling for Serverless LLM Serving on Shared GPUs" (arXiv 2606.30391) | Request routing by GPU clock-frequency match + SM partitioning + consolidation with GPU deactivation. 8x H100, vLLM, MPS. Up to **56% energy** saved, SLO within 2%. Ablation: dispatch 12%, runtime 25%, consolidation 11%. | **Strongest competitor.** Already does energy-aware request routing *and* consolidation. Differences: serverless multi-model, needs MPS + frequency control (root), bespoke system, homogeneous H100. |
| "Routing LLM Inference to the Cleanest Grid in Real Time" (arXiv 2608.06188) | Carbon-aware routing on a production fabric, **region-level**, with offline concurrency sweeps on H100/A100 via DCGM; J/token falls **28-32x** low to saturating concurrency (H100 3.37 -> 0.104 J/token). | Their Phase-0 characterization is methodologically the same as our H1 sweep, and their 28-32x brackets our 21x. **Our measurement is replication.** Their routing is across regions, not endpoints. |
| "Characterization of Request and Token Energy Costs" (arXiv 2608.28044) | Decomposes request energy into **fixed per-request + marginal per-token**, across models, phases, batch sizes, H100/H200. | Same decomposition we arrived at. Our "activation vs marginal" framing is not new. |
| "The Energy Cost of Execution-Idle in GPU Clusters" (arXiv 2604.04745, Lei et al., 2026-04-06) | **CORRECTED 2026-10-03** after fetching the abstract: execution-idle is **19.7% of execution time and 10.7% of energy** in their cluster telemetry, with two prototype mitigations (automatic downscaling, load imbalancing). An earlier version of this table recorded "mean idle time 53% to 96%", which is **not in the paper** and must not be cited. | Covers the idle-floor argument we were planning to make, but the magnitude is far smaller than we had written down, so our 27% idle floor is not corroborated by it and must stand on our own measurement. |
| TokenPowerBench (AAAI), Watt Counts (arXiv 2604.09048), ML.ENERGY | Phase-aware J/token benchmarks across batch sizes, GPUs, models. Batch effect saturates near 256. Watt Counts notes A30 is unusually efficient for small/medium models. | Our batching curve is a smaller-scale instance of these. |
| "Measured Joules, Learned Routes" (arXiv 2609.23085) | RL router choosing **which model** (0.5B-32B) answers a query; ~23% less energy at similar accuracy. | Different decision (model selection, not replica selection). Not a direct competitor. |

### 1.1 Verification pass and newly found prior art (2026-10-03)

Every identifier in the table above was fetched and checked against the live
arXiv record on 2026-10-03, rather than carried over from an earlier session.
All five exist and the titles match. Two substantive notes:

- **2604.04745's figures were recorded wrongly here** (see the corrected row).
- **2608.06188's headline is simulated.** Its ~51% emissions reduction comes
  from a year-long historical replay against round-robin and is stated as an
  upper bound; the live portion demonstrates steering without failures. Our
  measured comparison is therefore not competing with a measured result.

Prior art the earlier check missed, found by search on 2026-10-03:

| Work | What it is | Relation to us |
|---|---|---|
| **vLLM semantic-router issue #2332**, "Connect semantic routing to inference-aware backend selection" | **Open** epic defining an engine-neutral observation contract that explicitly includes "energy/power evidence and its measured/modeled provenance". Planning/early development; energy is one optional field among capacity and latency signals. | **The most important new finding.** A *second* production router is building the plumbing for energy-aware backend selection. Still unimplemented, so the gap is open, but we are no longer the only party moving, and the window is narrowing. |
| "The Workload-Router-Pool Architecture..." (arXiv 2603.21354, vLLM Semantic Router project) | **Vision paper**, 21 proposed research directions, names "fleet provisioning and energy-efficiency analysis" as an area. No measured energy outcomes. | A second agenda paper alongside 2609.05565. Both are citable evidence that the gap is acknowledged and unfilled. |
| GreenServ (arXiv 2601.17551) | LinUCB multi-armed bandit routing across **16 different models**, measuring GPU energy directly online; 31% less energy, 22% better accuracy against random routing. | **Model** selection, not replica selection. Same category as 2609.23085. Not a direct competitor, but it is a strong energy-routing result that a reviewer will expect us to position against. |
| RequestRouter (arXiv 2605.23057) | Request-boundary routing for a **single** GPU, 8B model on A100 via vLLM; 2.10x latency speedup, 0.48x energy ratio over FP16. | Intra-GPU scheduling, not fleet endpoint selection. Shows the energy-routing framing is active at every granularity. |
| "Dynamic Model Routing and Cascading..." (arXiv 2603.04445) | Survey of model routing and cascading. | Use for related-work framing; confirms model routing is a crowded area and replica routing is not the same thing. |

The practical consequence: **our claim must be stated as replica/endpoint
selection among interchangeable backends of the same model**, explicitly
distinguished from model selection, which is where most 2026 energy-routing
work sits. If that distinction is not made in the abstract, a reviewer will
mistake the contribution for a crowded one.

### What this does to our contributions

The four contributions in the plan, re-scored:

1. ~~Measurement: load-dependent power and J/token curves~~ -> **replication**. 2608.06188, TokenPowerBench and Watt Counts have published this on better hardware with more models. Keep it as *calibration for our system*, not as a contribution.
2. ~~Design: marginal-energy model~~ -> **partially pre-empted** by 2608.28044 (fixed + marginal decomposition) and Festina (energy-aware dispatch).
3. Evaluation -> still ours, but only meaningful against the baselines we have not yet run.
4. **Artifact: energy-aware endpoint selection inside llm-d** -> **this is the surviving contribution**, and 2609.05565 states explicitly that it does not exist.

### Remaining defensible claim

> The first implementation of energy-aware endpoint selection **inside a
> production open-source inference router** (llm-d), composed with that
> router's existing SLO and prefix-cache machinery, evaluated on a shared
> multi-tenant cluster **without privileged control** (no DVFS, no MPS, no GPU
> deactivation), with the artifact upstreamed.

Every clause there is doing work:
- *inside llm-d*: Festina and Solyx are bespoke systems; ours is a plugin others can adopt.
- *composed with SLO and prefix-cache scorers*: the interaction between
  cache-affinity routing and energy routing is genuinely unstudied, and our own
  data already shows a conflict (section 3.4).
- *without privileged control*: Festina's three levers (frequency match, SM
  partitioning, consolidation-with-deactivation) all require privileges a
  normal cluster user does not have. What is left when you cannot touch clocks
  or power states is exactly the routing decision, and nobody has isolated it.

That is a workshop paper (HotCarbon-scale), not a full conference paper, unless
the evaluation grows substantially.

---

## 2. Is the current setup valid for a paper?

The engineering is sound; the **experimental design is not yet publishable**.
Specific defects, in the order they would be attacked by a reviewer:

### 2.1 Blocking defects

| # | Defect | Why it invalidates | Fix |
|---|---|---|---|
| B1 | **GPU type varies between runs.** Jobs landed on frnt140 (A30), frnt152 (RTX 6000), frnt108 (RTX 6000) because the scheduler chose. The smoke test and the H1 sweep ran on *different GPUs*. | Any cross-run comparison confounds policy with hardware. | Pin hardware per experiment: `-w <node>` or `-C <feature>`, and record it per row (already in `instruments.txt`). |
| B2 | **No baselines.** We have one policy (stock scorers) and no spread/pack/oracle comparison. | The central claim is comparative; there is currently nothing to compare. | Run round-robin, SLO-aware packing, and the offline oracle on identical traces. |
| B3 | **n = 2 trials, 75 s windows, one model (1.5B), one output length (128), closed-loop synthetic prompts.** | Underpowered and unrepresentative; no confidence intervals; closed-loop load cannot show queueing behaviour under bursty arrivals. | >= 5 trials, >= 2 model sizes, open-loop Poisson arrivals from the Azure trace, mixed output lengths, report mean +/- 95% CI. |
| B4 | **Shared nodes, no exclusivity.** Other users' jobs can share the node and the measurement window. | Contaminates every power number. | Record co-tenancy per run (`nvidia-smi --query-compute-apps`), discard contaminated runs, request a reservation for the final campaign. |

### 2.2 Serious but non-blocking

| # | Defect | Fix |
|---|---|---|
| S1 | ~~**Prefix-cache result is backwards and unexplained**~~ **RESOLVED 2026-10-03 (job 12303088)**: a metric artifact. The shared-prefix arm carries 8.5x more prompt tokens, and J/*generated* token penalises it for the extra prefill. Per *total* token processed it is 2.6x better and it completes 1.32x more requests. See plan section 11.5. | No fix needed. Instead: report both denominators everywhere, and treat section 3.4 below as withdrawn pending a matched-prompt-length test with a measured hit rate. |
| S2 | **No sensor characterization** on these GPUs. We rely on the NVML counter but have not measured its sampling behaviour on RTX 6000 / A30. | Run the SC24 `GPU_Power_Benchmark` microbenchmark; and on the A30 nodes use the `power_ipmi` feature for an independent node-level cross-check. |
| S3 | **"Activation cost" is imprecisely defined.** The +135 W step from idle-with-model to concurrency 1 bundles the transition *and* the first request's compute. | Define it operationally (power at c=1 minus power at c=0 with the model resident) and say so, or measure a true activation transient. |
| S4 | **Energy attribution is per-GPU, not per-request.** We divide by engine token counters. | Fine, but state it as an assumption; per-request attribution under batching is not identifiable from GPU-level counters alone. |

### 2.3 What is already publication-grade

- Counter-based energy rather than integrated power polls, with the SC24 sampling caveat understood.
- Token counts from the engine's own Prometheus counters, not estimated.
- `instruments.txt` per run (GPU, driver, power limit, vLLM/torch versions, image size) - this is exactly the reproducibility table reviewers ask for.
- The whole path is scripted and re-runnable from one `sbatch` command.
- `J/token = P_active / throughput` reproduced to 0.0% error on all 12 points - an internally consistent dataset.

---

## 3. Is the approach valid?

Mostly yes, with two corrections.

### 3.1 The model form is now correct

H1's linear `P_idle + k_b*b` failed (R^2 = 0.37); active power is near-constant
(202 +/- 8 W over a 32x load range). The replacement -
`J/token = P_active / throughput(b)` plus an activation term - is both better
supported by our data and consistent with 2608.28044's fixed-plus-marginal
decomposition. Keep it.

### 3.2 The routing claim needs a sharper mechanism

With power near-constant when active, "minimise marginal energy" collapses to
something simpler and more defensible: **finish the work on the fewest
GPU-seconds of active time, and avoid activating idle GPUs**. That is a
scheduling claim, not an energy-model claim, which is good: it is testable
without a precise power model.

### 3.3 Scope that is now out

Festina already covers frequency matching, SM partitioning and
consolidation-with-deactivation. We cannot do those without privileges and
should not claim them. Our lever is request placement only.

### 3.4 WITHDRAWN: the cache-versus-energy conflict was a metric artifact

This section previously argued that our own data showed prefix-cache affinity
and energy efficiency pulling in opposite directions at c=8, and that "how
should a router trade cache affinity against energy?" was a better paper than
"energy-aware routing works".

**The 5-trial pinned run (job 12303088) removes the premise.** Judged per token
actually processed, the shared-prefix arm used 2.6x *less* energy and completed
1.32x more requests than the unique-prompt arm. The apparent conflict came
entirely from dividing by generated tokens while the shared-prefix workload
carried 8.5x more prompt tokens. Prefill is real work; the denominator was
unfair to the arm that did more of it.

What remains, much smaller: nobody has measured how a cache-affinity scorer and
an energy scorer interact when prompt lengths are *matched* and the cache hit
rate is *measured*. That is a legitimate but modest question, and it is no
longer a candidate headline. The plan should not lean on it until a
matched-length experiment exists.

The lesson generalises to the whole evaluation: with two defensible
denominators (per generated token, per token processed) a policy comparison can
invert, so the paper must fix a primary metric in advance and report both.

## 4. Step-by-step plan to a defensible paper

**Stage 0 - unblock (days).** Fix B1 and B4: pin GPU type, record co-tenancy.
Resolve S1 (prefix caching on/off, hit rate). Re-run the H1 sweep pinned to one
GPU type, 5 trials. *Exit:* a clean single-hardware dataset with CIs.

**Stage 1 - characterise, don't claim (1-2 weeks).** Repeat the sweep on each
GPU type available (A30, RTX 6000, L4, L40S) and two model sizes. Cross-check
energy against IPMI on the A30 nodes (S2). *Exit:* per-configuration
`P_active` and throughput curves - inputs to the scorer, framed as calibration.

**Stage 2 - the gate (1 week).** Offline trace replay (Azure arrivals) over
those curves comparing round-robin, SLO-aware packing, and an oracle. *Exit
criterion unchanged from the plan:* if the oracle beats packing by < ~5%
J/token, stop and write the measurement/negative-result paper.

**Stage 3 - build the scorer (2 weeks).** Out-of-tree plugin implementing
`argmin` active-GPU-seconds with the activation penalty, behind the existing
SLO filter. Unit tests against recorded attribute fixtures.

**Stage 4 - the real experiment (2-3 weeks).** On pinned hardware, open-loop
Poisson arrivals from the trace, >= 5 trials per policy: stock llm-d, round
robin, SLO-aware packing, ours, ours-without-activation-term. Report J/token,
p95 TTFT/TPOT, SLO attainment, and GPU-seconds active, each with 95% CI.

**Stage 5 - the cache question (1-2 weeks).** Prefix-sharing workload, sweep
the weight between prefix-cache scorer and energy scorer, map the Pareto front.
This is the section most likely to make the paper interesting rather than
merely competent.

**Stage 6 - write and upstream (2-3 weeks).** Target HotCarbon (5 pages).
Position against 2609.05565 (the gap), Festina (what we deliberately do not
assume), and 2608.06188 / 2608.28044 (whose characterisations we reuse rather
than re-derive). Submit the extractor PR upstream regardless of paper outcome.

---

## 5. Honest risk assessment

- **Novelty risk: moderate-to-high.** The measurement space is crowded and
  Festina covers adjacent ground. The surviving contribution is integration
  plus the constrained setting. A reviewer who values systems-integration
  artifacts will accept it; one who wants a new mechanism will not.
- **Effect-size risk: unknown and now more concerning.** With active power
  near-constant and only 2 GPUs per node, the achievable saving from routing
  alone may be small once SLO constraints bind. Stage 2 exists to find this out
  cheaply.
- **Being scooped: real.** 2609.05565 published an agenda for exactly this in
  llm-d. Upstreaming the plugin early is both the contribution and the
  timestamp.

## 6. Research-integrity notes

- AI assistance (this session) must be disclosed in any submission; the
  measurement scripts and the analysis were AI-generated and human-run.
- Every number in section 1 of this review comes from a source fetched on
  2026-10-03; none are from memory. The arXiv identifiers should be re-verified
  against the published record before they enter a bibliography.
- No human subjects, no dual-use concern.
