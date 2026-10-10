# router-plugin

Out-of-tree plugins for the [llm-d router](https://github.com/llm-d/llm-d-router)
endpoint picker (EPP), and the EPP binary that registers them.

`cmd/epp` is the upstream runner unchanged, plus our `Register` calls. Any
difference in behaviour from stock llm-d therefore comes only from plugins that
a configuration explicitly selects.

## Pinned versions

| Component | Version | Why this one |
|---|---|---|
| llm-d-router | **v0.11.0** (2026-09-27) | Latest release. `main` moves daily, and its docs already disagree with v0.11.0 (see below). |
| Go | 1.26.6 | The router's minimum. `GOTOOLCHAIN=auto` fetches it. |
| Envoy | 1.39.2 | What `images/envoy.sif` on Frontenac contains. The router needs at least 1.31. |

## Plugins

| Type | Status | What it does |
|---|---|---|
| `energy-epp-plumbing-probe` | Alpha, **inert** | Gives every endpoint a score of 1.0 and counts its calls in `energy_epp_probe_score_calls_total`. It proves the plugin is wired in. It is not a policy, takes no parameters, and must never be a measured arm. |
| `energy-epp-policy-scorer` | Alpha | The Stage 2 routing rules, ported (`pkg/energypolicy`): `energy_consolidate`, `energy_greedy`, `slo_packing`, `round_robin`, `least_loaded`. It gives 1.0 to exactly the endpoints the rule chooses between and 0.0 to the rest. It counts every decision in `energy_epp_policy_picks_total{policy,outcome}`, where the outcome is feasible, saturated, ungrounded or misconfigured. |
| `energy-epp-seeded-random-picker` | Alpha | Chooses uniformly among the top-scored endpoints from a per-trial seed (amendment B5). Upstream's `max-score-picker` breaks ties by a process-wide rotation instead. |

**How the policies are ported.** This follows the amended pre-registration,
tag `prereg-stage5-v2`, section 15.
- **Inputs:** endpoints carry `energy-epp/index` and `energy-epp/gpu-type`
  labels in the file-discovery list. The in-flight count comes from the
  router's `inflight-load-producer`, which the scorer declares in
  `Consumes()`; the router refuses undeclared reads.
- **Curves:** these are `curves/*.json`, written by
  `experiments/scripts/export_router_fixtures.py` through the harness's own
  `load_openloop_curve`, so the curve reduction exists once.
- **Fidelity:** on 9,856 recorded fleet states,
  `TestDecideMatchesPython` requires each policy's tied set and outcome
  (feasible, saturated or ungrounded) to equal the Python `Router`'s
  exactly. 2,077 of those states contain ties.
  - Three deliberate one-character bugs were each caught.
  - A sample of 1,408 states is re-run through real framework endpoints
    behind the router's data scoping.
- **Exact float equality:** ties are decided by exact equality, so the
  interpolation forbids fused multiply-add. A fused result could differ from
  Python's in the last bit and change which endpoints tie.

**Configs.** `configs/epp-config.sh` writes one arm's EPP config.
- **Saturation filter:** v0.11.0 adds a saturation detector to every
  scheduling profile as a filter, whether or not flow control is on. Its
  default drops endpoints whose metrics are stale. With no scraping, every
  endpoint is stale, so that default is inert only through its fail-open
  fallback. The generated configs set a concurrency detector instead, with a
  limit of 10^9 requests, which is inert by construction.
- **Check:** `configs/check-configs.sh` (WSL) starts the built EPP with each
  arm's config and prints the final profile. Each policy arm shows only the
  inert filter, the policy scorer and the seeded picker; `random` shows the
  same filter, no scorer and upstream's `random-picker`.
- **Not generated yet:** `stock_llmd` and `llmd_latency_least` are
  materials-addendum decisions.

## Build

The cluster has no Go toolchain, and its login node cannot run containers, so
the binary is cross-compiled here. The router is pure Go (no cgo, no `replace`
directives), so a static build works. Always build with the script:

```bash
bash router-plugin/build.sh
```

It builds with `-buildvcs=false -trimpath -ldflags "-s -w"` and writes the
binary's sha256 alongside it. **The build is reproducible:** two builds from the
same source give the same hash, checked 2026-10-08.

| Build | sha256 | Status |
|---|---|---|
| canonical, `build.sh` | `6e92f44b30b9b5334baf1aae00ac37e1e318f7bbe3c517f1c8916bc50ae29250` | reproducible from this source; used from 2026-10-08 |
| first build, 2026-10-07 | `f3f2aa63492547ae3edfecac92aa1820f6c6edfb1cae1a6c8e3cfa019fe2acf8` | **not reproducible**; used by jobs 12321493, 12321494, 12321496, 12321497 |

Why the first build cannot be reproduced: without `-buildvcs=false`, Go embeds
the repository commit and a "modified" flag. That build recorded
`vcs.revision=9775cc3` and `vcs.modified=true`, because `router-plugin/` was not
committed yet. No commit can recreate those bytes. Its source is the
`router-plugin/` committed in `a9bbbf2`, unchanged since (`git diff a9bbbf2
HEAD -- router-plugin` is empty). Same source, toolchain and flags apart from
`-buildvcs`, so the two binaries are expected to differ only in that embedded
metadata; this has not been checked byte for byte.

`bin/` is git-ignored. The submit scripts send the local binary's hash, and the
job refuses to run a binary that does not match it.

## Running without Kubernetes

These are the EPP flags for file-discovery mode on Frontenac. Each was found by
running the binary, not by reading the docs:

| Flag | Default | Why it is set |
|---|---|---|
| `--pool-name epp` | none | Required at v0.11.0 (`either pool-name or endpoint-selector must be set`). The docs on `main` call it optional. |
| `--secure-serving=false` | `true` | The documented Envoy config speaks plaintext gRPC to the EPP. |
| `--metrics-endpoint-auth=false` | `true` | It authenticates through a Kubernetes API that does not exist here. |
| `--tracing=false` | `true` | Otherwise the EPP retries exporting OpenTelemetry traces to a collector that does not exist. |
| `--allow-experimental-plugins` | `false` | Needed to load anything registered Alpha. |

The EPP also injects a `utilization-detector` filter by default. Every llm-d arm
in Stage 5 will carry it.

## Tests

```bash
GOTOOLCHAIN=auto go test ./...
```
