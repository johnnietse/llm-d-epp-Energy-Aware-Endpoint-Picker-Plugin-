#!/usr/bin/env python3
"""Choose the packing headroom h for the Stage 5 pre-registration amendment.

    python experiments/scripts/headroom_calibrate.py <homog_run_dir> <het_run_dir>

The rule below was written and committed BEFORE the calibration jobs ran
(audit 2026-10-09, plan 12.14d). Its commit precedes the job ids, which is
the evidence. Changing it after seeing calibration output is a deviation.

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
  A cell is VALID if it is not client-limited, has at most 2% ungrounded
  router picks, and has an energy measurement (stage2_analyse criteria).
  h QUALIFIES if every one of the 12 (policy x cell) combinations is valid
  and meets the SLO for at least 95% of requests.
  CHOSEN h = the smallest qualifying h.
  If no h qualifies, nothing is chosen: the script says so, exits 2, and the
  grid is NOT extended without a new rule written down first.

Smallest, not best-scoring: a larger h always costs consolidation, so the
smallest h that keeps the SLO is the one that gives the energy policies the
most room while keeping them honest. Picking the h that maximises an energy
metric would tune the design on the outcome it is meant to test.
"""
import glob
import json
import os
import re
import sys

GRID = (0.0, 0.1, 0.2, 0.3)
POLICIES = ("slo_packing", "energy_greedy", "energy_consolidate")
CELLS = {"homog": (100.0, 150.0), "het": (300.0, 400.0)}
ATTAIN = 0.95
UNGROUNDED_MAX = 0.02


def load(run_dir):
    """{(h, rate, policy): row} from policies-[h<h>-]rate<r>.json."""
    out = {}
    for p in glob.glob(os.path.join(run_dir, "policies-*rate*.json")):
        m = re.search(r"policies-(?:h([0-9.]+)-)?rate([0-9.]+)\.json$", p)
        if not m:
            continue
        for r in json.load(open(p, encoding="utf-8"))["results"]:
            h = float(r.get("headroom", m.group(1) or 0.0))
            out[(round(h, 3), float(r["offered_rate_rps"]), r["policy"])] = r
    return out


def invalid(r):
    if r.get("client_limited"):
        return "client-limited"
    if (r.get("router_ungrounded_frac") or 0.0) > UNGROUNDED_MAX:
        return "ungrounded %.1f%%" % (100 * r["router_ungrounded_frac"])
    if r.get("goodput_per_joule") is None:
        return "no energy"
    return None


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__.split("\n\n")[0])
    data = {"homog": load(sys.argv[1]), "het": load(sys.argv[2])}
    chosen = None
    for h in GRID:
        fails = []
        print("h = %.1f" % h)
        for fleet, rates in CELLS.items():
            for rate in rates:
                for pol in POLICIES:
                    r = data[fleet].get((round(h, 3), rate, pol))
                    if r is None:
                        why, att = "MISSING", None
                    else:
                        why, att = invalid(r), r["slo_rate"]
                    ok = why is None and att >= ATTAIN
                    if not ok:
                        fails.append((fleet, rate, pol))
                    print("  %-5s %5.0f %-19s %s" % (
                        fleet, rate, pol,
                        "invalid: " + why if why else
                        "SLO met %5.1f%%  p50 %.2fs  p95 %.2fs  %s" % (
                            100 * att, r["latency_p50"], r["latency_p95"],
                            "ok" if ok else "FAIL")))
        print("  -> %s" % ("QUALIFIES" if not fails else "%d failing" % len(fails)))
        if not fails and chosen is None:
            chosen = h
    if chosen is None:
        print("\nNO h IN %s QUALIFIES. Nothing chosen; write a new rule before "
              "extending the grid." % (GRID,))
        return 2
    print("\nCHOSEN h = %.1f (smallest qualifying)" % chosen)
    return 0


if __name__ == "__main__":
    sys.exit(main())
