#!/usr/bin/env python3
"""Print --curves arguments for the newest open-loop curve of each GPU type.

    python3 select_openloop_curves.py <root> <model>   # used when CURVE_SOURCE=openloop

Looks in <root>/results/olc-<job>/ for curve.csv plus instruments.txt naming
the same model. Per GPU type, it takes the newest job that has at least three
stationary rates: the same test policy_harness.load_openloop_curve applies,
so a curve the router would refuse is never selected. It exits nonzero if it
finds no curve at all, so a job cannot silently fall back to closed-loop
curves.
"""
import csv
import glob
import os
import re
import sys
from collections import defaultdict

TYPES = (r"NVIDIA A100[^,\s]*|NVIDIA L40S|Quadro RTX 8000|Quadro RTX 6000"
         r"|Tesla V100[^,\s]*|NVIDIA A30|NVIDIA L4(?![0-9])")
MIN_FIDELITY = 0.95


def keepup(row):
    # Same test as policy_harness.keepup: realised-rate keep-up when present.
    k = row.get("keepup")
    return float(k) if k not in (None, "", "None") else float(row["rate_fidelity"])


def stationary_rates(path):
    rows = defaultdict(list)
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            if int(float(r["trial"])) != 1:
                rows[float(r["rate"])].append(r)
    n = 0
    for rate in sorted(rows):
        if any(keepup(x) < MIN_FIDELITY
               or x["client_limited"] in ("True", "1") for x in rows[rate]):
            break
        n += 1
    return n


def main():
    root, model = sys.argv[1], sys.argv[2]
    best = {}
    for path in glob.glob(os.path.join(root, "results", "olc-*", "curve.csv")):
        d = os.path.dirname(path)
        try:
            text = open(os.path.join(d, "instruments.txt")).read()
        except OSError:
            continue
        if "model=" + model not in text:
            continue
        g = re.search(TYPES, text)
        j = re.search(r"olc-(\d+)", d)
        if not g or not j:
            continue
        n = stationary_rates(path)
        if n < 3:
            print("  skipping %s: %d stationary rates" % (path, n), file=sys.stderr)
            continue
        name = g.group(0).replace(" ", "_")
        if name not in best or int(j.group(1)) > best[name][0]:
            best[name] = (int(j.group(1)), path, n)
    if not best:
        raise SystemExit("no usable open-loop curve under %s/results/olc-*" % root)
    for name in sorted(best):
        print("  open-loop curve for %s: %s (%d stationary rates)"
              % (name, best[name][1], best[name][2]), file=sys.stderr)
    print("--curves " + " ".join("%s=%s" % (best[n][1], n) for n in sorted(best)))


if __name__ == "__main__":
    main()
