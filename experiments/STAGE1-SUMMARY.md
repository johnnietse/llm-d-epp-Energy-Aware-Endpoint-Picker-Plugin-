# Stage 1 complete: four measured configurations (2026-10-03)

All runs pinned with `-w`, `--exclusive`, 5 trials, trial 1 discarded as a
warm-up transient, full provenance per run. Every number below is from NVML's
hardware energy counter on a named physical GPU; nothing is modelled.

| Run | Node | GPU | Driver | Model | Job |
|---|---|---|---|---|---|
| A | `frnt109` | Quadro RTX 6000 (250 W) | 610.43.02 | Qwen2.5-1.5B | 12303088 |
| B | `frnt140` | NVIDIA A30 (165 W) | 610.43.02 | Qwen2.5-1.5B | 12303200 |
| C | `frnt201` | NVIDIA L4 (72 W) | 610.57.04 | Qwen2.5-1.5B | 12303303 |
| D | `frnt109` | **same die as A** | 610.43.02 | Qwen2.5-**7B** | 12303308 |

Run D shares GPU UUID `GPU-7fae90e9-...` with run A, so model size is the only
variable between them.

## The headline numbers

| | A: RTX 6000 1.5B | B: A30 1.5B | C: L4 1.5B | D: RTX 6000 7B |
|---|---|---|---|---|
| idle, no process | 13.10 W | 25.49 W | 15.91 W | 13.28 W |
| idle, model resident | 54.33 W | 27.87 W | 27.46 W | **54.87 W** |
| power at c=1 | 203.97 | 144.45 | 71.89 | 222.89 |
| power at c=32 | 198.72 | 155.51 | 71.88 | 216.33 |
| **activation step** | +149.6 W | +116.6 W | +44.4 W | **+168.0 W** |
| J/token at c=32 | 0.0735 | **0.0317** | 0.0351 | 0.2992 |
| tok/s at c=32 | 2704 | **4908** | 2048 | 723 |
| p95 at c=32 | 1.526 s | **0.840 s** | 2.008 s | 5.704 s |
| J/token range | 21.2x | 24.8x | **27.4x** | 21.6x |
| idle floor, share of peak | 27% | 18% | **38%** | 25% |
| linear-model `R^2` | 0.17 | **0.85** | 0.14 | 0.20 |
| marginal slope | **negative** | +0.357 W/req | **zero** | **negative** |

All intervals are sub-watt and sub-percent; see each run's README.

## Five findings

### 1. `J/token = P_active / throughput(c)` is the right model, on all four

Confirmed everywhere, falling 21-27x with concurrency. This is the replacement
for H1's linear power model and it is what the scorer should use.

### 2. The power-model form is a property of the GPU, not the workload

Three distinct shapes, and the 7B run proves the shape belongs to the hardware:

- **Turing (RTX 6000)**: non-monotonic, peak at c=1, **negative** slope,
  `R^2` 0.17 at 1.5B and 0.20 at 7B. The same odd shape appears for both model
  sizes on the same die, so it is the GPU's behaviour, not the workload's.
- **Ampere (A30)**: monotonic rise, positive slope, `R^2` 0.85.
- **L4**: **flat at its 72 W power cap**, max residual 0.09 W, slope zero.

So `P = P_idle + k_b*b` is refuted on three of four configurations and holds
only on the A30. No single power model is correct across hardware, and a scorer
must not assume a positive marginal term.

### 3. The cost of holding a model is a GPU property, not a model-size property

This is the most surprising result and it comes from runs A and D on the same
die:

| | 1.5B | 7B | ratio |
|---|---|---|---|
| idle, model resident | 54.33 W | 54.87 W | **1.01x** |
| activation step | +149.6 W | +168.0 W | 1.12x |
| parameters | 1.54 B | 7.6 B | 4.9x |

A 4.9x larger model costs **1% more** to hold resident and 12% more to
activate. **You cannot save idle power by keeping a smaller model loaded.**
That removes a whole class of routing ideas: swapping to smaller resident
models to cut the idle floor would not work on this hardware.

### 4. Energy per token scales sub-linearly with model size

Same die, same driver, same workload: 4.9x the parameters costs **3.74x to
4.21x** the energy per token (ratio stable across all six load levels), while
throughput falls 3.74x and p95 latency rises 3.74x. So the 7B model is slightly
*more* energy-efficient per parameter, and the penalty shows up as latency and
throughput rather than disproportionate energy.

### 5. The A30 dominates, and that is the project's central difficulty

At c=32 the A30 is better than every other configuration on **energy and
throughput and latency simultaneously**: 0.0317 J/token against 0.0351 (L4)
and 0.0735 (RTX 6000), 4908 tok/s, 0.840 s p95.

This is Pareto dominance, not a trade-off. Consequence, stated plainly:
energy-aware routing on this cluster degenerates to "prefer the A30s" whenever
any are free, and that is almost trivially correct. **The research question
therefore lives entirely in the saturated regime**, where the dominant hardware
is full and a policy must choose among the remainder under an SLO. Stage 2
(measured) is designed to reach that regime, and the honest possibility is that
there is no useful headroom once it does.

The L4 is the interesting counterexample for the future: nearly as
energy-efficient as the A30 (0.0351 vs 0.0317) on a 72 W budget rather than
165 W, but 2.4x the latency. A fleet of many L4s under a loose SLO is the one
configuration in which an energy-aware policy might beat packing outright, and
Frontenac has only two L4s.

## Protocol confirmations

- **The warm-up transient reproduces on all four runs**, trial 1 always low and
  outside the others' interval. Discarding it is now protocol, not judgement.
  On the L4 it shrinks the c=1 interval to +/- 0.06 W.
- **The prefix-cache metric artifact reproduces on all four**: shared-prefix
  looks worse per *generated* token and is 2.5-2.6x better per *token
  processed*, with more requests completed. The denominator decides the answer,
  which is why the primary metric is fixed in advance.
- **NVML counter and polled power agree** throughout.

## What Stage 1 does not cover

One model family (Qwen2.5), one output length (128 tokens), closed-loop load,
one cluster, one vendor. A100, L40S, RTX 8000 and V100 are available and
unmeasured. Open-loop arrivals from the Azure trace belong to Stage 5.
