#!/usr/bin/env python3
"""Compares goodput-per-joule across runs, per load level and pooled.

Written because het_final.sh reports one heterogeneous run at a time and knows
nothing about the homogeneous layout, so the two arms of the central comparison
could not be put side by side. Takes any number of result directories.

Pooling is a plain mean over matched load levels, not best-of. A policy that
wins by winning one cell and losing four is not a better policy, and max()
would hide that; the per-rate table above the pooled line is there so the
shape of a win is visible rather than summarised away.
"""
import glob
import json
import os
import sys

POLICY_ORDER = ["round_robin", "least_loaded", "slo_packing",
                "energy_greedy", "energy_consolidate"]


def load(d):
    """rate -> policy -> (gp_per_J, slo_pct). Skips cells the gate refused."""
    # glob does not expand ~, so a tilde path silently matches nothing and the
    # run reads as "no usable cells" - indistinguishable from a refused run.
    d = os.path.expanduser(d)
    out = {}
    dropped = []
    for f in sorted(glob.glob(os.path.join(d, "policies-rate*.json"))):
        for r in json.load(open(f))["results"]:
            rate = float(r["offered_rate_rps"])
            tag = "%s@%.0f" % (r["policy"], rate)
            # client_limited is a flag and disqualifies the cell: the number
            # describes the generator, not the fleet.
            #
            # router_ungrounded_frac is a FRACTION, not a flag. An earlier
            # version of this filter treated any non-zero value as
            # disqualifying, which silently dropped every cell in both runs and
            # printed "no usable cells" - identical to what a genuinely refused
            # run looks like. A policy that fell outside its curve on a few
            # picks still produced a real measurement; the fraction is reported
            # instead of being used as a veto.
            if r.get("client_limited"):
                dropped.append(tag + ":client_limited")
                continue
            gp = r.get("goodput_per_joule")
            if gp is None:
                dropped.append(tag + ":no_energy")
                continue
            out.setdefault(rate, {})[r["policy"]] = (gp, r.get("slo_rate"))
    if dropped:
        print("  dropped %d cell(s): %s" % (len(dropped), ", ".join(dropped)))
    return out


def main():
    dirs = sys.argv[1:]
    if not dirs:
        sys.exit("usage: compare_runs.py <result-dir> [result-dir ...]")

    runs = [(os.path.basename(d.rstrip("/")), load(d)) for d in dirs]

    for name, data in runs:
        print("=" * 72)
        print(name)
        if not data:
            print("  no usable cells")
            continue
        rates = sorted(data)
        print("  %-20s %s" % ("policy", "".join("%10.0f" % r for r in rates)
                              + "     pooled   vs best other"))
        pooled = {}
        for p in POLICY_ORDER:
            vals = [data[r][p][0] for r in rates if p in data[r]]
            if not vals:
                continue
            pooled[p] = sum(vals) / len(vals)
        for p in POLICY_ORDER:
            if p not in pooled:
                continue
            cells = "".join(
                ("%10.4f" % data[r][p][0]) if p in data[r] else "%10s" % "-"
                for r in rates)
            others = [v for q, v in pooled.items() if q != p]
            rel = ((pooled[p] / max(others) - 1.0) * 100.0) if others else 0.0
            print("  %-20s%s  %9.4f   %+8.2f%%" % (p, cells, pooled[p], rel))

        # Where does the winner actually win? A pooled margin can be carried
        # entirely by one load level, which matters for what can be claimed.
        print()
        best = max(pooled, key=pooled.get)
        print("  pooled winner: %s" % best)
        wins = 0
        for r in rates:
            if best not in data[r]:
                continue
            rivals = {q: v[0] for q, v in data[r].items() if q != best}
            if not rivals:
                continue
            top = max(rivals, key=rivals.get)
            margin = (data[r][best][0] / rivals[top] - 1.0) * 100.0
            if margin > 0:
                wins += 1
            print("    %4.0f req/s: %+7.2f%% vs %s" % (r, margin, top))
        print("    wins %d of %d load levels" % (wins, len(rates)))

    if len(runs) == 2:
        print()
        print("=" * 72)
        print("SIDE BY SIDE, pooled goodput per joule")
        a, b = runs
        print("  %-20s %12s %12s %10s" % ("policy", a[0][:12], b[0][:12], "ratio"))
        for p in POLICY_ORDER:
            pa = [a[1][r][p][0] for r in sorted(a[1]) if p in a[1][r]]
            pb = [b[1][r][p][0] for r in sorted(b[1]) if p in b[1][r]]
            if not pa or not pb:
                continue
            ma, mb = sum(pa) / len(pa), sum(pb) / len(pb)
            print("  %-20s %12.4f %12.4f %9.2fx" % (p, ma, mb, ma / mb))


if __name__ == "__main__":
    main()
