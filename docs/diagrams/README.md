# Diagrams

This folder mixes two kinds of image. Tell them apart before reusing one.

**Design drawings**, describing an architecture rather than a result. These are
fine as illustrations, but several describe the pre-2026-10-03 design (the
adaptive weight controller, GIE adapters, eBPF, RDMA, carbon routing), most of
which is now in `legacy/`.
Examples: `architecture.png`, `scheduling_pipeline.png`,
`system_components.png`, `concurrency_model.png`,
`telemetry_goroutine_model.png`, `deployment_topology.png`,
`adaptive_controller_fsm.png`, `gie_integration.png`, `ebpf_datapath.png`.

**Data-style plots: not measurements.** Every generator that writes to this
folder (`benchmarks/scripts/generate_advanced_diagrams.py`,
`generate_new_diagrams.py`, `generate_extra_diagrams.py`,
`generate_dvfs_plot.py`, `generate_edp_plot.py`, `generate_arch_diagrams.py`)
reads no data file at all: its numbers are written into the code, or, in
`generate_advanced_diagrams.py`, drawn at random. Checked 2026-10-08. By name,
these include `carbon_savings_heatmap.png`, `cost_per_million_tokens.png`,
`dvfs_power_frequency_curve.png`, `dvfs_savings.png`, `edp_analysis.png`,
`edp_scatter_analysis.png`, `epsilon_constraint_pareto.png`,
`hardware_spec_comparison.png`, `inference_timeline_gantt.png`,
`regional_carbon_comparison.png`, `scoring_overhead_cdf.png`,
`workload_characterization_radar.png` and `phase_aware_weights.png`.

Do not present any of them as results. Measured figures are in
[`../figures/measured/`](../figures/measured/).
