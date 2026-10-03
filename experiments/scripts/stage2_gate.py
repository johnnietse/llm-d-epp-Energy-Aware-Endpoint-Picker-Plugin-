#!/usr/bin/env python3
"""Stage 2 offline gate: is a comparative result worth building for?

WHAT THIS IS, AND IS NOT
------------------------
The single modelled artifact FINAL-PLAN-2026-10.md permits. Its output is a
go/no-go decision, never a reported result. No physics is modelled: throughput
and power come from the MEASURED curves in experiments/h1-*/h1.csv (trials 2+,
warm-up excluded). Only the arrival process and the queueing are modelled, so
policies can be compared over identical offered load without spending weeks of
cluster time.

THE QUESTION
------------
How much room is there between SLO-aware packing and the best any placement
could possibly do? If packing is already close to a bound nothing can beat,
an online scorer cannot help and the comparative paper has no result.

THREE DEFECTS IN THE FIRST VERSION, FIXED HERE
----------------------------------------------
The first version printed PASS and the verdict was worthless:

1. Its "oracle" policy selected the same endpoint as energy_greedy at every
   load, so the columns were identical and no bound existed. Replaced with
   energy_lower_bound(), which ignores queueing and asks what the work could
   cost at best given measured J/token and measured peak throughput.
2. Its apparent wins came from SLO collapse: at the highest load the "winner"
   had 41% SLO attainment against packing's 22%, with p95 five times the
   target. Comparing joules-per-SLO-request at different attainment compares
   different operating points. The verdict now only considers loads where
   packing actually meets its SLO.
3. One seed, 600 requests, gaps bouncing from -4% to +36%. Now multiple seeds
   with 95% intervals.

WHY SATURATION MATTERS (FINAL-PLAN 3.1b)
----------------------------------------
The A30 Pareto-dominates the Quadro RTX 6000 here: 2.32x less energy per token
AND 1.81x the throughput. Below saturation every policy simply fills A30s and
they tie. The report marks saturated loads and warns when the verdict rests
only on unsaturated ones.

Usage:
  python stage2_gate.py \
      --curves ../h1-2026-10-03-frnt140-a30/h1.csv=a30 \
               ../h1-2026-10-03-frnt109/h1.csv=rtx6000 \
      --fleet a30=2 rtx6000=4 --requests 800 --trials 5
"""
from __future__ import annotations

import argparse
import csv
import math
import random
import statistics as st
from collections import defaultdict
from dataclasses import dataclass, field

OUTPUT_TOKENS = 128  # matches the measured sweeps

T_CRIT = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571,
          6: 2.447, 7: 2.365, 8: 2.306, 9: 2.262}


def ci95(xs):
    xs = [x for x in xs if math.isfinite(x)]
    if not xs:
        return math.nan, math.nan
    if len(xs) == 1:
        return xs[0], 0.0
    m = st.mean(xs)
    return m, T_CRIT.get(len(xs) - 1, 1.96) * st.stdev(xs) / math.sqrt(len(xs))


# ---------------------------------------------------------------- measured data

@dataclass
class Curve:
    name: str
    tok_s: dict
    power_w: dict
    idle_resident_w: float
    levels: list = field(default_factory=list)

    def __post_init__(self):
        self.levels = sorted(self.tok_s)

    def _bracket(self, c):
        if c <= self.levels[0]:
            return self.levels[0], self.levels[0], 0.0
        if c >= self.levels[-1]:
            return self.levels[-1], self.levels[-1], 0.0
        for lo, hi in zip(self.levels, self.levels[1:]):
            if lo <= c <= hi:
                return lo, hi, (c - lo) / (hi - lo)
        raise AssertionError

    def throughput(self, c):
        if c <= 0:
            return 0.0
        lo, hi, f = self._bracket(c)
        return self.tok_s[lo] + f * (self.tok_s[hi] - self.tok_s[lo])

    def power(self, c):
        if c <= 0:
            return self.idle_resident_w
        lo, hi, f = self._bracket(c)
        return self.power_w[lo] + f * (self.power_w[hi] - self.power_w[lo])

    def per_request_rate(self, c):
        return self.throughput(c) / c if c > 0 else 0.0

    def max_throughput(self):
        return self.tok_s[self.levels[-1]]

    def most_efficient_level(self):
        return min(self.levels, key=lambda c: self.power(c) / self.throughput(c))

    def best_j_per_token(self):
        c = self.most_efficient_level()
        return self.power(c) / self.throughput(c)


