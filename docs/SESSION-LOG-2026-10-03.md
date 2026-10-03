# Session log, 2026-10-03

Written because this session was long enough to be context-compacted and the
memory tool that was supposed to record it was dead for the whole day (see
"Infrastructure" below). The verbatim transcript is at
`~/.claude/projects/C--/757beada-62ef-47d9-9a04-72567e18fd44.jsonl`; this file
is the durable, reviewable summary.

## What was asked

1. Decide whether cloud GPU rental was needed given Frontenac exists, and
   whether NVML was still the right telemetry choice against CUPTI, Nsight,
   DCGM and nvidia-smi.
2. Download and test the alternative telemetry tools on Frontenac "as a
   backup" even if not adopted.
3. Treat the eight supplied paper drafts as proposals, not data.
4. Run the H1 sweep pinned to one node and driver.
5. Validate the setup, topic and approach against current literature.
6. Audit the whole project (plan, code, branches) and finalize the plan.
7. Fix the memory tooling.

## What was decided

**Cloud rental: dropped.** A probe established that Frontenac already supplies
what rental was for. `--exclusive` gives genuine single-tenancy, `-w`/`-C` pin
hardware, and the real inventory is better than the plan assumed: three 8-GPU
A100 nodes (`frnt154`, and the DGX pair `frnt190`/`frnt191`), 8-GPU RTX 6000
(`frnt155`), 8-GPU RTX 8000 (`frnt156`), and roughly 36 four-GPU RTX 6000
nodes. Seven GPU types. The only thing rental uniquely offered was root for
power capping, which is a CAC request rather than a purchase.

**Simulation: dropped entirely**, per explicit instruction ("we don't want
simulation because it is not real"). Every previously-simulated scenario has a
real equivalent on the cluster. The only remaining model is the offline bound
at the Stage 2 gate, which is a planning instrument and never a reported
result.

**NVML stays primary**, now for a measured reason: it was the only source that
worked on every node without privilege.

## Measurements

### Canonical H1 run (job 12303088, `frnt109`, pinned, exclusive, 5 trials)

Full write-up: `experiments/h1-2026-10-03-frnt109/README.md`.

- **Trial 1 is a warm-up transient.** 17.4 W below the others at c=1, far
  outside their +/- 0.20 W interval; including it widened that interval
  48-fold. Protocol now discards it.
- **Active power is near-constant** 187-204 W across a 32x load range, while
  throughput scales 20.7x, so `J/token = P_active/throughput` falls 21.2x.
- **H1's linear model is refuted.** Power is non-monotonic (highest at c=1,
  minimum at c=2, then rising), so the fitted slope from c=1 to c=32 is
  *negative*. The earlier `k_b` values (0.46 W, then 0.24 W) were fitting noise
  around a flat curve. The marginal term and every ratio built on it were
  withdrawn.
- **Activation dominates**: resident-idle 54.33 W to 203.97 W at c=1 is a
  **+149.64 W** step; adding load to a serving GPU is free to within
  measurement error. Idle floor is 27% of peak-load power. This is the robust
  half and it carries the consolidation argument alone.
- **Cross-node offset**: against the superseded `frnt152` run, same GPU model
  and driver, J/token agrees to 0.3% at c=1 but carries a consistent ~6% offset
  at every level from c=2 up; bare idle was 13.10 W against 22.0 W. Policy
  comparisons must be within-node or block on node.

### Defect S1 resolved: the prefix-cache conflict was a metric artifact

The validity review had called the apparent cache-versus-energy conflict the
most interesting open question in the project. It had no premise. At c=8, the
shared-prefix arm carries **8.5x more prompt tokens**, and prefill is real
work:

| | unique | shared prefix |
|---|---|---|
| J / generated token | 0.2259 | 0.2391 (1.06x worse) |
| J / total token | 0.1770 | **0.0680 (2.6x better)** |
| requests completed | 496 | **655 (1.32x)** |

Caching improved energy per unit work *and* goodput simultaneously. The
generalisable lesson, now binding on the whole paper: two defensible
denominators can invert a policy ranking, so the primary metric must be fixed
in advance.

## Instrumentation findings

All tools were downloaded and tested in user space (`~/energy-epp/opt`, 5.3 GB,
removable with one `rm -rf`). Details:
`experiments/instruments-2026-10-03/README.md`.

| Source | Verdict |
|---|---|
| NVML | works everywhere, unprivileged. Primary. |
| DCGM energy (field **156**) and power (155) | work unprivileged everywhere tested |
| DCGM profiling fields | **node-dependent**, see below |
| dcgm-exporter 4.8.4 | serves all 80 series unprivileged on a permissive node |
| CUPTI / Nsight **tracing** | work even where counters are denied |
| CUPTI / Nsight **counters** | denied where `RmProfilingAdminOnly=1` |
| IPMI | `/dev/ipmi0` exists, root-only 0600 |

**The incidental finding worth a paper paragraph:** within one cluster, three
things are non-uniform across nodes of the same GPU model.

