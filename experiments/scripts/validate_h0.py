#!/usr/bin/env python3
"""Validation of h = 0 across the full Stage 5 load ladders, before the freeze.

    python experiments/scripts/validate_h0.py \
        --homog <run_dir> <run_dir> <run_dir> --het <run_dir> <run_dir> <run_dir>

Committed BEFORE its data (author's "go", 2026-10-09). It is a check, not a
choice: h was already chosen (calibration v3, h = 0). It asks whether h = 0
holds where calibration did not look, under the final router design.

Why it is needed (plan 12.14d):
  * Calibration v3 tested the mixed fleet only at 300/400 req/s, where the
    four A100s sufficed, so no RTX 6000 carried mixed-fleet traffic.
  * The tie-break changed to a seeded random choice (--tiebreak random).
    Energy-blind policies may now load RTX 6000s at any load, which
    calibration never exercised.
  * Two assumptions are only checkable on the real fleets: curves were
    measured with one server per node (the fleets run four plus the
    generator), and the router compares a live in-flight count with a curve
    indexed by MEAN in-flight.

THE RULE
  Router:   open-loop curves, max_inflight 256, h = 0, tiebreak random.
  Policies: slo_packing, energy_greedy, energy_consolidate.
  Cells:    the Stage 5 ladders. Mixed fleet 200, 300, 400, 500, 600 req/s
            (measured open-loop capacity about 4 x 128 + 4 x 61 = 756);
            one-type fleet 100, 150, 200, 250, 300 req/s (capacity about
            8 x 61 = 488). Every cell is below measured capacity, so a
            correct packer must meet the SLO in all of them.
  Seeds:    921, 922, 923, one run directory each.
  PASS if every one of the 90 (policy x cell x seed) combinations is valid
  (not client-limited, at most 2% ungrounded, energy present, and run with
  the router above) and meets the SLO for at least 95% of requests.
  On FAIL: stop and report. h is not re-chosen and nothing is tuned until a
  new rule is written down.

Only SLO attainment and validity are read. The energy outcome of these runs
is not inspected before the freeze, so it cannot steer the design (it stays
pilot data either way).
"""
import argparse
import glob
import json
import os
import re
import sys

POLICIES = ("slo_packing", "energy_greedy", "energy_consolidate")
CELLS = {"homog": (100.0, 150.0, 200.0, 250.0, 300.0),
         "het": (200.0, 300.0, 400.0, 500.0, 600.0)}
SEEDS = (921, 922, 923)
ATTAIN = 0.95
UNGROUNDED_MAX = 0.02


def load(run_dir):
    out, seeds = {}, set()
    for p in glob.glob(os.path.join(run_dir, "policies-*rate*.json")):
        if not re.search(r"policies-(?:h[0-9.]+-)?rate[0-9.]+\.json$", p):
            continue
        for r in json.load(open(p, encoding="utf-8"))["results"]:
            out[(float(r["offered_rate_rps"]), r["policy"])] = r
            seeds.add(r.get("seed"))
    return out, seeds


def invalid(r):
    if r.get("client_limited"):
        return "client-limited"
    if (r.get("router_ungrounded_frac") or 0.0) > UNGROUNDED_MAX:
        return "ungrounded %.1f%%" % (100 * r["router_ungrounded_frac"])
    if r.get("goodput_per_joule") is None:
        return "no energy"
    if r.get("curve_kind") != ["openloop"]:
        return "curves %s" % r.get("curve_kind")
    if r.get("max_inflight") != 256:
        return "max_inflight %s" % r.get("max_inflight")
    if float(r.get("headroom", -1)) != 0.0:
        return "headroom %s" % r.get("headroom")
    if r.get("tiebreak") != "random":
        return "tiebreak %s" % r.get("tiebreak")
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--homog", nargs="+", required=True)
    ap.add_argument("--het", nargs="+", required=True)
    a = ap.parse_args()
    runs = {}
    for fleet, dirs in (("homog", a.homog), ("het", a.het)):
        runs[fleet] = {}
        for d in dirs:
            data, seeds = load(d)
            if len(seeds) != 1:
                raise SystemExit("%s: expected one seed, found %s" % (d, sorted(seeds)))
            runs[fleet][seeds.pop()] = data
        if sorted(runs[fleet]) != sorted(SEEDS):
            raise SystemExit("%s: need seeds %s, got %s" % (fleet, SEEDS, sorted(runs[fleet])))
    fails = 0
    for fleet, rates in CELLS.items():
        for rate in rates:
            for pol in POLICIES:
                for seed in SEEDS:
                    r = runs[fleet][seed].get((rate, pol))
                    why = "MISSING" if r is None else invalid(r)
                    ok = why is None and r["slo_rate"] >= ATTAIN
                    fails += not ok
                    print("  %-5s %5.0f %-19s seed %d  %s" % (
                        fleet, rate, pol, seed, "invalid: " + why if why else
                        "SLO met %5.1f%%  p95 %.2fs  %s" % (
                            100 * r["slo_rate"], r["latency_p95"], "ok" if ok else "FAIL")))
    if fails:
        print("\nVALIDATION FAILED: %d of 90 combinations. Stop and report; "
              "nothing is re-chosen without a new rule." % fails)
        return 2
    print("\nVALIDATION PASSED: h = 0 holds at every Stage 5 load, all 3 seeds.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
