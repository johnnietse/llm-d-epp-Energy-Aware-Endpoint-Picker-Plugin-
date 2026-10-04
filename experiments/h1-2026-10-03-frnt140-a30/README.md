# H1 on A30: the model form is architecture-dependent (job 12303200)

> **Energy scope.** Every joule figure here is **GPU-package energy**, read from
> NVML's hardware counter (`nvmlDeviceGetTotalEnergyConsumption`). It
> **excludes** CPU, DRAM, fans, PSU conversion losses and any other node
> component. It is therefore a *subset* of system energy and is **not
> comparable to an MLPerf Power figure**, which is measured at the wall. See
> `docs/plan/FINAL-PLAN-2026-10.md` section 5.1.

Second pinned run, deliberately on the **same driver** as the Quadro RTX 6000
run so that GPU model is isolated from driver version.

## Provenance

| | |
|---|---|
| Node | `frnt140`, pinned with `-w`, `--exclusive` |
| GPU | NVIDIA A30, 24576 MiB, persistence on |
| GPU UUIDs | `GPU-3e5c4e83-...`, `GPU-fca29d65-...` |
| Driver | **610.43.02** — identical to the `frnt109` RTX 6000 run |
| Kernel | 4.18.0-553.148.1.el8_10 |
| `RmProfilingAdminOnly` | 1 |
| Power limit | 165 W, range **100-165** |
| Node features | `power_ipmi,amd` — one of the eight nodes that could give an independent IPMI cross-check |
| Co-tenants | none |
| Design | 6 levels x 75 s x 5 trials, trial 1 excluded as warm-up |
| Elapsed | 56:10 |

## 1. The headline: H1's linear model is NOT universally refuted

This is a correction to what the RTX 6000 run alone suggested.

| | Quadro RTX 6000 (`frnt109`) | A30 (`frnt140`) |
|---|---|---|
| Fitted `R^2` for `P = P_idle + k_b*b` | **0.17** | **0.85** |
| Max residual | 13.5 W | **4.1 W** |
| Power shape vs concurrency | non-monotonic, peak at c=1 | rises monotonically after a small c=2 dip |
| Marginal slope c=1 to c=32 | **negative** (-0.169 W/req) | **positive** (+0.357 W/req) |

So the linear power model **fails on Turing-era Quadro RTX 6000 and holds
approximately on Ampere A30**. The earlier blanket statement "H1 is refuted"
was too broad; it is refuted *on that hardware*. The model form is an
architecture-dependent empirical question, which is a more interesting and more
defensible claim than either "it works" or "it does not".

Practical consequence for the scorer: it still must not assume a positive
marginal-power term, because on one of the two architectures measured that term
is negative. An activation-aware rule is correct on both.

## 2. Measured curve (trials 2-5, mean +/- 95% CI)

| conc | power (W) | J / generated token | gen tok/s | p95 (s) |
|---|---|---|---|---|
| idle, no process | 25.49 | - | - | - |
| idle, model resident | 27.87 | - | - | - |
| 1 | 144.45 +/- 0.57 | 0.7777 +/- 0.0031 | 185.7 | 0.690 |
| 2 | 143.37 +/- 0.26 | 0.3923 +/- 0.0008 | 365.5 | 0.701 |
| 4 | 145.61 +/- 0.27 | 0.2022 +/- 0.0006 | 720.0 | 0.713 |
| 8 | 147.64 +/- 0.39 | 0.1033 +/- 0.0002 | 1428.5 | 0.720 |
| 16 | 153.33 +/- 0.57 | 0.0558 +/- 0.0004 | 2748.1 | 0.750 |
| 32 | 155.51 +/- 0.45 | 0.0317 +/- 0.0001 | 4907.7 | 0.840 |

J/token falls **24.75x** across the range (RTX 6000: 21.2x).

## 3. The warm-up transient reproduces

Trial 1 was low at **every** concurrency level and outside the others' interval
every time, on a different architecture and a different node:

