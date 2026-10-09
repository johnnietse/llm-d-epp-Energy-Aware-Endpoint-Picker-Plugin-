# Measured figures

Every figure here is drawn from measurements committed under
[`experiments/cluster-records/`](../../../experiments/cluster-records/), and
each PNG has a CSV beside it holding exactly the numbers plotted. Regenerate
all of them, with no cluster and no GPU, with:

```bash
python experiments/scripts/make_figures.py
```

The output is deterministic: two runs on the same machine give byte-identical
files. CI regenerates the figures and fails if any CSV changes; PNG bytes vary
between operating systems through font rendering, so only the CSVs are
compared.

| Figure | Shows | Source jobs |
|---|---|---|
| `stage1_energy_per_token` | GPU energy per generated token against concurrency, for the six GPU types whose curves the routing policies loaded | h1-12304125 (A100), h1-12304133 (RTX 6000), h1-12304126/27/28/29 |
| `stage2_mixed_fleet` | SLO-goodput per joule and SLO attainment against offered load, five policies, mixed fleet, mean of three seeds with min-max whiskers | 12305232, 12319685, 12321476 |
| `stage2_homogeneous_control` | The same on 8x RTX 6000, load inside that fleet's capacity: every packing policy, energy-aware or not, aims at the 2.0 s target and misses it (plan 12.14d) | 12321478 |
| `stage2_gate_margins` | Per-trial margin over `slo_packing` at each policy's best feasible point, computed by `stage2_analyse.py`'s own functions | 12305232, 12319685, 12321476 |
| `stage2_energy_by_gpu_type` | GPU energy split by type at 300 req/s, mean of three trials | 12305232, 12319685, 12321476 |
| `generator_itl_crosscheck` | The load generator's inter-token latency against vLLM's own histogram, 50 cells | 12319685, 12321476 |
| `router_overhead` | Median time to first token and end-to-end latency: direct, via the router with metrics polling, and with polling off | 12321497 |

How the Stage 1 curves are aggregated mirrors `policy_harness.py`'s
`load_curve`: unique-prompt rows only, trial 1 dropped as warm-up, and J/token
taken as mean power divided by mean token rate. So the figure shows the same
curves the policies used.

Colour follows the entity in every figure: each policy, and each GPU type,
keeps one colour throughout. The five policy colours pass the palette
validator's colour-vision-deficiency checks. Three of them sit below 3:1
contrast on the light background, so every chart also carries a legend,
distinct marker shapes, and the CSV table.