1. **NVIDIA driver version** — 580.173.02, 610.43.02 and 610.57.04 all in
   service. Counter sampling is a driver property, so this is a blocking
   comparability variable, not a detail.
2. **GPU profiling permission** — `RmProfilingAdminOnly` is 1 on 13 of 15 nodes
   surveyed and 0 on two. It does **not** track the kernel build, so it is
   configuration drift with accidental-looking exceptions.
3. **Bare idle power** — 13.10 W against 22.0 W on identical models.

DCGM field **156** is the NVML counter surfaced through DCGM, verified by a
reading that fell between two NVML readings taken either side of it. So DCGM is
not an independent sensor; node-level IPMI would be the only independent check.

## The audit that changed the project

The plan and the code described **two different projects**. `pkg/` holds 45 Go
files that build cleanly and pass every test, and almost all of it implements
the design the validity review had already discarded:

- `energy_aware_scorer.go` scores with
  `w_latency*S_latency + w_energy*S_energy + w_carbon*S_carbon` and uses
  `profile.TDP_Watts / 700.0` as a proxy for both compute capability and
  carbon, when our measurements show active power is near-constant
- it targets `gateway-api-inference-extension v1.5.0`, not llm-d-router
- `pkg/adaptive/weight_controller.go` is the drafts' Schmitt-trigger FSM
- `pkg/simulation/e2e_simulation_test.go` is 390 lines of simulated evaluation
- `pkg/ebpf/` and `pkg/slurm/spank_adapter.go` both **require privilege**,
  contradicting the paper's central "no privileged control" framing

The plans mentioned `pkg/` four times, and the only substantive mention was in
the superseded v1. The direction the plan commits to had no implementation.
Result: `docs/plan/FINAL-PLAN-2026-10.md`, with a per-package disposition, and
tag `pre-rescope-2026-10-03` (`bda1f97`) preserving the drafts' design for the
thesis design-space chapter.

## Literature verification

Every arXiv identifier was fetched and checked against the live record rather
than trusted from notes. All five existed and titles matched, but:

- **2604.04745 had been recorded wrongly here** as "idle 53% to 96%". The paper
  says execution-idle is 19.7% of execution time and 10.7% of energy. Our 27%
  idle floor is therefore not corroborated by it.
- **2608.06188's headline is simulated** (year-long historical replay, stated
  as an upper bound).

Four pieces of prior art had been missed. The important one: **vLLM
semantic-router issue #2332** is an open epic whose engine-neutral observation
contract already names "energy/power evidence and its measured/modeled
provenance". A second production router is building this plumbing. Still
unimplemented, so the gap holds, but the window is narrowing. Also found:
arXiv 2603.21354 (vLLM vision paper), GreenServ 2601.17551 (bandit routing
across 16 models), RequestRouter 2605.23057, and the model-routing survey
2603.04445.

**Framing consequence:** the claim must be stated as replica/endpoint selection
among interchangeable backends of one model, explicitly separated from model
selection, where most 2026 energy-routing work sits.

## Corrections made the same day

Left visible rather than edited away, because the negative results depend on
this discipline.

1. "DCGM is unusable without root" — **wrong**. A `dcgmi` call with the
   subsystem after `--host` returns `ERROR: Invalid subsystem`, which I read as
   a privilege failure, then generalised one node to the cluster.
2. "The permissive node is behind on patching" — **refuted** by the survey.
3. 2604.04745's figures — **corrected**.
4. H1's marginal term and its ratios — **withdrawn**.

## Infrastructure

**claude-mem wrote nothing from 2026-09-30 to 2026-10-03 21:00.** Root cause:
it generates summaries by spawning its own `claude` CLI, whose OAuth session
had expired (`claude auth status` returned `loggedIn: false`). Every generator
died at startup; a stale `memory_session_id` then surfaced as
`NOT NULL constraint failed`, which is the error the banner reported — the last
symptom, not the cause. Restarting the worker did not fix it; upgrading the CLI
(2.1.259 to 2.1.288) did not fix it; `claude auth login` plus a worker restart
did. Verified by querying the database, not the log.

The gap is **not recoverable** into claude-mem: there is no retroactive ingest
path for Claude Code transcripts (its transcript watcher is configured for
Codex sessions), and flushing the 46-item backlog produced only
meta-observations about claude-mem itself. Hence this file.

## State at session end

- Branch `docs/technical-plan-v2`, pushed. Tag `pre-rescope-2026-10-03`.
- Canonical measurement: `experiments/h1-2026-10-03-frnt109/`.
- A30 sweep submitted as job 12303200 on `frnt140` (driver 610.43.02, matching
  the RTX 6000 run so GPU model is isolated from driver).

Open, and each needing a human decision or action:

| Item | Status |
|---|---|
| Stage 0 code rescope | decided in the final plan, not executed |
| Stage 2 offline gate | **the blocking question**: does a comparative result exist at all? |
| CAC access request | drafted at `docs/plan/cac-access-request.md`, **not sent** |
| Two CAC passwords | exposed in chat and PowerShell history; **rotate** |
| PowerShell history | clear with `Remove-Item (Get-PSReadlineOption).HistorySavePath -Force` |
