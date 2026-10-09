# Documents from before any measurement (April to June 2026)

These files stood at the repository root (one in `docs/design/`, one in
`.github/`, one in `scripts/`) until 2026-10-09. They were moved here unchanged with `git mv`, so each file's
history follows it. The pre-move layout is preserved by the tag
`archive-2026-10-09-pre-amendment`.

They describe the project's **first design**: phase-aware prefill/decode
routing across GPUs and ASICs, an adaptive carbon-aware weight controller,
SCI scoring, and a TDP-based energy proxy. They also describe its evaluation
by simulation and synthetic telemetry. Measurement on Frontenac from
2026-10-03 onward replaced that design. Treat everything here as a record of
how the project began, **not as results**.

| Document | What it was |
|---|---|
| `thesis.md`, `June_3_2026_research_report.md`, `new_thesis_additions.md`, `thesis_structure_analysis.md` | Thesis drafts and outlines; their evaluation numbers are simulated |
| `thesis_diagrams.md`, `thesis_diagrams2.md`, `d2_thesis_diagrams.md` | Diagram sources for the first design |
| `data_verification_report.md`, `TESTING_REPORT.md`, `project_update_audit.md`, `project_additions_summary.md` | Status reports on the first design's code |
| `benchmark_plan.md`, `cluster_benchmark_setup_guide.md`, `frontenac_benchmark_guide.md` | Benchmark plans written before the cluster was used |
| `deployment_walkthrough.md`, `production_deployment_guide.md`, `gke_setup_walkthrough.md`, `github_actions_setup.md` | Deployment guides for the Kubernetes-based first design |
| `Makefile-first-design`, `validate-setup-first-design.sh` | The first design's Makefile (Kind cluster, simulated pool, a target that regenerated the synthetic thesis figures) and its setup checker. Replaced 2026-10-09 |
| `CONTRIBUTING-first-design.md`, `PULL_REQUEST_TEMPLATE-upstream-draft.md` | The first design's contributing guide, and an upstream PR description whose "17.4%" key result was simulated. Both were replaced 2026-10-09 |
| `llm_d_integration_plan.md`, `upstream_integration_walkthrough.md`, `upstream_interface_mapping.md`, `action_plan_and_integration.md`, `energy-aware-scorer-proposal.md` | Upstream integration plans against an older llm-d API, with a TDP proxy the measurements later refuted |

## Links inside these documents

They are kept byte-for-byte, so their relative links (for example
`docs/diagrams/architecture.png`) still assume the repository root and no
longer resolve from here. To read one with working links, check out the tag
from before the move: `git checkout archive-2026-10-09-pre-amendment -- thesis.md`.

## Current documents

- What the project is now, and what has been measured: [`../../README.md`](../../README.md)
- The authoritative plan, results and defect log: [`../../docs/plan/FINAL-PLAN-2026-10.md`](../../docs/plan/FINAL-PLAN-2026-10.md)
- The pre-registered comparative study: [`../../docs/plan/PREREGISTRATION-STAGE5.md`](../../docs/plan/PREREGISTRATION-STAGE5.md)
- How to rerun the analysis or a measurement: [`../../QUICKSTART.md`](../../QUICKSTART.md)