def load_curve(path, name):
    pw, tk, idle = defaultdict(list), defaultdict(list), []
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            note = r["note"]
            if note == "idle_model_loaded":
                idle.append(float(r["mean_power_w"]))
                continue
            if note != "unique_prompts":
                continue
            if int(float(r["trial"])) == 1:       # warm-up transient
                continue
            c = int(float(r["concurrency"]))
            pw[c].append(float(r["mean_power_w"]))
            tk[c].append(float(r["gen_tok_per_s"]))
    if not pw:
        raise SystemExit(path + ": no usable rows")
    return Curve(
        name=name,
        tok_s={c: st.mean(v) for c, v in tk.items()},
        power_w={c: st.mean(v) for c, v in pw.items()},
        idle_resident_w=st.mean(idle) if idle else min(st.mean(v) for v in pw.values()),
    )


# ------------------------------------------------------------------- simulation

@dataclass
class Endpoint:
    eid: int
    curve: Curve
    inflight: list = field(default_factory=list)
    ids: list = field(default_factory=list)
    energy_j: float = 0.0
    activations: int = 0
    was_idle: bool = True

    @property
    def c(self):
        return len(self.inflight)

    def projected_latency(self, extra=1):
        rate = self.curve.per_request_rate(self.c + extra)
        return OUTPUT_TOKENS / rate if rate > 0 else math.inf


def simulate(endpoints, arrivals, policy, slo_s, dt=0.01):
    for e in endpoints:
        e.inflight.clear()
        e.ids.clear()
        e.energy_j = 0.0
        e.activations = 0
        e.was_idle = True

    pending = list(reversed(arrivals))
    t = 0.0
    latencies = []
    met = done = next_id = 0
    horizon = arrivals[-1] + 900.0

    while t < horizon and (pending or any(e.inflight for e in endpoints)):
        while pending and pending[-1] <= t:
            pending.pop()
            target = policy(endpoints, slo_s)
            target.inflight.append(float(OUTPUT_TOKENS))
            target.ids.append((next_id, t))
            next_id += 1
            if target.was_idle:
                target.activations += 1
                target.was_idle = False

        for e in endpoints:
            c = e.c
            e.energy_j += e.curve.power(c) * dt
            if c == 0:
                e.was_idle = True
                continue
            per = e.curve.per_request_rate(c) * dt
            finished = []
            for i in range(c):
                e.inflight[i] -= per
                if e.inflight[i] <= 0:
                    finished.append(i)
            for i in reversed(finished):
                e.inflight.pop(i)
                _, started = e.ids.pop(i)
                lat = t + dt - started
                latencies.append(lat)
                done += 1
                if lat <= slo_s:
                    met += 1
        t += dt

    total = sum(e.energy_j for e in endpoints)
    return {
        "energy_j": total,
        "completed": done,
        "slo_rate": met / done if done else 0.0,
        "j_per_request": total / done if done else math.inf,
        "p95_latency": (sorted(latencies)[int(0.95 * len(latencies))]
                        if latencies else math.inf),
        "activations": sum(e.activations for e in endpoints),
    }


# --------------------------------------------------------------------- policies

_RR = {"i": 0}


def p_round_robin(endpoints, slo_s):
    e = endpoints[_RR["i"] % len(endpoints)]
    _RR["i"] += 1
    return e


def p_slo_packing(endpoints, slo_s):
    """Fill the most loaded endpoint that still meets the SLO. The baseline."""
    feasible = [e for e in endpoints if e.projected_latency() <= slo_s]
    if feasible:
        return max(feasible, key=lambda e: e.c)
    return min(endpoints, key=lambda e: e.c)


