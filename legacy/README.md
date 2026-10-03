# legacy/ — the drafts' design, preserved

Moved here by the **2026-10-03 rescope**. This is not dead weight to delete: it
is the design space the thesis documents in Chapter 3, and it is the evidence
that these approaches were implemented and then withdrawn *for measured
reasons* rather than never tried.

**It does not compile in place.** `legacy/go.mod` exists only so the root
module ignores this tree; the imports here still point at the root module. The
last state where everything built and passed tests together is tagged
**`pre-rescope-2026-10-03` (`bda1f97`)** — check that out to run any of it.

Full reasoning: `docs/plan/FINAL-PLAN-2026-10.md` section 2, and
`docs/plan/draft-assessment-2026-10.md`.

## Why each piece is here

| Path | Was | Why withdrawn |
|---|---|---|
| `simulation/` | 390-line simulated end-to-end evaluation | The project moved to real hardware only. A simulated 1000-cycle win-rate cannot be defended, and keeping it in the build invited its numbers back into the paper. |
| `upstream-port/` | A port against llm-d-router | Never built: upstream removed `scheduling.Metrics` and changed the `Score` signature. It had already produced one false "100% API compatible" claim. |
| `ebpf/` | Kernel-level eBPF token tracker | **Requires privilege**, contradicting the paper's central "no privileged control" claim. Shipping it in the same artifact would hand a reviewer that inconsistency. |
| `slurm/` | SPANK plugin adapter | Same contradiction: SPANK plugins are installed by cluster admins. |
| `ray/` | Ray/KubeRay autoscaling policy | Autoscaling demoted from a headline; not reachable as an unprivileged user on a shared Slurm cluster. |
| `scorers/kv_cache_transfer_scorer.go` | KV-cache transfer cost scorer | The cache-versus-energy conflict it was built for turned out to be a metric artifact (measured 2026-10-03: caching improved energy per token processed 2.6x *and* goodput 1.32x). Revisit only with matched prompt lengths and a measured hit rate. |
| `scorers/rdma_locality_scorer.go` | RDMA locality scorer | Out of scope. |
| `filters/thermal_filter.go` | Thermal headroom filter | No measured basis; thermal headroom was never shown to bind. |
| `signals/sci_calculator.go` | Software Carbon Intensity calculator | Within one cluster every endpoint shares a grid, so the carbon term is collinear with energy. SCI is demoted to an optional reporting metric, never a contribution. |

## Still in `pkg/`, but superseded

Three things were **not** moved, for different reasons:

- `pkg/plugins/filter/energy_budget_filter.go` is **unvalidated but entangled**:
  `pkg/config` wires it through `energy_config.go`, `gie_adapter.go`,
  `plugin_registry.go` and `scheduling_profile.go`. Moving it broke the build,
  so it stays until the config layer is rebuilt for the new module. It must not
  appear in the paper, and it also owns the shared `PodCandidate` type that the
  surviving SLO filter depends on.


- `pkg/plugins/scorer/energy_aware_scorer.go` and
  `pkg/plugins/scorer/carbon_intensity_scorer.go` are entangled with
  `pkg/metrics/prometheus_exporter.go`. They are scheduled for **rewrite**, not
  quarantine, once the new out-of-tree module exists. Their current logic is
  refuted: weighted multi-objective scoring with `profile.TDP_Watts / 700.0` as
  a proxy for compute capability, when measurement shows active power is
  near-constant over a 32x load range.
- `pkg/adaptive/weight_controller.go` (the Schmitt-trigger adaptive weights) is
  retained for now because the thesis discusses it; it has no measured basis
  and must not appear in the paper.

## What survives into the new design

- `pkg/signals/energy_store.go` — thread-safe store with Welford/EWMA, genuinely
  reusable and independent of the refuted model
- `pkg/metrics/prometheus_exporter.go` — orthogonal to the scoring question
- `pkg/plugins/filter/slo_constraint_filter.go` — the epsilon-constraint idea is
  sound and matches how the upstream router composes filters
