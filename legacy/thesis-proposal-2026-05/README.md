# Thesis proposal, May 2026: a plan, not a results document

The PDF in this folder, *Energy-Aware Token-Level Routing for Heterogeneous
LLM Inference in Kubernetes* (May 2026), is the project's **proposal**. It was
written before any measurement, to set out a design and an evaluation plan.
Read it as a plan that contains errors, not as findings.

It stood at the repository root until 2026-10-09 and was moved here unchanged
(sha256 begins `2a4ea16a00700bc2`). Nothing in it was edited or removed. The
pre-move state is kept by the tag `archive-2026-10-09-pre-amendment`.

## What in it is not a measurement

- **Chapter 5, all of it.** Table 5.1's "calibrated" H100, A100 and L4
  profiles, the "17.4% reduction", the latency CDF, the EDP comparison, the
  carbon-region results and the 12-hour controller trace come from synthetic
  telemetry and a simulated cluster. No H100 was ever available to this
  project. The appendix says the profiles are synthetic, but chapter 5
  presents them as an evaluation.
- **The acknowledgement** that Frontenac was "heavily utilized during the
  initial hardware telemetry profiling". No number in the proposal traces to
  a committed record. The earliest Frontenac record in this repository is job
  12302427, started 2026-10-03, four months after the proposal.
- **The design** it describes (phase-aware prefill/decode routing, an adaptive
  carbon controller, SCI scoring, ASIC targets) was largely set aside on
  2026-10-03. Those components are in [`../`](../).

## What replaced it

- The measured study and its current design:
  [`../../docs/plan/FINAL-PLAN-2026-10.md`](../../docs/plan/FINAL-PLAN-2026-10.md).
- Measured figures, each traced to a cluster job:
  [`../../docs/figures/measured/`](../../docs/figures/measured/).
- The pre-registered comparative study:
  [`../../docs/plan/PREREGISTRATION-STAGE5.md`](../../docs/plan/PREREGISTRATION-STAGE5.md).

Anything quoted from this proposal in the final thesis must be checked against
those first.
