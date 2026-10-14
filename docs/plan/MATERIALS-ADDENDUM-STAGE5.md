# Stage 5 materials addendum (DRAFT, not yet tagged)

| | |
|---|---|
| **Status** | **DRAFT.** It becomes binding when tagged `prereg-stage5-v1-materials` (the name section 9 fixed), before trial 1. |
| **Scope** | Section 9 of `PREREGISTRATION-STAGE5.md`: implementations and configs only. Nothing here changes a hypothesis, outcome definition, operating-point rule, SLO, alpha, sample size, seed, exclusion rule or analysis code (`prereg_analysis.py`, `stage2_analyse.py`). |
| **Governs with** | Section 15 (amendment 1, tag `prereg-stage5-v2`). |

## M1. The router policies (section 10 items 1-2, amendment B11)

- **Code:** `router-plugin/pkg/energypolicy` (9afbd9f).
  - `energy-epp-policy-scorer` gives 1.0 to exactly the set of endpoints the
    Python `Router` chooses between before its tie-break.
  - `energy-epp-seeded-random-picker` chooses uniformly within that set from
    the trial seed (B5).
- **Fidelity test:** on 9,856 recorded states (2,077 with ties), `Decide`
  returns Python's tied set and outcome exactly. Three planted mutants are
  caught. 1,408 states are re-run through framework endpoints behind the
  router's data scoping.
- **Binary:** `bash router-plugin/build.sh` gives sha256
  `a7664114de00dd878548357598a30c3a88b6e5f0fc24d71a4720931c1fed5fa0`, the
  same across two builds. The job refuses any other hash.
- **Curves:** `router-plugin/curves/a100.json` and `rtx6000.json`, exported
  by `export_router_fixtures.py` through `load_openloop_curve`. Sources are
  `olc-12325349/curve.csv` (sha256 `2b38f406a778fc46...`) and
  `olc-12325350/curve.csv` (`d68c6772e6a2915d...`), as B2 names them.

## M2. Arm configurations (section 10 item 5)

Configs are written by `router-plugin/configs/epp-config.sh`.
`check-configs.sh` loads each one in the built binary and prints its final
scheduling profile.

Every project arm declares exactly one in-flight producer, under the default
name `inflight-load-producer` (see the checklist below).

| Arm | Profile after v0.11.0's defaults |
|---|---|
| `energy_consolidate`, `energy_greedy`, `slo_packing`, `round_robin` | inert concurrency detector (limit 10^9), policy scorer, seeded picker; `injectDefaults: false` |
| `random` | inert concurrency detector, upstream `random-picker` (unseeded) |
| `stock_llmd` | upstream `deploy/config/epp-config.yaml` plus file discovery, every default on: `decode-filter`, default utilization-detector filter, `prefix-cache-scorer` (weight 2), `max-score-picker` |

- **Why the inert detector:** v0.11.0 adds a saturation detector to every
  scheduling profile as a filter, even with flow control off. Its default
  drops endpoints whose metrics are stale. With no scraping, every endpoint
  is stale, so that default is inert only through its fail-open fallback.
  The project arms set one that is inert by construction.
- **`stock_llmd`:** the author chose this on 2026-10-13. `decode-filter`
  keeps endpoints without an llm-d role label, so it passes the fleet
  through.
- **`llmd_latency_least`:** pending its feasibility check (B7). If the
  predictor cannot run, the arm and H4 are dropped here, with the reason.

## M3. Load generator in router mode (section 10 item 3)

`policy_harness.py --router <envoy> --epp-metrics <epp>` sends every request
to the Envoy listener; the EPP chooses the server. The validity fields of
section 7 come from the EPP's `energy_epp_policy_picks_total`, with the same
denominator (completed requests) as the Python `Router` used:

- `router_ungrounded_frac` counts ungrounded plus misconfigured picks.
- Arms without this project's scorer (`stock_llmd`, `random`) make no
  curve-based decision, so both fractions are 0.
- If the EPP metrics cannot be read, the cell is recorded as fully
  ungrounded, so it fails validity rather than passing unverified.

## M4. Energy window (author decision 2026-10-13)

- **Which window:** Stage 5 runs with `--energy-window traffic`. A cell's
  energy and keep-up are taken from the schedule origin to the last request
  completion.
- **Why:** the earlier window ran until every generator worker process had
  exited. Worker teardown then counted as serving time. The sensitivity
  jobs 12330596/8 showed about 14 s of it in some cells, with no request
  affected. The traffic window is the "measurement window" of section 3
  with generator teardown left out.
- **Fields:** the chosen window fills the fields the frozen analysis reads
  (`goodput_per_joule`, `j_per_request`, `keepup`, `goodput_rps`). The join
  window is kept with a `_join` suffix.
- **Missing energy:** if the traffic-window energy is missing, the fields are
  empty rather than taken from the other window, and the analysis refuses
  the cell as "no energy".
- **Comparability:** Stage 2's pilot used the join window. Pilot data is
  never confirmatory (section 1, B12), so no comparison depends on the two
  windows being equal.

## M5. Wall-clock steps (author decision 2026-10-13)

- **What is recorded:** every cell records `clock_step_s`, wall time minus
  monotonic time over the cell.
- **The rule:** a cell with |`clock_step_s`| > 0.1 s is an infrastructure
  failure under section 7. It is re-run with the same seed, and the event is
  logged.