def p_energy_greedy(endpoints, slo_s):
    """Ours in spirit: among SLO-feasible endpoints prefer the lowest resulting
    J/token, with an explicit penalty for waking an idle endpoint. Deliberately
    not the same rule as the bound below."""
    feasible = [e for e in endpoints if e.projected_latency() <= slo_s] or list(endpoints)

    def cost(e):
        c1 = e.c + 1
        thr = e.curve.throughput(c1)
        if thr <= 0:
            return math.inf
        j_per_tok = e.curve.power(c1) / thr
        penalty = 0.0
        if e.c == 0:
            dur = OUTPUT_TOKENS / e.curve.per_request_rate(1)
            penalty = (e.curve.power(1) - e.curve.idle_resident_w) * dur / OUTPUT_TOKENS
        return j_per_tok + penalty

    return min(feasible, key=cost)


POLICIES = {
    "round_robin": p_round_robin,
    "slo_packing": p_slo_packing,
    "energy_greedy": p_energy_greedy,
}


def energy_lower_bound(fleet, n_requests, window_s):
    """Genuine lower bound on energy to serve n_requests. NOT a policy.

    Ignores queueing entirely: allocate required tokens to endpoints
    cheapest-first by measured J/token, capped by measured peak throughput over
    the window, plus the idle-resident floor for the whole fleet because an
    endpoint holding a model draws power regardless. No placement policy can
    beat this, since none can exceed measured throughput or undercut measured
    J/token.
    """
    tokens = n_requests * OUTPUT_TOKENS
    energy = sum(e.curve.idle_resident_w * window_s for e in fleet)
    opts = []
    for e in fleet:
        c = e.curve.most_efficient_level()
        opts.append((e.curve.power(c) / e.curve.throughput(c),
                     e.curve.throughput(c) * window_s,
                     e.curve.power(c) - e.curve.idle_resident_w,
                     e.curve.throughput(c)))
    opts.sort(key=lambda o: o[0])

    remaining = tokens
    for _j, capacity, active_extra, thr in opts:
        if remaining <= 0:
            break
        take = min(remaining, capacity)
        energy += active_extra * (take / thr)
        remaining -= take
    return math.inf if remaining > 0 else energy


# ------------------------------------------------------------------------- main

