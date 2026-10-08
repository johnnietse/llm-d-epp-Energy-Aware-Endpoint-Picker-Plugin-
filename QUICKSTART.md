# Quick Start

Four things you can do with this repository, in order of how much you need.
The commands are the ones that produced the recorded results, with real job
ids replaced by `<jobid>`. Nothing in this guide requires Kubernetes.

| Goal | Needs |
|---|---|
| [1. Rerun the results from the committed records](#1-rerun-the-results-from-the-committed-records) | Python 3 |
| [2. Run the tests](#2-run-the-tests) | Go 1.26.6+ |
| [3. Build the llm-d EPP with our plugin](#3-build-the-llm-d-epp-with-our-plugin) | Go 1.26.6+ |
| [4. Run the router path or a measurement](#4-run-the-router-path-or-a-measurement) | A Linux GPU node, Apptainer, vLLM and Envoy images |

```bash
git clone --recurse-submodules https://github.com/johnnietse/llm-d-epp-Energy-Aware-Endpoint-Picker-Plugin-.git
cd llm-d-epp-Energy-Aware-Endpoint-Picker-Plugin-
```

`--recurse-submodules` fetches `llm-d-ref/`, the official llm-d-router pinned to
v0.11.0. Only step 4 needs it.

---

## 1. Rerun the results from the committed records

Every raw measurement is committed under `experiments/cluster-records/`, so the
headline verdicts can be recomputed without a cluster or a GPU.

**Heterogeneous fleet, three trials:**

```bash
python experiments/scripts/stage2_analyse.py experiments/cluster-records/results/stage2het-12305232 experiments/cluster-records/results/stage2het-12319685 experiments/cluster-records/results/stage2het-12321476
```

Expected to end with:

```
GATE PASSED: energy_consolidate beats slo_packing in all 3 trial(s), by at least +1.0% SLO-goodput per joule (per trial: +2.0%, +1.2%, +1.0%).
```

**Homogeneous control, 8x RTX 6000:**

```bash
python experiments/scripts/stage2_analyse.py experiments/cluster-records/results/stage2-12321478
```

Expected:

```
GATE FAILED, informatively: the best policy is round_robin, which uses no energy information at all.
```

`stage2_analyse.py` is the pre-registered gate: each policy is judged at its own
best load level where at least 95% of requests meet the latency target.
`experiments/scripts/compare_runs.py` also prints averages across load levels,
but those are descriptive only. Its own output says not to quote them as the
result.

The router-overhead measurement (job 12321497) is summarised in
`experiments/cluster-records/results/router-overhead-12321497/summary.txt`, with
the per-run count of metrics polls in `runs.tsv`.

---

## 2. Run the tests

```bash
# The out-of-tree llm-d-router plugin module
cd router-plugin && go test ./... && cd ..

# The pre-measurement code at the repository root
go test ./pkg/...
```

`GOTOOLCHAIN=auto` (Go's default) fetches Go 1.26.6 if the router module needs
it. The root `pkg/` code builds and passes, but it is **not** the scorer the
study will use: it ranks GPUs by a power-rating (TDP) proxy that the
measurements refuted. See the README.

---

## 3. Build the llm-d EPP with our plugin

```bash
bash router-plugin/build.sh
```

This produces `router-plugin/bin/epp-linux-amd64`, a static Linux binary of the
**official llm-d-router v0.11.0 EPP** with our plugin registered, and prints its
sha256. The build is reproducible: the same source gives the same hash. The
router itself is not modified; `router-plugin/cmd/epp/main.go` calls the
upstream runner and adds one registration.

The plugin currently shipped is `energy-epp-plumbing-probe`, an **inert** scorer
that gives every endpoint the same score and counts its calls. It proves the
wiring. It is not a routing policy.

---

## 4. Run the router path or a measurement

### Without Kubernetes, the tested recipe

The EPP runs in llm-d-router's **file-discovery mode**: a static
`endpoints.yaml` lists the vLLM servers, Envoy forwards each request to the EPP
over ext_proc, and the EPP picks an endpoint. The exact recipe that passed on a
Slurm node, 40 of 40 requests routed through our plugin, is
[`experiments/scripts/router_smoke.sbatch`](experiments/scripts/router_smoke.sbatch).
Read it top to bottom as the reference. Its parts:

1. Start vLLM 0.30.0, one server per GPU.
2. Write `endpoints.yaml` and an EPP config (the scheduling profile).
3. Take the Envoy config from the router's own docs: `llm-d-ref/docs/discovery.md`,
   section "4. Envoy config". `router_overhead.sbatch` extracts it at run time
   and changes only ports and the bind address, rather than retyping it.
4. Start the EPP with the flags below, then Envoy (1.31 or later; we used
   1.39.2).

Flags the EPP needs **outside Kubernetes**, each found by running it:

| Flag | Why |
|---|---|
| `--pool-name epp` | Required at v0.11.0, although the docs on `main` say optional |
| `--secure-serving=false` | The documented Envoy config talks plaintext gRPC to the EPP |
| `--metrics-endpoint-auth=false` | Otherwise it authenticates through a Kubernetes API |
| `--tracing=false` | Otherwise it keeps retrying an OpenTelemetry collector that is not there |
| `--allow-experimental-plugins` | Needed to load plugins registered as Alpha, including ours |

To switch off the EPP's background polling of vLLM metrics entirely, add
`injectDefaults: false` under `dataLayer:` in the EPP config. Job 12321497
measured the polling's cost at under 1 ms of median time to first token.

### On Frontenac, or another Slurm cluster

The jobs live in `experiments/scripts/` and are driven from a local machine by
the scripts in [`tools/cluster-helpers/`](tools/cluster-helpers/), whose README
says which are current. The usual sequence:

```bash
bash frontenac-connect-hpc6081.sh
```

That opens the shared SSH connection; type the password, then the one-time
code. Then, in another shell:

```bash
bash fr-sync.sh run verify_fixes.sh
```

That pushes the scripts and runs the verification suite, which should end with
`ALL VERIFIED`. Then submit, wait and fetch:

```bash
bash fr-hetsubmit.sh 13
```

```bash
bash fr-hetwait.sh 6600 het:<jobid>
```

```bash
bash fr-fetchall.sh stage2het-<jobid>
```

These scripts hard-code this project's paths, account and cluster host. On
another cluster, treat them as a worked example rather than something to run
unchanged.

---

## Where to look next

- [`README.md`](README.md): what has been measured, and what was withdrawn.
- [`docs/plan/FINAL-PLAN-2026-10.md`](docs/plan/FINAL-PLAN-2026-10.md): the plan,
  every result with its job id, the threats to validity and the defect log.
- [`router-plugin/README.md`](router-plugin/README.md): pinned versions, the
  build and the EPP flags.

The previous version of this guide described simulated GPUs, a Kind cluster and
cloud Kubernetes setups that were never used for any result. It remains in git
history: `git show 3543e10:QUICKSTART.md`.
