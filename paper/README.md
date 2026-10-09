# Paper

Single source of truth for the write-up. It supersedes the eight zipped
drafts; `docs/plan/draft-assessment-2026-10.md` explains how they were
consolidated.

| File | Role |
|---|---|
| `main.tex` | Canonical body, from `new_new_new___June_4_latest`, with 1,361 lines of a commented-out older version removed |
| `bibliography-source.tex` | The 92-item bibliography from the condensed IEEE variant, which is far richer than the canonical draft's 37. Merge from here |

## Status: a pre-measurement draft, not submittable

`main.tex` was written in June 2026, before any measurement, for the first
design. Its evaluation is **calibrated simulation**: the H100, L4 and
Qualcomm Cloud AI hardware, a 1,000-cycle routing simulation with "99.8%
prefill, 100% decode accuracy", carbon-region results and an adaptive
controller trace. About 70 lines mention that hardware or those results. None
of it is a finding, and much of it contradicts what was later measured.

What it must be rebuilt from:

| Need | Source |
|---|---|
| Claim and scope | `docs/plan/FINAL-PLAN-2026-10.md` sections 1 and 12.14e (replica selection, no privileged control, routing's own share) |
| Results to date | `README.md` findings 1 to 4, each traced to a job id |
| Figures | `docs/figures/measured/` only, each with a CSV of its plotted numbers. Never `docs/figures/fig*` or `docs/diagrams/`, which are synthetic |
| The comparative result | Stage 5, analysed by `experiments/scripts/prereg_analysis.py` under `docs/plan/PREREGISTRATION-STAGE5.md` |
| Related work | Plan 12.2 and 12.14e. Every reference there was fetched from arXiv, Crossref or the paper on 2026-10-09. The 92-item bibliography above has **not** been checked and must be, entry by entry, before use |
| Disclosure | Plan section 9: AI assistance was substantial and must be disclosed |

The May 2026 thesis proposal, which shares this draft's evaluation, is in
`legacy/thesis-proposal-2026-05/` with a note on which parts are synthetic.
