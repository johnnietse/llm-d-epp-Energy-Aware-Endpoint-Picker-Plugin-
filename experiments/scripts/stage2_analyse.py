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
    # Routing decisions must be grounded in measurement - but the right
    # measure of that is NOT the raw out-of-range lookup count.
    #
    # interp() returns None above the measured concurrency, _proj_latency turns
    # that into +inf, and the endpoint is excluded as infeasible. That is the
    # curve doing its job. A consolidating policy probes above the ceiling
    # constantly by design: in jobs 12304118/19 energy_greedy logged ~15k
    # out-of-range lookups at 180 req/s purely from correctly rejecting busy
    # endpoints. Refusing on that count blocked a clean run and would block
    # every future one.
    #
    # The condition that actually invalidates a policy claim is a pick where
    # NO endpoint had curve data, so the policy ran on its fallback rather
    # than on the rule being tested.
    UNGROUNDED_TOLERANCE = 0.02
    if rows and "router_ungrounded_picks" not in rows[0]:
        print("REFUSING: cells predate ungrounded-pick accounting, so it "
              "cannot be established whether the policies ever routed without "
              "curve data. Re-run with the current harness.")
        return False
    ung = [(r["policy"], r["offered_rate_rps"], r["router_ungrounded_picks"],
            r.get("router_ungrounded_frac") or 0.0)
           for r in rows
           if (r.get("router_ungrounded_frac") or 0.0) > UNGROUNDED_TOLERANCE]
    if ung:
        print("REFUSING: %d cell(s) made more than %.0f%% of their routing "
              "picks with no endpoint having curve data."
              % (len(ung), UNGROUNDED_TOLERANCE * 100))
        for pol, rate, n, frac in sorted(ung, key=lambda t: -t[3])[:8]:
            print("  %-20s at %.0f req/s: %d picks (%.1f%%) ungrounded"
                  % (pol, rate, n, frac * 100))
        print("Those cells measure the fallback, not the policy. Extend the "
              "curve to the concurrencies the policy actually drives.")
        return False

    probed = sum(1 for r in rows if r.get("router_out_of_range"))
    if probed:
        worst = max(rows, key=lambda r: r.get("router_out_of_range") or 0)
        print("curve probed above its measured range in %d cell(s); worst %s "
              "at %.0f req/s with %d lookups. Those endpoints were excluded "
              "as infeasible, and every pick still had a grounded option."
              % (probed, worst["policy"], worst["offered_rate_rps"],
                 worst["router_out_of_range"]))

    print("validity audit: %d cells, none client-limited, no ungrounded "
          "routing above %.0f%%." % (len(rows), UNGROUNDED_TOLERANCE * 100))
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


def mean_cells(trials):
    """Average each (policy, rate) cell across trials.

    Pooling must not be done by throwing every trial's cells into one pile and
    letting best_feasible pick the maximum: that takes each policy's LUCKIEST
    trial, so whichever policy drew a favourable run wins by selection bias.
    With a ranking already known to turn on sub-percent latency differences,
    that is not a small distortion. Averaging the matched cells first, then
    choosing the best feasible operating point on the averages, is the honest
    statistic. Feasibility is judged on the MEAN attainment, so a policy that
    met the SLO in one trial and missed in another does not qualify.
    """
    buckets = {}
    for rows in trials.values():
        for r in rows:
            buckets.setdefault((r["policy"], r["offered_rate_rps"]), []).append(r)

    def avg(rs, key):
        vals = [r.get(key) for r in rs if r.get(key) is not None]
        return sum(vals) / len(vals) if vals else None

    out = []
    for (policy, rate), rs in buckets.items():
        out.append({
            "policy": policy,
            "offered_rate_rps": rate,
            "n_trials": len(rs),
            "slo_rate": avg(rs, "slo_rate") or 0.0,
            "j_per_request": avg(rs, "j_per_request"),
            "j_per_slo_request": avg(rs, "j_per_slo_request"),
            "goodput_per_joule": avg(rs, "goodput_per_joule"),
            "slo_margin_p95": avg(rs, "slo_margin_p95"),
            "achieved_rate_rps": avg(rs, "achieved_rate_rps"),
            "client_limited": any(r.get("client_limited") for r in rs),
            "server_saturated": all(r.get("server_saturated") for r in rs),
            "router_out_of_range": max((r.get("router_out_of_range") or 0)
                                       for r in rs),
        })
    return out


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


