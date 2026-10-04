# Stage 2 gate, first run (2026-10-03)

> **Energy scope.** Every joule figure here is **GPU-package energy**, read from
> NVML's hardware counter (`nvmlDeviceGetTotalEnergyConsumption`). It
> **excludes** CPU, DRAM, fans, PSU conversion losses and any other node
> component. It is therefore a *subset* of system energy and is **not
> comparable to an MLPerf Power figure**, which is measured at the wall. See
> `docs/plan/FINAL-PLAN-2026-10.md` section 5.1.

Script: `../scripts/stage2_gate.py`. Inputs: the two measured curves
(`h1-2026-10-03-frnt140-a30`, `h1-2026-10-03-frnt109`), trials 2+ only.

**This is a planning decision, not a finding.** It must never appear in the
paper as a result. Only the arrival process and queueing are modelled;
throughput and power are measured.

Command:

```
python scripts/stage2_gate.py \
  --curves h1-2026-10-03-frnt140-a30/h1.csv=a30 \
           h1-2026-10-03-frnt109/h1.csv=rtx6000 \
  --fleet a30=2 rtx6000=4 --requests 500 --trials 3
```

Fleet: 2 A30 + 4 RTX 6000. SLO 1.378 s (2x the best single-request latency).
Fleet peak ~161 req/s; A30-only peak ~77 req/s.

## Verdict: PASS, conditional — but read the second table first

| offered | regime | bound J/req | packing J/req | headroom | packing SLO% |
|---|---|---|---|---|---|
| 40.3 | below sat | 10.11 | 11.39 | 11.2% | 100.0 |
| 80.6 | saturated | 6.89 | 8.26 | **16.6%** | 100.0 |
| 120.9 | saturated | 6.87 | 9.86 | **30.3%** | 96.7 |
| 145.1 | saturated | 6.86 | 8.72 | 21.3% | 65.1 — excluded |
| 161.2 | saturated | 6.86 | 8.27 | 17.0% | 55.5 — excluded |
| 185.3 | saturated | infeasible | 8.25 | — | 45.1 — excluded |
| 209.5 | saturated | infeasible | 8.13 | — | 29.9 — excluded |

So there is **16-30% headroom against a bound no policy can beat**, at loads
where the SLO is actually met and the dominant GPU type is saturated. That
clears the 5% criterion.

## The more important result: our candidate policy captures none of it

| offered | slo_packing J/req | energy_greedy J/req | difference |
|---|---|---|---|
| 80.6 | 8.26 +/- 0.36 | 8.35 +/- 0.16 | within noise |
| 120.9 | 9.86 +/- 0.37 | 9.82 +/- 0.44 | within noise |

`energy_greedy` — pick the SLO-feasible endpoint with the lowest resulting
J/token, penalising idle wake-ups, which is the rule the plan proposes — is
**indistinguishable from SLO-aware packing** at every load where service is
met. The headroom exists; this policy does not reach it.

Two readings, and the honest answer is probably both:

1. **The headroom is largely unreachable.** The bound ignores queueing
   entirely, so part of that 16-30% is the gap between "perfect foresight with
   no queues" and any causal policy. None of it is free.
2. **The policy is too naive.** Choosing by instantaneous J/token converges to
   the same decisions as packing because, once the A30s are busy, both rules
   send work to the same place. A policy that beats packing must do something
   packing does not: hold work back, batch-shape, or trade a little latency
   inside the SLO envelope for a better operating point.

**Consequence for Stage 4:** do not implement `energy_greedy` as specified and
expect a result. The scorer needs a mechanism that packing lacks, and the gate
should be re-run against each candidate rule before any of it is built.

## Known weaknesses of this gate

Recorded so the verdict is not over-trusted:

- Processor-sharing service model; no prefill/decode split, so TTFT and TPOT
  are collapsed into one latency and one SLO.
- Fixed 128-token outputs, matching the measurement but not real traffic.
- Poisson arrivals, not the Azure trace. Stage 5 uses the trace.
- One fleet composition (2+4). The headroom will depend on the A30:RTX ratio,
  and the plan's A30 pool is 8 nodes x 2 GPUs against ~36 nodes x 4 RTX 6000.
- 3 seeds, 500 requests. Intervals are wide at low load.
- The bound returns infeasible above ~161 req/s, which is correct behaviour and
  also means the interesting high-load regime cannot be assessed this way.

## What the first version of this gate got wrong

Kept as a caution. It printed PASS with a 36% margin and the number was
meaningless:

1. Its "oracle" policy selected the same endpoint as `energy_greedy` at every
   load, so the two columns were byte-identical and no bound was ever computed.
2. Its wins came from SLO collapse — at 209 req/s the "winner" had 41.5%
   attainment against packing's 22.2% and p95 of 7.15 s against a 1.38 s
   target. Joules-per-SLO-request is not comparable across policies operating
   at different attainment.
3. One seed, 600 requests, gaps bouncing from -3.93% to +36.25%.

All three are fixed above: a real capacity-constrained bound, a verdict
restricted to loads where packing meets its SLO, and multi-seed intervals.
