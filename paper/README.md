# Paper

Single source of truth for the write-up. Supersedes the eight zipped drafts;
see `docs/plan/draft-assessment-2026-10.md` for how they were consolidated.

| File | Role |
|---|---|
| `main.tex` | Canonical body, from `new_new_new___June_4_latest` with 1361 lines of commented-out older article version removed. |
| `bibliography-source.tex` | The 92-item bibliography from the condensed IEEE variant, which is far richer than the canonical draft's 37. Merge from here. |

## Status: not submittable as written

The evaluation in `main.tex` is calibrated simulation, including a 1000-cycle
routing simulation reporting "99.8% prefill, 100% decode accuracy". Those
numbers follow from the chosen weight vectors and are not findings. Real
hardware measurements now exist in `experiments/h1-2026-10-03/` and contradict
parts of the model (active power is near-constant; the linear energy model fits
at R^2 = 0.37).

Before any submission, work through section 5 of
`docs/plan/draft-assessment-2026-10.md`, and re-scope the claim per
`docs/plan/research-validity-review-2026-10.md`.
