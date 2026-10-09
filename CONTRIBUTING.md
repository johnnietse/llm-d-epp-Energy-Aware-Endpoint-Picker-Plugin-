# Contributing

This repository is a measured research study as well as code. Most of the
rules below protect the measurements, not the code style.

## Where things are

| Path | What it is |
|---|---|
| `router-plugin/` | Out-of-tree llm-d-router (v0.11.0) plugin module and the EPP binary. Stage 4's scorers go here |
| `experiments/scripts/` | The load generator and policy harness (`policy_harness.py`), Slurm jobs, analysis (`stage2_analyse.py`, `prereg_analysis.py`, `power_analysis.py`, `headroom_calibrate.py`), figures (`make_figures.py`), and the verification suite (`verify_fixes.sh`) |
| `experiments/cluster-records/` | Every raw record fetched from the cluster |
| `docs/plan/` | The plan (`FINAL-PLAN-2026-10.md`) and the pre-registration |
| `tools/cluster-helpers/` | Local scripts that drive the cluster |
| `pkg/`, `cmd/energy-epp/` | Pre-measurement code, being rewritten in Stage 4 |
| `legacy/` | Superseded code and documents, kept for history |

## Rules that protect the results

1. **No simulated or synthetic number is ever presented as a result.** Every
   number in the README, the plan, a figure or a paper traces to a cluster
   job id and a committed record under `experiments/cluster-records/`.
2. **Never delete a record.** Superseded files move to `legacy/` with
   `git mv` and a note saying why. Records are fetched with
   `tools/cluster-helpers/fr-fetchall.sh` and committed.
3. **The pre-registration is not edited after its tag.** Changes before the
   first Stage 5 trial are an amendment with a new tag. Changes after it are
   appended to the document's "Deviations" section. A tag is never moved.
4. **Decision rules are committed before their data.** A calibration or
   analysis rule that chooses anything is committed, and so timestamped,
   before the job it judges runs.
5. **Check the full data, not a printout.** Extremes, worst cases and
   agreement figures are computed over every cell, not over what a summary
   script happened to print.
6. **Fetch before citing.** Every reference is checked against arXiv,
   Crossref or the paper itself before it is cited, never taken from memory,
   a search snippet or a draft.

## Making a change

```bash
go test ./pkg/... && (cd router-plugin && go test ./...)
python experiments/scripts/make_figures.py
git diff --exit-code -- 'docs/figures/measured/*.csv'
```

The last command is what CI checks: if a figure's plotted data changes on
regeneration, it no longer matches its records. Before submitting any cluster
job, run `bash fr-sync.sh run verify_fixes.sh`, which must report no failures.

Cluster commands go in a script file under `experiments/scripts/` and run
through `fr-sync.sh run`. Never build them inline through `wsl.exe` and `ssh`:
that corrupted five runs (plan section 3.4).

Commit messages say what changed, why, and what was verified.

## Upstreaming

The scorer will be proposed to [llm-d-router](https://github.com/llm-d/llm-d-router)
after the Stage 5 study, whatever its outcome, following llm-d's own
[contributing guide](https://github.com/llm-d/llm-d/blob/main/CONTRIBUTING.md).
Any figure in that proposal comes from `docs/figures/measured/`.

## License

Apache License 2.0. By contributing, you agree that your contributions are
licensed under it.