| conc | trial 1 (W) | trials 2-5 (W) | delta |
|---|---|---|---|
| 1 | 139.78 | 144.45 | -4.67 |
| 2 | 140.15 | 143.37 | -3.22 |
| 4 | 143.00 | 145.61 | -2.61 |
| 8 | 145.60 | 147.64 | -2.04 |
| 16 | 152.65 | 153.33 | -0.68 |
| 32 | 154.79 | 155.51 | -0.72 |

Two architectures, same direction, every level. **Discarding trial 1 is now an
established protocol requirement, not a one-off judgement.**

## 4. The A30 Pareto-dominates the RTX 6000, and that reshapes the experiment

Same driver, same model, same workload, same harness:

| | RTX 6000 | A30 | A30 advantage |
|---|---|---|---|
| J / generated token at c=32 | 0.0735 | **0.0317** | **2.32x less energy** |
| Throughput at c=32 | 2704 tok/s | **4908 tok/s** | 1.81x |
| p95 latency at c=32 | 1.526 s | **0.840 s** | 1.82x faster |
| Power limit | 250 W | 165 W | 1.52x lower |

Ratio of J/token across all levels: **0.43 to 0.51**, i.e. the A30 uses roughly
half the energy per token at every load, while also being faster.

**This is a dominance relation, not a trade-off**, and it has a sharp
consequence for Stage 2 that the plan did not anticipate: if one GPU type is
better on both energy *and* latency, then "energy-aware routing" degenerates to
"prefer the A30s" whenever any are free. An oracle will simply pack A30 first.
The genuinely interesting routing question is therefore what happens **once the
dominant hardware is saturated or SLO-bound**, and the Stage 2 trace replay
must be designed to reach that regime or it will measure something trivial.

Caveat on interpretation: this is a *generational* comparison (Ampere datacenter
part against a Turing workstation part), not a like-for-like one. The honest
framing is that real clusters contain exactly this kind of generational mix, and
a router that ignores it leaves a 2.3x energy factor on the table.

## 5. The cost of holding a model resident differs 17x

| | RTX 6000 | A30 |
|---|---|---|
| Bare idle, no process | 13.10 W | 25.49 W |
| Idle with model resident | 54.33 W | 27.87 W |
| **Model-resident overhead** | **+41.2 W** | **+2.4 W** |
| Idle floor as share of peak-load power | 27% | 18% |

Note the inversion: the A30 draws *more* power with nothing on it, yet far less
with a model loaded and waiting. Keeping a model resident on an A30 is nearly
free; on the RTX 6000 it costs 41 W.

This weakens the "avoid waking idle GPUs" lever on A30 specifically, and it
means the activation penalty in the scorer **must be per-architecture**, not a
single constant. Activation step: **+116.58 W** on A30 against +149.64 W on the
RTX 6000.

## 6. Prefix caching: S1's resolution reproduces

| | unique | shared prefix |
|---|---|---|
| J / generated token | 0.1032 +/- 0.0005 | 0.1050 +/- 0.0010 |
| J / **total** token | 0.0809 +/- 0.0004 | **0.0324 +/- 0.0010** |
| prompt tokens | 29 674 | **238 445** |
| requests completed | 840 | **1051** |
| p50 / p95 latency | 0.717 / 0.720 | 0.643 / 0.725 |

Per generated token, shared looks 1.02x worse; per token actually processed it
is **0.40x, i.e. 2.5x better**, with 1.25x more requests completed and lower
median latency. Identical pattern to the RTX 6000 (0.38x there). The metric
artifact explanation is confirmed on a second architecture.

## Files

`h1.csv` (36 rows), `fit.txt`, `instruments.txt`, `idle_bare.txt`, `sweep.log`.

Analysis:
`python ../scripts/h1_analyse.py h1.csv --compare ../h1-2026-10-03-frnt109/h1.csv`
