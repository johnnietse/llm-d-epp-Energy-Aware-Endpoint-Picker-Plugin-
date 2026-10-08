# Figures

## `measured/`: use these

Drawn from real measurements on the Frontenac cluster, each traced to a job id,
with the plotted numbers in a CSV beside each figure. See
[`measured/README.md`](measured/README.md).

## `fig1_*.png` to `fig16_*.png`: do not use as results

**These sixteen figures are drawn from synthetic data.** They are not
measurements, from Frontenac or anywhere else.

They are produced by `benchmarks/scripts/generate_figures.py` and
`generate_figures_extended.py`, which read
`benchmarks/results/frontenac/heterogeneous_realistic/`. That directory is
written by `benchmarks/scripts/generate_realistic_telemetry.py`, whose own
docstring describes it as "Production-Grade Synthetic Telemetry" that "adds
real-world imperfections to make the data credible": random request failures,
thermal throttling, sensor glitches, cold starts and latency spikes.
`generate_figures_extended.py` also draws random samples directly. Despite the
`frontenac` in the path, no step reads a measurement.

Found on 2026-10-08 while replacing them. They are kept, not deleted, because
earlier drafts and the thesis report may refer to them by path. **Any figure in
the thesis or a paper built from them must be replaced with its counterpart in
`measured/`, or removed.**
