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

The real scorer is Stage 4 of the plan. It ports only the rule Stage 2 measured
as a winner, after Stage 3 pre-registration.

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
