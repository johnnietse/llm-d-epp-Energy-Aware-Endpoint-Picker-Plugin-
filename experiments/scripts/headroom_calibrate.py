#!/usr/bin/env python3
"""Choose the packing headroom h for the Stage 5 pre-registration amendment.

    python experiments/scripts/headroom_calibrate.py \
        --homog <run_dir> <run_dir> <run_dir> --het <run_dir> <run_dir> <run_dir>

The rule below was written and committed BEFORE the calibration jobs ran
(audit 2026-10-09, plan 12.14d). Its commit precedes the job ids, which is
the evidence. Changing it after seeing calibration output is a deviation.

Revision history, both before any calibration data existed:
  a21651b  first version, one seed per fleet
  (this)   three seeds per fleet, every seed must pass (author decision
           2026-10-09: one lucky seed could otherwise pick too small an h)

Why calibrate at all. With h = 0 the three packing policies admit work until
projected latency equals the SLO, so on the homogeneous fleet they ran at
p50 1.98-2.01 s against a 2.0 s SLO and missed it for 17-70% of requests
(job 12321478). The projection itself was accurate; aiming at the boundary
was the defect. h is how far below the SLO they aim.

THE RULE
  Grid:      h in {0, 0.1, 0.2, 0.3}, nothing else.
  Policies:  slo_packing, energy_greedy, energy_consolidate (the three that
             use the headroom; round_robin and least_loaded are unaffected).
  Cells:     homogeneous 8x RTX 6000 at 100 and 150 req/s; mixed fleet at 300
             and 400 req/s. Both are loads where round_robin met the SLO for
             100% (homog) or >= 86% (mixed) of requests in Stage 2, so a cell
             failing here is the packing aim, not the fleet's capacity.
  Seeds:     exactly 3 distinct seeds per fleet (901, 902, 903), one run
             directory each.
  A cell is VALID if it is not client-limited, has at most 2% ungrounded
  router picks, and has an energy measurement (stage2_analyse criteria).
  h QUALIFIES if every one of the 36 (policy x cell x seed) combinations is
  valid and meets the SLO for at least 95% of requests.
  CHOSEN h = the smallest qualifying h.
  If no h qualifies, nothing is chosen: the script says so, exits 2, and the
  grid is NOT extended without a new rule written down first. A missing or
  invalid combination counts as a failure, never as a pass.

Smallest, not best-scoring: a larger h always costs consolidation, so the
smallest h that keeps the SLO is the one that gives the energy policies the
most room while keeping them honest. Picking the h that maximises an energy
metric would tune the design on the outcome it is meant to test.
"""
import argparse
import glob
import json
import os
import re
import sys

GRID = (0.0, 0.1, 0.2, 0.3)
POLICIES = ("slo_packing", "energy_greedy", "energy_consolidate")
CELLS = {"homog": (100.0, 150.0), "het": (300.0, 400.0)}
SEEDS = (901, 902, 903)
ATTAIN = 0.95
UNGROUNDED_MAX = 0.02


def load(run_dir):
    """{(h, rate, policy): row} from policies-[h<h>-]rate<r>.json, plus seeds seen."""
    out, seeds = {}, set()
    for p in glob.glob(os.path.join(run_dir, "policies-*rate*.json")):
        m = re.search(r"policies-(?:h([0-9.]+)-)?rate([0-9.]+)\.json$", p)
        if not m:
            continue
        for r in json.load(open(p, encoding="utf-8"))["results"]:
            h = float(r.get("headroom", m.group(1) or 0.0))
            out[(round(h, 3), float(r["offered_rate_rps"]), r["policy"])] = r
            seeds.add(r.get("seed"))
    return out, seeds


def invalid(r):
    if r.get("client_limited"):
        return "client-limited"
    if (r.get("router_ungrounded_frac") or 0.0) > UNGROUNDED_MAX:
        return "ungrounded %.1f%%" % (100 * r["router_ungrounded_frac"])
    if r.get("goodput_per_joule") is None:
        return "no energy"
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--homog", nargs="+", required=True)
    ap.add_argument("--het", nargs="+", required=True)
    a = ap.parse_args()

    runs = {}  # fleet -> {seed: data}
    for fleet, dirs in (("homog", a.homog), ("het", a.het)):
        runs[fleet] = {}
        for d in dirs:
            data, seeds = load(d)
            if len(seeds) != 1:
                raise SystemExit("%s: expected one seed per run dir, found %s" % (d, sorted(seeds)))
            s = seeds.pop()
            if s in runs[fleet]:
                raise SystemExit("%s: seed %s given twice for %s" % (d, s, fleet))
            runs[fleet][s] = data
        if sorted(runs[fleet]) != sorted(SEEDS):
            raise SystemExit("%s: need seeds %s, got %s" % (fleet, SEEDS, sorted(runs[fleet])))

    chosen = None
    for h in GRID:
        fails = 0
        print("h = %.1f" % h)
        for fleet, rates in CELLS.items():
            for rate in rates:
                for pol in POLICIES:
                    for seed in SEEDS:
                        r = runs[fleet][seed].get((round(h, 3), rate, pol))
                        why = "MISSING" if r is None else invalid(r)
                        ok = why is None and r["slo_rate"] >= ATTAIN
                        fails += not ok
                        print("  %-5s %5.0f %-19s seed %d  %s" % (
                            fleet, rate, pol, seed,
                            "invalid: " + why if why else
                            "SLO met %5.1f%%  p50 %.2fs  p95 %.2fs  %s" % (
                                100 * r["slo_rate"], r["latency_p50"],
                                r["latency_p95"], "ok" if ok else "FAIL")))
        print("  -> %s" % ("QUALIFIES" if not fails else "%d of 36 failing" % fails))
        if not fails and chosen is None:
            chosen = h
    if chosen is None:
        print("\nNO h IN %s QUALIFIES. Nothing chosen; write a new rule before "
              "extending the grid." % (GRID,))
        return 2
    print("\nCHOSEN h = %.1f (smallest qualifying, all 3 seeds)" % chosen)
    return 0


if __name__ == "__main__":
    sys.exit(main())