def poisson_arrivals(rate, n, rng):
    t, out = 0.0, []
    for _ in range(n):
        t += rng.expovariate(rate)
        out.append(t)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--curves", nargs="+", required=True)
    ap.add_argument("--fleet", nargs="+", required=True)
    ap.add_argument("--requests", type=int, default=800)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--trials", type=int, default=5)
    ap.add_argument("--slo-multiple", type=float, default=2.0)
    args = ap.parse_args()

    curves = {}
    for spec in args.curves:
        path, _, name = spec.rpartition("=")
        curves[name] = load_curve(path, name)

    fleet, eid = [], 0
    for spec in args.fleet:
        name, _, count = spec.partition("=")
        for _ in range(int(count)):
            fleet.append(Endpoint(eid=eid, curve=curves[name]))
            eid += 1

    print("=== measured curves (trials 2+, warm-up excluded) ===")
    for n, c in curves.items():
        print("  %s: idle-resident %.2f W, peak %.0f tok/s, best %.4f J/token at c=%d"
              % (n, c.idle_resident_w, c.max_throughput(), c.best_j_per_token(),
                 c.most_efficient_level()))
    ranked = sorted(curves.values(), key=lambda c: c.best_j_per_token())
    if len(ranked) > 1:
        print("  dominant: %s (%.2fx better J/token than %s)"
              % (ranked[0].name,
                 ranked[-1].best_j_per_token() / ranked[0].best_j_per_token(),
                 ranked[-1].name))

    counts = {n: sum(1 for e in fleet if e.curve.name == n) for n in curves}
    best_lat = min(OUTPUT_TOKENS / c.per_request_rate(1) for c in curves.values())
    slo = best_lat * args.slo_multiple
    peak_rps = sum(e.curve.max_throughput() for e in fleet) / OUTPUT_TOKENS
    dom_rps = sum(e.curve.max_throughput() for e in fleet
                  if e.curve.name == ranked[0].name) / OUTPUT_TOKENS

    print("\n=== fleet %s; SLO %.3fs (%.1fx best single-request %.3fs) ==="
          % (counts, slo, args.slo_multiple, best_lat))
    print("fleet peak ~%.1f req/s, dominant-type-only ~%.1f req/s"
          % (peak_rps, dom_rps))
    print("%d seeds per cell, %d requests each, mean +/- 95%% CI\n"
          % (args.trials, args.requests))

    loads = [0.25, 0.5, 0.75, 0.9, 1.0, 1.15, 1.3]
    seeds = list(range(args.seed, args.seed + args.trials))

    print("%8s %10s | %s" % ("req/s", "regime",
          " | ".join("%24s" % p for p in POLICIES)))
    print("%8s %10s | %s" % ("", "",
          " | ".join("%24s" % "J/req           SLO%" for _ in POLICIES)))
    print("-" * 100)

    agg = {}
    for frac in loads:
        rate = peak_rps * frac
        cells = []
        for pname, fn in POLICIES.items():
            jpr, slos = [], []
            for sd in seeds:
                _RR["i"] = 0
                rng = random.Random(sd)
                r = simulate(fleet, poisson_arrivals(rate, args.requests, rng),
                             fn, slo)
                jpr.append(r["j_per_request"])
                slos.append(r["slo_rate"])
            jm, jh = ci95(jpr)
            sm, _ = ci95(slos)
            agg[(frac, pname)] = {"j": jm, "ci": jh, "slo": sm}
            cells.append("%8.2f +/-%-5.2f %6.1f" % (jm, jh, sm * 100))
        regime = "saturated" if rate >= dom_rps else "below"
        print("%8.1f %10s | %s" % (rate, regime, " | ".join(cells)))

    print("\n=== lower bound (not a policy; ignores queueing) ===")
    print("%8s %12s %14s %10s %10s"
          % ("req/s", "bound J/req", "packing J/req", "headroom", "pack SLO%"))
    rows = []
    for frac in loads:
        rate = peak_rps * frac
        window = args.requests / rate
        lb = energy_lower_bound(fleet, args.requests, window)
        lbr = lb / args.requests if math.isfinite(lb) else math.inf
        pack = agg[(frac, "slo_packing")]
        head = ((pack["j"] - lbr) / pack["j"] * 100) if math.isfinite(lbr) else math.nan
        rows.append((rate, lbr, pack, head))
        print("%8.1f %12.2f %14.2f %9.1f%% %9.1f"
              % (rate, lbr, pack["j"], head, pack["slo"] * 100))

    print("\n=== GATE VERDICT ===")
    print("Criterion: at a load where service is actually met (packing SLO")
    print("attainment >= 95%), there must be >= 5% headroom between SLO-aware")
    print("packing and the lower bound. Loads where packing already misses its")
    print("SLO are excluded: 'winning' there means degrading service.\n")

    usable = [r for r in rows if r[2]["slo"] >= 0.95 and math.isfinite(r[3])]
    if not usable:
        print("  NO LOAD where packing meets its SLO. The question cannot be")
        print("  asked on this fleet and SLO. Widen the load range or relax")
        print("  --slo-multiple and re-run; do not trust any verdict yet.")
        return

    for rate, lbr, pack, head in usable:
        tag = "saturated" if rate >= dom_rps else "below saturation"
        print("  %7.1f req/s (%s): headroom %5.1f%%  (packing %.2f vs bound %.2f "
              "J/req, SLO %.1f%%)"
              % (rate, tag, head, pack["j"], lbr, pack["slo"] * 100))

    sat = [u for u in usable if u[0] >= dom_rps]
    pool = sat or usable
    best = max(h for _, _, _, h in pool)
    print("\n  best headroom at a served load: %.1f%%" % best)
    if not sat:
        print("  WARNING: no saturated load also meets the SLO, so this rests on")
        print("  the regime where every policy trivially prefers the dominant GPU")
        print("  type (FINAL-PLAN 3.1b). Treat as WEAK; re-run with a bigger")
        print("  fleet or a longer window before acting on it.")
    if best >= 5.0:
        print("  VERDICT: PASS (conditional). Headroom exists against a bound no")
        print("  policy can beat, at a load where the SLO is met. The bound")
        print("  ignores queueing, so the achievable share is smaller than this.")
    else:
        print("  VERDICT: FAIL. Packing is already within 5% of an unbeatable")
        print("  bound. STOP and write the measurement/negative-result paper.")
    print("\nThis verdict is a planning decision, not a finding, and must never")
    print("appear in the paper as a result.")


if __name__ == "__main__":
    main()
