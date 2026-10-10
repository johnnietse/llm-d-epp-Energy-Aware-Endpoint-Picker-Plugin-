#!/usr/bin/env python3
"""Corrected validation rule for the h = 0 check (v2). Committed BEFORE its data.

    python experiments/scripts/validate_capacity.py \
        --validation <homog_dir> <homog_dir> <homog_dir> <het_dir> <het_dir> <het_dir> \
        --reference <ref_dir> <ref_dir> <ref_dir>

Why a v2 exists (plan 12.14d). validate_h0.py (d4029c3) FAILED 81 of 90:
only the one-type fleet at 300 req/s failed, for every packer and seed. Its
premise, "every cell is below capacity", was wrong. It used the RTX 6000's
stationarity limit (about 61 req/s per GPU, 488 for the fleet) where the SLO
limit applies (about 33 req/s per GPU, about 265 for the fleet). The v1
verdict stays on record as FAILED. This rule does not overwrite it; it
corrects the premise and tests that correction directly.

THE RULE
  Definition. A cell is BEYOND FLEET CAPACITY if both energy-blind
  spreading policies, round_robin and least_loaded, also meet the SLO for
  fewer than 95% of requests there, in every one of the reference seeds,
  under the same conditions: the same fleet, rate, curves, cap, vLLM
  limits, h = 0 and the random tie-break. Spreading is what any router can
  do best when no endpoint has spare capacity, so if it fails, no routing
  rule can pass.
  Reference runs. round_robin and least_loaded on the one-type fleet at
  300 req/s, seeds 921-923 (the same seeds as the v1 validation).
  Verdict.
    * If the 300 req/s cell is beyond capacity, it is excluded. Validation
      PASSES if every other combination of the v1 validation passed (they
      did: 81 of 81, recorded in validation-h0-verdict.txt; this script
      re-checks them from the records).
    * If either spreading policy meets 95% in any reference seed, the cell
      is within capacity. The packers' failure there is then a real defect:
      validation FAILS, and the result is reported, not tuned.
  Only SLO attainment and validity are read, never energy.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import validate_h0 as v1  # noqa: E402

REF_POLICIES = ("round_robin", "least_loaded")
REF_FLEET, REF_RATE = "homog", 300.0
ATTAIN = v1.ATTAIN


def ref_invalid(r):
    """Validity for the reference runs. They must run under the final router
    design. The tie-break and cap never change what round_robin does, but they
    are required anyway so the conditions are identical."""
    why = v1.invalid(r)
    return why


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--validation", nargs=6, required=True,
                    help="the six v1 validation run dirs: 3 homog then 3 het")
    ap.add_argument("--reference", nargs=3, required=True,
                    help="three one-type reference run dirs, seeds 921-923")
    a = ap.parse_args()

    # Re-check the v1 cells from the records, excluding nothing yet.
    runs = {"homog": {}, "het": {}}
    for fleet, dirs in (("homog", a.validation[:3]), ("het", a.validation[3:])):
        for d in dirs:
            data, seeds = v1.load(d)
            if len(seeds) != 1:
                raise SystemExit("%s: expected one seed" % d)
            runs[fleet][seeds.pop()] = data
        if sorted(runs[fleet]) != sorted(v1.SEEDS):
            raise SystemExit("%s: need seeds %s" % (fleet, v1.SEEDS))

    # Reference: is the 300 req/s one-type cell beyond fleet capacity?
    ref, seen = {}, set()
    for d in a.reference:
        data, seeds = v1.load(d)
        if len(seeds) != 1:
            raise SystemExit("%s: expected one seed" % d)
        s = seeds.pop()
        seen.add(s)
        for pol in REF_POLICIES:
            r = data.get((REF_RATE, pol))
            why = "MISSING" if r is None else ref_invalid(r)
            ref[(s, pol)] = (why, None if r is None else r["slo_rate"])
    if sorted(seen) != sorted(v1.SEEDS):
        raise SystemExit("reference: need seeds %s, got %s" % (v1.SEEDS, sorted(seen)))
    print("Reference, one-type fleet at %.0f req/s:" % REF_RATE)
    any_invalid = within = False
    for (s, pol), (why, att) in sorted(ref.items()):
        if why:
            any_invalid = True
            print("  %-13s seed %d  invalid: %s" % (pol, s, why))
        else:
            print("  %-13s seed %d  SLO met %5.1f%%" % (pol, s, 100 * att))
            within = within or att >= ATTAIN
    if any_invalid:
        print("\nINCONCLUSIVE: a reference run is invalid; nothing is decided.")
        return 3
    beyond = not within
    print("  -> %s" % ("BEYOND FLEET CAPACITY (excluded)" if beyond
                       else "WITHIN capacity (spreading meets the SLO)"))

    fails = 0
    for fleet, rates in v1.CELLS.items():
        for rate in rates:
            if beyond and fleet == REF_FLEET and rate == REF_RATE:
                continue
            for pol in v1.POLICIES:
                for seed in v1.SEEDS:
                    r = runs[fleet][seed].get((rate, pol))
                    why = "MISSING" if r is None else v1.invalid(r)
                    fails += not (why is None and r["slo_rate"] >= ATTAIN)
    n = sum(len(r) for r in v1.CELLS.values()) * len(v1.POLICIES) * len(v1.SEEDS)
    n -= 9 if beyond else 0
    if fails:
        print("\nVALIDATION (v2) FAILED: %d of %d combinations." % (fails, n))
        return 2
    print("\nVALIDATION (v2) PASSED: all %d combinations within fleet capacity "
          "met the SLO at h = 0." % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
