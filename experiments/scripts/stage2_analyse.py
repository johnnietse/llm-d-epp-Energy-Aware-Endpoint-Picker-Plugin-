#!/usr/bin/env python3
"""Stage 2 gate analysis.

Answers one question: at a load level where the SLO is actually met, does any
routing policy deliver more SLO-satisfied work per joule than `slo_packing`?

Why this is not simply "compare J/req at matched SLO attainment", which is what
the discarded job 12303327 appeared to answer:

  * Attainment is a near-step function here. With a fixed 128-token output,
    service time is about TTFT + 128*TPOT, so an end-to-end SLO is effectively
    a TPOT threshold and the whole latency distribution crosses it together.
    Job 12303354 measured 97.1% attainment at 271 req/s and 7.6% at 350 while
    e2e p99 moved only 2.012 -> 2.225 s. Two policies can therefore show
    "matched" attainment of 5% and be in completely different states, or differ
    by 90 points on an 8% TPOT difference.

  * Energy per request falls monotonically with offered load, because fixed
    idle power amortises over more requests. So J/req alone always rewards
    whichever policy pushed more load through, regardless of whether the result
    was usable.

The comparison used instead: each policy picks its own best operating point
among the load levels where it meets the SLO, and the policies are compared on
SLO-goodput per joule there. That is how the system would actually be run, and
it is robust to the cliff because a policy on the wrong side of it simply has
no feasible point.

Reads the policies-rate*.json written by stage2_real.sbatch.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import sys

# A policy "meets the SLO" at a load level if attainment is at least this.
# Declared here rather than chosen after seeing the numbers.
FEASIBLE_SLO = 0.95


def load(run_dir):
    rows = []
    for path in sorted(glob.glob(os.path.join(run_dir, "policies-rate*.json"))):
        with open(path) as fh:
            doc = json.load(fh)
        for rec in doc["results"]:
            rec["_file"] = os.path.basename(path)
            rows.append(rec)
    return rows


def validity_audit(rows):
    """Refuse to analyse a run containing a cell the harness itself distrusts."""
    bad = [(r["policy"], r["offered_rate_rps"]) for r in rows
           if r.get("client_limited")]
    missing = [k for k in ("achieved_rate_rps", "client_limited",
                           "slo_margin_p95", "generator_workers")
               if rows and k not in rows[0]]
    if missing:
        print("REFUSING: these cells predate the generator instrumentation and "
              "cannot be checked for client limitation: missing " +
              ", ".join(missing))
        print("Any run without achieved_rate_rps is unusable regardless of how "
              "clean its numbers look. That is the lesson of job 12303327.")
        return False
    if bad:
        print("REFUSING: %d client-limited cell(s); the generator fell behind "
              "its own schedule, so the offered rate is fiction." % len(bad))
        for pol, rate in bad:
            print("  %-20s at %.0f req/s" % (pol, rate))
        return False
    print("validity audit: %d cells, none client-limited." % len(rows))
    worst = max(rows, key=lambda r: r.get("send_delay_p99") or 0.0)
    print("  worst dispatch delay p99: %.4f s (%s at %.0f req/s)"
          % (worst.get("send_delay_p99") or 0.0, worst["policy"],
             worst["offered_rate_rps"]))
    fid = min(rows, key=lambda r: r.get("rate_fidelity") or 0.0)
    print("  lowest rate fidelity:     %.1f%% (%s at %.0f req/s)"
          % ((fid.get("rate_fidelity") or 0.0) * 100, fid["policy"],
             fid["offered_rate_rps"]))
    gen = max(rows, key=lambda r: r.get("generator_cpu_cores_mean") or 0.0)
    print("  peak generator CPU:       %.2f cores (%s at %.0f req/s) - this "
          "fraction of any CPU/DRAM figure is the client, not the workload"
          % (gen.get("generator_cpu_cores_mean") or 0.0, gen["policy"],
             gen["offered_rate_rps"]))
    return True


def per_rate_tables(rows):
    by_rate = {}
    for r in rows:
        by_rate.setdefault(r["offered_rate_rps"], {})[r["policy"]] = r
    order = ("round_robin", "least_loaded", "slo_packing", "energy_greedy",
             "energy_consolidate")
    for rate in sorted(by_rate):
        cells = by_rate[rate]
        base = cells.get("slo_packing")
        print("\n### offered %.0f req/s" % rate)
        print("%-20s %7s %8s %7s %9s %8s %8s %8s" % (
            "policy", "J/req", "vs pack", "SLO%", "gp/J", "J/SLOreq",
            "margp95", "achieved"))
        for name in order:
            r = cells.get(name)
            if not r:
                continue
            j = r.get("j_per_request") or 0.0
            delta = ""
            if base and base.get("j_per_request"):
                delta = "%+.1f%%" % ((j - base["j_per_request"])
                                     / base["j_per_request"] * 100)
            print("%-20s %7.2f %8s %7.1f %9.4f %8.2f %8.3f %8.1f" % (
                name, j, delta, r["slo_rate"] * 100,
                r.get("goodput_per_joule") or 0.0,
                r.get("j_per_slo_request") or float("nan"),
                r.get("slo_margin_p95") or 0.0,
                r.get("achieved_rate_rps") or 0.0))
    return by_rate


def best_feasible(rows):
    """Each policy's best operating point among load levels where it meets the
    SLO, scored on SLO-goodput per joule."""
    best = {}
    for r in rows:
        if r["slo_rate"] < FEASIBLE_SLO:
            continue
        gpj = r.get("goodput_per_joule") or 0.0
        cur = best.get(r["policy"])
        if cur is None or gpj > (cur.get("goodput_per_joule") or 0.0):
            best[r["policy"]] = r
    return best


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir")
    args = ap.parse_args()

    rows = load(args.run_dir)
    if not rows:
        raise SystemExit("no policies-rate*.json in " + args.run_dir)

    print("=" * 72)
    print("Stage 2 gate analysis:", args.run_dir)
    print("=" * 72)
    if not validity_audit(rows):
        return 2

    print("\nGenerator: %s worker process(es), pool %s per worker."
          % (rows[0].get("generator_workers"),
             rows[0].get("generator_pool_per_worker")))

    per_rate_tables(rows)

    print("\n" + "=" * 72)
    print("BEST FEASIBLE OPERATING POINT PER POLICY (SLO attainment >= %.0f%%)"
          % (FEASIBLE_SLO * 100))
    print("=" * 72)
    best = best_feasible(rows)
    if not best:
        print("NO policy met the SLO at any swept load level.")
        print("The sweep is on the wrong side of the knee: lower the load "
              "levels, do not relax FEASIBLE_SLO after the fact.")
        return 1

    print("%-20s %8s %9s %8s %7s %8s" % (
        "policy", "at req/s", "gp/J", "J/SLOreq", "SLO%", "margp95"))
    for name, r in sorted(best.items(),
                          key=lambda kv: -(kv[1].get("goodput_per_joule") or 0)):
        print("%-20s %8.0f %9.4f %8.2f %7.1f %8.3f" % (
            name, r["offered_rate_rps"], r.get("goodput_per_joule") or 0.0,
            r.get("j_per_slo_request") or float("nan"), r["slo_rate"] * 100,
            r.get("slo_margin_p95") or 0.0))

    pack = best.get("slo_packing")
    if not pack:
        print("\nslo_packing has NO feasible point, so there is no baseline to "
              "beat at these load levels. Report that rather than comparing "
              "against an infeasible cell.")
        return 1

    print("\n--- VERDICT vs slo_packing ---")
    pack_gpj = pack.get("goodput_per_joule") or 0.0
    winners = []
    for name, r in best.items():
        if name == "slo_packing":
            continue
        gpj = r.get("goodput_per_joule") or 0.0
        gain = (gpj - pack_gpj) / pack_gpj * 100 if pack_gpj else 0.0
        verdict = "beats packing" if gain > 0 else "does not beat packing"
        print("  %-20s %+6.1f%% SLO-goodput/J   %s" % (name, gain, verdict))
        if gain > 0:
            winners.append((gain, name))
    if winners:
        gain, name = max(winners)
        print("\nGATE PASSED: %s is the best measured rule, %+.1f%% "
              "SLO-goodput per joule over slo_packing." % (name, gain))
        print("Stage 4 builds THAT rule and nothing else.")
    else:
        print("\nGATE FAILED: no policy beat slo_packing on SLO-goodput per "
              "joule at a feasible operating point.")
        print("That is a publishable negative result, not a reason to retune "
              "the policies until one wins.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
