# Sensitivity study: data-quality note (2026-10-13)

The tables in this directory are the output of `sensitivity_analyse.py`, as
committed before the data (`SENSITIVITY-VLLM-LIMITS.md`), run on all 16 curves
(jobs 12330595 to 12330610, all COMPLETED). Each job's log confirms its vLLM
limits, and each curve has 90 rows (6 trials x 15 rates) with no FATAL. The
tables are unchanged by this note.

## One artefact, in two curves: RTX 6000 at max-num-seqs 64

The analysis reports C(2 s) = 1 req/s for RTX 6000 64/2048 (olc-12330596) and
no capacity for 64/8192 (olc-12330598). Every other RTX 6000 setting reaches
27 req/s. The 64 result is not a serving limit.

1. **The curves were cut at 1 req/s by keep-up alone.** At 1-27 req/s the
   pooled p95 (1.21-1.86 s) and median TTFT (0.03-0.04 s) equal those of
   the 128 setting. That is, no queueing.
2. **The shortfall belongs to whole trials, not rates.** Keep-up below 0.95
   at rates whose p99 latency is under 2 s occurs only in trial 6 of
   olc-12330596 (5 rates) and trials 3, 5 and 6 of olc-12330598 (6, 5 and 6
   rates). No other curve shows this pattern. That includes the Stage 5
   curves olc-12325349 and olc-12325350, checked the same way.
3. **Example: trial 6, 13 req/s, olc-12330596.** All 780 requests
   completed. Sends were on schedule (maximum send delay 3 ms), with e2e p99
   1.535 s and maximum inter-token gap 22 ms. Yet achieved was 10.6 req/s
   against 13.3 realised. That implies about 74 s of elapsed time for about
   60 s of traffic, roughly 14 s that no request accounts for.
4. **Where the extra time can come from.** `policy_harness.py` takes `t_end`
   after joining every worker process, so the elapsed time includes worker
   shutdown, not only serving. A slow teardown lowers keep-up while every
   request is served on time.
5. **Likely cause, not proven.** These were the first two jobs on frnt149,
   started 2026-10-10 02:23 and 05:22, while another user's jobs shared the
   node. CPU contention slowing worker teardown would fit. The logs do not
   time the teardown, so this is not shown.

**Reading the tables.**
- Treat the two RTX 6000 64-seq rows as unresolved, not as "64 sequences
  fail".
- The A100 64-seq result is unaffected: C(2 s) = 73 req/s, against 128 for
  the other settings.
- No change has been made to the analysis rule. Any re-analysis would be a
  labelled deviation.

## What the clean curves say at the 2.0 s target

| GPU | settings | C(2 s), req/s | requests per joule at C |
|---|---|---|---|
| A100 | 128, 256, 512 seqs x 2048, 8192 tokens | 128 (all six) | 0.5313-0.5321, within each other's 95% CI |
| A100 | 64 seqs | 73 | 0.306-0.307 |
| RTX 6000 | 128, 256, 512 seqs x 2048, 8192 tokens | 27 (all six) | 0.1299-0.1306, within each other's 95% CI |

- **Stage 5's setting is not disadvantaged.** On both GPUs it is 256/2048,
  which is tied with the leader within the leader's 95% CI at 2.0 s.
- **Capacities are grid-limited.** The rate grids step 128 to 147 (A100) and
  27 to 34 (RTX 6000). A "tie" means no setting moved the capacity across a
  grid step.