- **Limit:** if the same cell steps three times, the trial job fails and is
  resubmitted with the same seed, like any infrastructure failure.
- **Not a new exclusion criterion:** a stepped cell's intervals are not a
  measurement, so it is re-run, never analysed or excluded.

## M6. Energy is metered over the serving GPUs only

- **The rule:** section 3 defines energy as "summed over all GPUs of the
  fleet". The fleet is the GPUs that serve: 4 A100 + 4 RTX 6000 on the mixed
  fleet, 8 RTX 6000 on the homogeneous one.
- **How it is enforced:** `stage5_trial.sbatch` starts each node's sampler
  with `--gpus 0..N-1`. It launches vLLM with `CUDA_DEVICE_ORDER=PCI_BUS_ID`,
  so CUDA's device *i* is NVML's index *i*. It refuses to run if a sampler
  meters a different number of GPUs than the fleet uses.
- **Why it is written down:** the Stage 2 mixed-fleet script started its
  samplers without `--gpus`. On frnt154 (8 A100s, 4 serving) every Stage 2
  mixed-fleet cell therefore summed 12 GPUs. The 4 idle A100s (NVML 4-7, about
  2.2-2.5 kJ each per cell) were 7.3-17.4% of each cell's energy, mean 10.4% over 225 cells
  (`stage2_serving_gpu_reanalysis.py`; an earlier "roughly 15%" came from one
  cell).
- **Effect on Stage 2:** the same for every arm within a cell, so it cannot
  reverse a comparison, but it dilutes every margin. Stage 2 is pilot data
  (B12), so nothing confirmatory depends on it.

**M6 consequence for B10's power statement.** Recomputed over serving GPUs,
the pilot SD is 0.627, not 0.538 (`stage2_serving_gpu_reanalysis.py`).
- At n = 25, power is 0.951 at its 80% upper bound, which still meets the
  0.90 target the sample size was set for.
- At the 90% upper bound it is 0.700, not the 0.82 B10 quotes.
- B10 is frozen and n is unchanged. This corrects a stated figure; it does
  not change the design.

## M7. Open: the llmd_latency_least SLO split (B7)

- **What B7 says:** the TTFT/TPOT split follows "Stage 1's median TTFT share
  of end-to-end latency at concurrency 1 on the RTX 6000".
- **The problem:** Stage 1 never recorded TTFT. Its closed-loop sweep did not
  stream, and neither `h1.csv` nor `trace.jsonl` has a TTFT field. The
  registered source does not exist.
- **The nearest measured equivalent:** the RTX 6000 open-loop curve
  `olc-12325350` at its lowest rate (1 req/s, mean in flight 1.0-1.45,
  trials 2-6).
  - The median TTFT share there is 0.0270.
  - That gives a TTFT SLO of 54.0 ms and a TPOT SLO of 15.32 ms
    (54.0 + 127 x 15.32 = 2000 ms).
- **Status:** the author's decision. The feasibility job uses it
  provisionally.

## Still to come before the tag

- [x] **The Stage 5 run script:** `stage5_trial.sbatch` (6672d2c), submitted
      with `fr-stage5.sh`.
      - Per level: a discarded round_robin warm-up (`WARMUP_S`, default
        30 s), then the arms in a permutation seeded by trial seed and level.
      - Each arm gets a fresh EPP and Envoy. The in-flight wiring is checked
        before any request.
      - `--energy-window traffic` (M4); the clock-step re-run rule (M5);
        serving-GPU metering (M6).
      - Seed guard: real trials only with 501-531 / 601-631; dry runs never
        with them.
- [x] **One-type dry run PASSED** (job 12341686, frnt155, seed 991, records
      committed).
      - Both levels ran with all six arms, each routed through the router with
        the traffic window, in recorded seeded orders.
      - Every project arm made exactly one EPP decision per request (3,000 at
        100 req/s; 9,000 at 300). None was ungrounded or misconfigured.
        `clock_step_s` was about 0.
      - **It confirms M4:** worker teardown on the cluster was 16-30 s per
        cell (223 s in one stock_llmd cell). The old join window would have
        shifted J/request by 25-35%.
- [ ] **Mixed dry run, retry** (job 12341684). The first attempt (12335940)
      failed because file discovery needs IPv4 literals. Fixed in 22715e9.
- [x] **The `llmd_latency_least` arm is FEASIBLE on Frontenac** (job
      12341687, records committed).
      - **Install:** llm-d-latency-predictor at commit c810ebcb, with 53
        pinned wheels for the vLLM image's Python 3.12, installed offline
        inside the container.
      - **Routing:** six consecutive 60 s cells at 20 req/s on 2 RTX 6000s
        went through the llm-d latency stack with SLO headers, with 0 EPP
        prediction errors.
      - **Cold start:** the untrained first cell gave p95 7.06 s and 87% SLO.
        Cells 2-6 gave p95 1.66-1.75 s and 100%, with the model reloaded
        every 1-2 min (retraining interval 60 s in this test).
- [ ] **Author's decisions for this arm.**
      - The SLO split (M7).
      - A training rule, needed because of the cold start. The upstream
        default retrains every 1800 s, so without a rule the arm would run
        untrained for its first 30 minutes.
- [ ] The author's sign-off, then the tag.
