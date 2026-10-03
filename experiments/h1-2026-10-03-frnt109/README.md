# H1 on pinned hardware: 5 trials, exclusive node (job 12303088)

Supersedes `../h1-2026-10-03/` (job 12302438), which ran 2 trials on a shared
node whose GPU the scheduler chose. This run closes blocking defects B1
(hardware varies) and B4 (co-tenancy), and part of B3 (underpowered).

## Provenance

| | |
|---|---|
| Node | `frnt109`, pinned with `-w`, `--exclusive` |
| GPU | Quadro RTX 6000, 23040 MiB, persistence on |
| GPU UUIDs | `GPU-7fae90e9-...`, `GPU-732d069e-...` |
| Driver | **610.43.02** (same as the superseded run, so the two are comparable) |
| Kernel | 4.18.0-553.148.1.el8_10 |
| `RmProfilingAdminOnly` | **1** (the cluster's representative state) |
| Power limit | 250 W, range 150-250 W |
| Co-tenants at start | none |
| Engine | vLLM 0.30.0, torch 2.13.0+cu130 |
| Model | Qwen/Qwen2.5-1.5B-Instruct |
| Design | 6 levels x 75 s x 5 trials, plus a shared-prefix arm at c=8 |
| Elapsed | 56:53 |

Driver and `RmProfilingAdminOnly` are recorded because the 2026-10-03 survey
showed both vary across this cluster's GPU nodes.

## 1. Trial 1 is a warm-up transient and must be excluded

| conc | trial 1 (W) | trials 2-5 mean (W) | delta | trials 2-5 CI |
|---|---|---|---|---|
| 1 | 186.57 | 203.97 | **-17.40** | +/- 0.20 |
| 2 | 181.99 | 186.97 | -4.98 | +/- 0.17 |
| 4 | 187.56 | 187.11 | +0.45 | +/- 0.53 |
| 8 | 190.75 | 189.33 | +1.42 | +/- 0.69 |
| 16 | 197.10 | 194.62 | +2.48 | +/- 0.70 |
| 32 | 198.93 | 198.72 | +0.21 | +/- 0.19 |

The first trial sits far outside the CI of the rest, most severely at c=1. The
15 s warm-up in the harness is not enough. Including it inflates the c=1
interval from **+/- 0.20 W to +/- 9.66 W**, a 48x widening from one biased
sample.

**Protocol change:** discard trial 1, or lengthen the warm-up and verify
stationarity before recording. Reported numbers below exclude it.

## 2. Measured curve (trials 2-5, mean +/- 95% CI)

| conc | power (W) | J / generated token | gen tok/s | p95 (s) |
|---|---|---|---|---|
| idle, no process | 13.10 | - | - | - |
| idle, model resident | 54.33 | - | - | - |
| 1 | 203.97 +/- 0.20 | 1.5596 +/- 0.0005 | 130.8 | 0.980 |
| 2 | 186.97 +/- 0.17 | 0.8265 +/- 0.0043 | 226.2 | 1.133 |
| 4 | 187.11 +/- 0.53 | 0.4279 +/- 0.0018 | 437.3 | 1.173 |
| 8 | 189.33 +/- 0.69 | 0.2256 +/- 0.0016 | 839.4 | 1.224 |
| 16 | 194.62 +/- 0.70 | 0.1258 +/- 0.0011 | 1547.0 | 1.331 |
| 32 | 198.72 +/- 0.19 | 0.0735 +/- 0.0005 | 2703.6 | 1.526 |

Intervals are sub-watt and sub-percent. The instrument is repeatable; the
earlier spread was warm-up, not noise.

## 3. H1's linear power model is not merely weak, its slope has the wrong sign

The sweep's own fit reports `R^2 = 0.17` on all trials. With warm-up excluded
the structure is clearer and worse for H1:

- power is **non-monotonic**: highest at c=1 (203.97 W), drops to a minimum at
  c=2 (186.97 W), then rises slowly to 198.72 W at c=32
- the slope from c=1 to c=32 is **negative**, -0.169 W per extra concurrent
  request

So `P(b) = P_idle + k_b*b` with `k_b > 0` is refuted, and the superseded run's
`k_b = 0.46 W` and this run's `k_b = 0.24 W` were both fitting noise around a
flat-to-dipping curve. **The marginal-power term should not be reported as a
quantity at all**, and any ratio built on it (the earlier "293x", "547x") is
unstable and must be dropped.

What does hold, tightly:

- **active power is near-constant**, 187-204 W across a 32x load range
- **throughput scales almost linearly**, 130.8 to 2703.6 tok/s = **20.7x**
- therefore **`J/token = P_active / throughput(b)`**, falling **21.2x**

The c=1 peak is worth a sentence in the thesis: a single in-flight request
leaves the GPU with idle gaps that keep clocks boosted, so the least efficient
operating point is also the highest-power one. That strengthens the
consolidation argument rather than weakening it.

## 4. Activation dominates, and that is the robust claim

| | |
|---|---|
| idle, model resident | 54.33 W |
| power at c=1 | 203.97 +/- 0.20 W |
| **activation step** | **+149.64 W** |
| marginal per extra request | negative / indistinguishable from zero |

The routing implication is unchanged and now rests on the solid half of the
measurement: **consolidate onto already-active endpoints and avoid waking idle
ones.** The step from resident-idle to serving is ~150 W; adding load to a
serving GPU is free to within measurement error.

The idle floor is 54.33 W, **27%** of power at the highest load, so an endpoint
holding a model without serving is expensive.

## 5. Defect S1 resolved: the prefix-cache "conflict" was a metric artifact

The superseded run showed shared-prefix workloads looking *worse* per token,
which the validity review flagged as the most interesting open question. It is
not a conflict. At c=8, 5 trials each:

| | unique prompts | shared prefix |
|---|---|---|
| J / **generated** token | 0.2259 +/- 0.0015 | 0.2391 +/- 0.0012 |
| J / **total** token | 0.1770 +/- 0.0012 | **0.0680 +/- 0.0003** |
| prompt tokens in window | 17 534 | **148 582** |
| requests completed | 496 | **655** |
| latency p50 / p95 | 1.219 / 1.224 | 1.047 / 1.303 |

The shared-prefix arm carries **8.5x more prompt tokens**, and prefill is real
work. Judged per generated token it is 1.06x worse; judged per token actually
processed it is **0.38x, i.e. 2.6x better**, and it completed **1.32x more
requests** in the same window with lower median latency.

So the cache is working exactly as expected and the earlier result was the
denominator penalising the arm that did more work. Consequences:

1. **Stage 5 of the plan is rescoped.** "How should a router trade cache
   affinity against energy?" cannot be posed from this evidence, because at
   c=8 there is no trade to make. A real test needs **matched prompt lengths**
   and a **measured cache hit rate**, so that cache effect is separated from
   workload composition.
2. **Report both denominators** everywhere. J per generated token is the
   user-facing cost; J per total token processed is the system efficiency.
   Policies can be ranked oppositely by the two, which is a reporting hazard
   for the whole paper, not just this arm.
3. The honest headline is that prefix caching improved energy per unit of work
   and request goodput simultaneously. There was never a tension here.

## 6. Reproduction against the superseded run

Same GPU model and driver, different node, warm-up excluded here:

| conc | this run J/gen-tok | frnt152 run | ratio |
|---|---|---|---|
| 1 | 1.5596 | 1.5547 | 1.003 |
| 2 | 0.8265 | 0.8613 | 0.960 |
| 4 | 0.4279 | 0.4517 | 0.947 |
| 8 | 0.2256 | 0.2401 | 0.939 |
| 16 | 0.1258 | 0.1342 | 0.937 |
| 32 | 0.0735 | 0.0783 | 0.939 |

Agreement to 0.3% at c=1 and a consistent **~6% offset** at c>=2, in the same
direction at every level. A uniform offset between two nodes of identical model
and driver is not noise; it is a node or die effect, which is the hypothesis
section 13.5 of the plan exists to test. Supporting evidence from the same two
runs: **bare idle power was 13.10 W on frnt109 and 22.0 W on frnt152**, a 1.7x
difference with no process on the GPU.

**This means cross-node comparisons need a per-node calibration or a
within-node design.** Routing policies must be compared on the same node, or
with node as an explicit blocking factor.

## Files

| File | Contents |
|---|---|
| `h1.csv` | 36 rows, one per (trial, level, arm) |
| `fit.txt` | the harness's own fit and gate verdict |
| `instruments.txt` | full provenance including the new fields |
| `idle_bare.txt` | idle power with no process on the GPU |
| `sweep.log` | run log |

Analysis: `../scripts/h1_analyse.py h1.csv --compare ../h1-2026-10-03/h1.csv`
