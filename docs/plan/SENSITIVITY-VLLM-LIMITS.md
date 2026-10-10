# Sensitivity study: vLLM batch limits (exploratory)

| | |
|---|---|
| **Status** | Plan committed **before any of its data**, 2026-10-10. Approved by the author ("go for everything"; full grid chosen as best). |
| **Kind** | **Exploratory.** Not confirmatory, and not part of the Stage 5 pre-registration. |
| **Does not change Stage 5** | Stage 5 runs at vLLM 0.30.0's defaults for these GPUs, `--max-num-seqs 256 --max-num-batched-tokens 2048`, whatever this study finds. The open-loop curve selector only accepts curves measured with the limits a run declares, so these curves cannot leak into Stage 5. |

## Question

How do vLLM's two batch limits change, per GPU type:
- capacity under random arrivals;
- tail latency and time to first token;
- energy per request;

and which settings give the most SLO-met requests per joule for a given latency target? The answer is scenario guidance for operators, and for the llm-d plugin's configuration.

## The two limits

- `--max-num-seqs`: the most requests vLLM runs at once; the rest wait.
- `--max-num-batched-tokens`: the per-step token budget, shared between
  decoding running requests and processing new prompts. At 2048 with many
  requests decoding, little budget is left for new prompts. That fits the
  rise in time to first token seen near the limit (plan 12.14d).

## Grid

| Factor | Levels |
|---|---|
| `max-num-seqs` | 64, 128, 256, 512 |
| `max-num-batched-tokens` | 2048, 8192 |
| GPU | A100-PCIE-40GB on frnt154; Quadro RTX 6000 on frnt149 (pinned, as for every curve) |

That is 16 open-loop curves, measured by `openloop_curve.sbatch` exactly as the Stage 5 curves were:
- the same model, prompt mix and output length;
- six trials per rate (trial 1 dropped as warm-up), 60 s cells;
- the same keep-up test.

Rate grids are wider than before, so higher-capacity settings still reach their collapse point:
- A100: 4, 9, 18, 37, 55, 73, 92, 110, 128, 147, 165, 183, 202, 220, 240 req/s.
- RTX 6000: 1, 3, 7, 13, 20, 27, 34, 40, 47, 54, 61, 67, 74, 82, 90 req/s.

Seeds 731-736, the same for every curve, so differences come from the setting and not the arrival draw.

The two existing curves at 256 / 2048 (`olc-12325349`, `olc-12325350`) are **re-measured inside the grid**, not reused, so every cell has the same date, nodes and seeds. Agreement between the old and new 256 / 2048 curves is itself reported, as a repeatability check.

**A setting that does not fit in GPU memory** is recorded as such: vLLM reports its KV-cache capacity at startup, and the job records the log. It is never silently dropped. If vLLM refuses to start, the cell is reported as "does not run" with the error.

## Measures, per GPU x setting

- **SLO capacity C(T):** the highest measured rate that stays stationary (keep-up >= 0.95 in every used trial) and whose mean p95 latency is at most T. T is 1.0, 1.5, 2.0 and 3.0 s. Measured rates only; nothing is interpolated beyond them.
- At C(T):
  - **requests per joule:** realised rate / mean GPU power;
  - J per token;
  - p50 and p95 latency, TTFT p50;
  - 95% confidence intervals across trials.
- Stationary capacity (the highest stationary rate, whatever the latency) and idle power.

## How the scenario rules are drawn (fixed now)

For each GPU and each target T, the recommended setting is the one with the highest requests per joule at C(T).
- **Ties:** if the runner-up's value lies within the leader's 95% confidence interval, both are reported as tied, and the rule says so rather than picking one.
- **Second axis:** settings are also ranked by C(T), capacity, since an operator short of GPUs may prefer capacity over energy.
- **Full grid always reported:** every value is shown in a table and figure. A rule is never stated without the grid behind it.
- **Scope:** rules apply only to this model (Qwen2.5-1.5B-Instruct, 128 output tokens, this prompt mix) and these GPUs. Generalising beyond them is a hypothesis, not a finding.

## Router cap (second part, after Stage 5)

The router's per-endpoint cap (`MAX_INFLIGHT`) at 32, 64, 128 and 256 on the mixed fleet, h = 0, three seeds, at the Stage 5 loads. It runs after Stage 5, so it cannot compete for the Stage 5 nodes. Its plan is committed before its data, like this one.

## Cost

About 2.5 h per curve, eight curves per node in sequence, both nodes in parallel: **about 20 h**. It runs while Stage 4 (the Go plugin, no cluster time) is built, so it does not delay Stage 5.

## Analysis

`experiments/scripts/sensitivity_analyse.py` computes the measures and rules above. It will be committed before the first sensitivity record is fetched. Figures go to `docs/figures/measured/sensitivity/`, each with a CSV of the plotted numbers.