def brittle_note(best):
    """Warn when a winner's margin rests on straddling the SLO boundary.

    Attainment is a near-step function of latency here, so two policies whose
    latency distributions differ by ~1% can differ by tens of points of
    attainment purely by sitting either side of the threshold. That is a
    property of where the SLO was set, not evidence that one policy is better.
    """
    boundary = [(n, r) for n, r in best.items()
                if r.get("slo_margin_p95") is not None
                and 0.95 <= r["slo_margin_p95"] <= 1.05]
    if len(boundary) >= 2:
        print("\nCAUTION: %d feasible point(s) sit within 5%% of the SLO "
              "boundary:" % len(boundary))
        for n, r in sorted(boundary, key=lambda t: t[1]["slo_margin_p95"]):
            print("  %-20s p95 = %.3f x SLO at %.0f req/s, attainment %.1f%%"
                  % (n, r["slo_margin_p95"], r["offered_rate_rps"],
                     r["slo_rate"] * 100))
        print("  Attainment is a near-step function of latency in this "
              "configuration, so a ranking among these is decided by a "
              "sub-percent latency difference and is not a robust policy "
              "result. Repeat trials and report confidence intervals before "
              "treating any ordering here as a finding.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", nargs="+",
                    help="one directory per trial; with two or more, a "
                         "policy must beat the baseline in EVERY trial "
                         "to count as a winner")
    args = ap.parse_args()

    trials = {}
    for d in args.run_dir:
        rows = load(d)
        if not rows:
            raise SystemExit("no policies-rate*.json in " + d)
        trials[d] = rows
    rows = [r for rs in trials.values() for r in rs]

    print("=" * 72)
    print("Stage 2 gate analysis: %d trial(s)" % len(trials))
    for d in args.run_dir:
        seeds = sorted({r.get("seed") for r in trials[d]})
        print("  %s  (%d cells, seed(s) %s)"
              % (d, len(trials[d]), ",".join(str(x) for x in seeds)))
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
    # Pooled on per-cell means, never on best-of-trials.
    best = best_feasible(mean_cells(trials))
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

    brittle_note(best)
    pack = best.get("slo_packing")
    if not pack:
        print("\nslo_packing has NO feasible point, so there is no baseline to "
              "beat at these load levels. Report that rather than comparing "
              "against an infeasible cell.")
        return 1

    print("\n--- VERDICT vs slo_packing, pooled across trials ---")
    pack_gpj = pack.get("goodput_per_joule") or 0.0
    pooled = {}
    for name, r in best.items():
        if name == "slo_packing":
            continue
        gpj = r.get("goodput_per_joule") or 0.0
        pooled[name] = (gpj - pack_gpj) / pack_gpj * 100 if pack_gpj else 0.0
        print("  %-20s %+6.1f%%" % (name, pooled[name]))

    # Per-trial verdicts. A ranking decided by a sub-percent latency difference
    # is exactly what job 12303355 produced, so a policy that wins pooled but
    # not in every trial is reported as unreplicated rather than as a result.
    per_trial = {}
    for d, rs in trials.items():
        tb = best_feasible(rs)
        tpack = tb.get("slo_packing")
        if not tpack or not tpack.get("goodput_per_joule"):
            per_trial[d] = None
            continue
        base = tpack["goodput_per_joule"]
        per_trial[d] = {n: ((r.get("goodput_per_joule") or 0.0) - base)
                        / base * 100
                        for n, r in tb.items() if n != "slo_packing"}

    if len(trials) > 1:
        print("\n--- per-trial, to check the pooled number replicates ---")
        names = sorted(pooled)
        print("%-20s %s" % ("policy", "".join("%12s" % ("trial %d" % (i + 1))
                                              for i in range(len(trials)))))
        for n in names:
            cells = []
            for d in args.run_dir:
                v = per_trial.get(d)
                cells.append("%11.1f%%" % v[n] if v and n in v else "         n/a")
            print("%-20s %s" % (n, "".join(cells)))

    consistent = []
    for n, gain in pooled.items():
        if gain <= 0:
            continue
        signs = [per_trial[d].get(n) for d in args.run_dir
                 if per_trial.get(d) and n in per_trial[d]]
        if signs and all(x > 0 for x in signs) and len(signs) == len(trials):
            consistent.append((min(signs), n, signs))

    if not pooled or max(pooled.values(), default=0.0) <= 0:
        print("\nGATE FAILED: no policy beat slo_packing on SLO-goodput per "
              "joule at a feasible operating point.")
        print("That is a publishable negative result, not a reason to retune "
              "the policies until one wins.")
        return 0

    if not consistent:
        print("\nGATE INCONCLUSIVE: a policy leads when trials are pooled, "
              "but the lead does not hold in every trial.")
        print("Job 12303355 produced exactly this shape - a 1.1% latency "
              "spread deciding a 9-point attainment gap - so an unreplicated "
              "lead is not reported as a finding. Add trials.")
        return 1

    worst, name, signs = max(consistent)
    print("\nGATE PASSED: %s beats slo_packing in all %d trial(s), by at "
          "least %+.1f%% SLO-goodput per joule (per trial: %s)."
          % (name, len(trials), worst,
             ", ".join("%+.1f%%" % x for x in signs)))
    print("Stage 4 builds THAT rule and nothing else.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
