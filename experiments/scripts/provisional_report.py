#!/usr/bin/env python3
"""Provisional per-cell view of a Stage 2 run, with every caveat stated.

Separate from stage2_analyse.py on purpose. That script is the gate and it
refuses runs it cannot certify; this one prints what a run contains so the
cells that ARE sound can be read while the rest are re-measured. It never
declares a winner.

Why it is needed for jobs 12304118/12304119: round_robin and least_loaded
never consult the energy curve, and slo_packing's no-data fallback was already
load balancing, so their cells stand. energy_greedy and energy_consolidate had
a fallback that degraded to endpoint index order when no endpoint had curve
data, so their cells at the highest load levels need re-measuring.
"""
from __future__ import annotations

import argparse
import glob
import json
import os

CURVE_USERS = {"slo_packing", "energy_greedy", "energy_consolidate"}
SOUND_FALLBACK = {"slo_packing"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", nargs="+")
    args = ap.parse_args()

    rows = []
    for d in args.run_dir:
        for path in sorted(glob.glob(os.path.join(d, "policies-rate*.json"))):
            doc = json.load(open(path))
            for rec in doc["results"]:
                rec["_trial"] = os.path.basename(d)
                rows.append(rec)

    by = {}
    for r in rows:
        by.setdefault(r["offered_rate_rps"], {}).setdefault(
            r["policy"], []).append(r)

    order = ("round_robin", "least_loaded", "slo_packing", "energy_greedy",
             "energy_consolidate")

    def avg(rs, key):
        v = [r.get(key) for r in rs if r.get(key) is not None]
        return sum(v) / len(v) if v else None

    print("Provisional view. Means across %d trial(s). No verdict is drawn."
          % len({r["_trial"] for r in rows}))
    for rate in sorted(by):
        print("\n### offered %.0f req/s" % rate)
        print("%-20s %7s %7s %9s %8s %8s %9s  %s" % (
            "policy", "J/req", "SLO%", "gp/J", "margp95", "achieved",
            "oor", "status"))
        for name in order:
            rs = by[rate].get(name)
            if not rs:
                continue
            oor = avg(rs, "router_out_of_range") or 0
            if name not in CURVE_USERS:
                status = "sound (curve unused)"
            elif oor == 0:
                status = "sound (curve in range)"
            elif name in SOUND_FALLBACK:
                status = "sound (fallback was load balancing)"
            else:
                status = "RE-MEASURE (fallback was index order)"
            print("%-20s %7.2f %7.1f %9.4f %8.3f %8.1f %9.0f  %s" % (
                name, avg(rs, "j_per_request") or 0.0,
                (avg(rs, "slo_rate") or 0.0) * 100,
                avg(rs, "goodput_per_joule") or 0.0,
                avg(rs, "slo_margin_p95") or 0.0,
                avg(rs, "achieved_rate_rps") or 0.0, oor, status))

    print("\nIntegrity across all cells:")
    print("  client-limited cells: %d"
          % sum(1 for r in rows if r.get("client_limited")))
    worst = max(rows, key=lambda r: r.get("send_delay_p99") or 0.0)
    print("  worst dispatch delay p99: %.4f s (%s at %.0f req/s)"
          % (worst.get("send_delay_p99") or 0.0, worst["policy"],
             worst["offered_rate_rps"]))
    gen = max(rows, key=lambda r: r.get("generator_cpu_cores_mean") or 0.0)
    print("  peak generator CPU: %.2f cores - that share of any CPU/DRAM "
          "figure is the client, not the workload"
          % (gen.get("generator_cpu_cores_mean") or 0.0))


if __name__ == "__main__":
    main()
