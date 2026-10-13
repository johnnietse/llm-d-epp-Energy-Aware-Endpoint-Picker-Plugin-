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

## Still to come before the tag

- [ ] The Stage 5 run script: per-level warm-up, seeded arm order per level,
      an EPP restart per arm, `--energy-window traffic`, the M5 re-run
      rule, and per-node energy samplers (section 10 item 4).
- [ ] The `llmd_latency_least` feasibility check and its outcome (B7).
- [ ] A cluster smoke test with real vLLM servers. It checks pick counts,
      outcome counters, router mode end to end, and the EPP's in-flight
      count against vLLM's running and waiting gauges (the scheduling-cycle
      race noted in the plan).
- [ ] The author's sign-off, then the tag.
