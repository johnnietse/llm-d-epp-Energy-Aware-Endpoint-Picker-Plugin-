## What this changes

<!-- One or two sentences. -->

## Why

<!-- The problem, and the evidence for it: job ids, record paths, plan section. -->

## How it was verified

<!-- Commands run and what they printed. "Tests pass" is not enough on its own
     for anything that touches measurement or analysis. -->

## Checklist

- [ ] Every number this PR states traces to a job id and a committed record
- [ ] Nothing measured or recorded was deleted; anything superseded moved to `legacy/` with a note
- [ ] `go test ./pkg/...` and `(cd router-plugin && go test ./...)` pass
- [ ] `python experiments/scripts/make_figures.py` leaves `docs/figures/measured/*.csv` unchanged, or the PR explains why they changed
- [ ] Changes to `policy_harness.py` or a batch script: `fr-sync.sh run verify_fixes.sh` reports no failures
- [ ] Does not modify `docs/plan/PREREGISTRATION-STAGE5.md` above its "Deviations" section after a freeze tag
