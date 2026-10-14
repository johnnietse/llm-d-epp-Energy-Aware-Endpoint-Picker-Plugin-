#!/usr/bin/env python3
"""LABELLED RE-ANALYSIS of the Stage 2 pilot: energy over the SERVING GPUs only.

    python experiments/scripts/stage2_serving_gpu_reanalysis.py

Why (plan 2026-10-13, materials addendum M6). The Stage 2 mixed-fleet samplers
ran without --gpus, so every cell summed all 8 A100s on frnt154 although the
fleet used 4 (plus the 4 RTX 6000s). The 4 idle A100s added about 15% to every
cell's energy, equally across policies within a cell, so they cannot reverse a
comparison but they dilute every margin.

What this does. It recomputes each cell's energy from the per-GPU figures the
records already hold, dropping the A100s the fleet did not use (NVML index
>= the per-type fleet size, 4), and recomputes goodput_per_joule and
j_per_request from it. It then runs the FROZEN analysis (prereg_analysis.py,
--pilot) unchanged on those cells, with stage2_analyse.load patched to return
the corrected records. Nothing is written back to the records.

The dropped GPUs are checked, not assumed: in every cell each dropped GPU's
mean power must be below IDLE_MAX_W, and each kept A100 is reported. A busy
dropped GPU would mean CUDA and NVML numbered the GPUs differently; the script
then stops rather than drop the wrong card.

This is pilot data and never confirmatory (pre-registration section 1, B12).
The one-type run (stage2-12321478) used all 8 of its GPUs and is unchanged.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
RES = os.path.join(HERE, "..", "cluster-records", "results")
sys.path.insert(0, HERE)
import stage2_analyse as gate  # noqa: E402
import prereg_analysis as pa   # noqa: E402

HET = ["stage2het-12305232", "stage2het-12319685", "stage2het-12321476"]
HOMOG = ["stage2-12321478"]
FLEET_PER_TYPE = 4
IDLE_MAX_W = 60.0

_orig_load = gate.load
audit = {"cells": 0, "dropped_max_w": 0.0, "kept_a100_min_w": 1e9, "share": []}


def serving_rows(run_dir):
    rows = _orig_load(run_dir)
    if os.path.basename(os.path.normpath(run_dir)) not in HET:
        return rows
    for r in rows:
        pg = r["energy"]["per_gpu"]
        keep, drop = [], []
        for g in pg:
            a100 = "A100" in (g.get("name") or "")
            (drop if a100 and g["index"] >= FLEET_PER_TYPE else keep).append(g)
        if len(keep) != 2 * FLEET_PER_TYPE:
            raise SystemExit("%s %s: kept %d GPUs, expected %d"
                             % (run_dir, r["policy"], len(keep), 2 * FLEET_PER_TYPE))
        for g in drop:
            if (g.get("mean_power_w") or 0) >= IDLE_MAX_W:
                raise SystemExit("%s %s rate %s: dropped A100 %d drew %.1f W, not idle; "
                                 "GPU numbering may differ, refusing"
                                 % (run_dir, r["policy"], r.get("offered_rate_rps"),
                                    g["index"], g["mean_power_w"]))
            audit["dropped_max_w"] = max(audit["dropped_max_w"], g["mean_power_w"])
        for g in keep:
            if "A100" in (g.get("name") or ""):
                audit["kept_a100_min_w"] = min(audit["kept_a100_min_w"], g.get("mean_power_w") or 0)
        full = r["energy"]["total_energy_j"]
        e = sum(g["energy_j"] for g in keep)
        audit["cells"] += 1
        audit["share"].append(1 - e / full)
        r["energy_full_node_j"] = full
        r["energy"] = dict(r["energy"], total_energy_j=e)
        met, done = r.get("slo_met") or 0, r.get("completed") or 0
        r["goodput_per_joule"] = met / e if e else None
        r["j_per_request"] = e / done if done else None
    return rows


def main():
    print("=" * 72)
    print("ORIGINAL (all GPUs on each node, as recorded)")
    sys.argv = ["prereg_analysis.py", "--pilot", "--het"] + [os.path.join(RES, d) for d in HET] \
        + ["--homog"] + [os.path.join(RES, d) for d in HOMOG]
    pa.main()
    gate.load = serving_rows
    pa.gate.load = serving_rows
    print()
    print("=" * 72)
    print("RE-ANALYSIS: serving GPUs only (labelled; pilot; not confirmatory)")
    pa.main()
    s = audit["share"]
    print()
    print("audit: %d mixed-fleet cells; idle-GPU share of recorded energy %.1f%% to %.1f%% "
          "(mean %.1f%%); dropped A100s at most %.1f W; kept A100s at least %.1f W"
          % (audit["cells"], 100 * min(s), 100 * max(s), 100 * sum(s) / len(s),
             audit["dropped_max_w"], audit["kept_a100_min_w"]))


if __name__ == "__main__":
    main()
