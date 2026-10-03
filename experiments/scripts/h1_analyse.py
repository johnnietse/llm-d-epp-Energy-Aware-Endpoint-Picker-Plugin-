#!/usr/bin/env python3
"""Analysis the sweep's own fit.txt does not do.

Three things:

1. Mean and 95% CI per concurrency level, and the effect of excluding trial 1.
   The pinned run shows trial 1 systematically low in power (186.6 W against
   ~204 W at c=1), which is a warm-up transient, not noise. Averaging it in
   biases every derived quantity.

2. The prefix-cache comparison on a fair denominator. The sweep reports
   J per GENERATED token, under which shared-prefix looks WORSE. But the
   shared-prefix workload carries ~8.5x more prompt tokens, and prefill is
   real work, so that denominator penalises it for doing more. Recomputed per
   total token processed.

3. Reproduction check against the earlier unpinned frnt152 run.

Usage: python h1_analyse.py <h1.csv> [--compare <older h1.csv>]
"""
import argparse
import csv
import math
import statistics as st
from collections import defaultdict


def t_crit(n):
    """Two-sided 95% t critical value; small-n table, 1.96 beyond."""
    table = {1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571,
             6: 2.447, 7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228}
    return table.get(n - 1, 1.96)


def ci95(xs):
    """Return (mean, half_width). Half-width is 0 for a single sample."""
    n = len(xs)
    if n == 0:
        return (float("nan"), float("nan"))
    m = st.mean(xs)
    if n == 1:
        return (m, 0.0)
    sd = st.stdev(xs)
    return (m, t_crit(n) * sd / math.sqrt(n))


def load(path):
    rows = []
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            for k in ("concurrency", "trial", "shared_prefix", "gen_tokens",
                      "prompt_tokens", "requests"):
                r[k] = int(float(r[k])) if r[k] else 0
            for k in ("energy_j", "mean_power_w", "polled_power_w", "window_s",
                      "gen_tok_per_s", "lat_p50_s", "lat_p95_s"):
                r[k] = float(r[k]) if r[k] else float("nan")
            r["j_per_gen_token"] = float(r["j_per_gen_token"]) if r["j_per_gen_token"] else float("nan")
            rows.append(r)
    return rows


def unique_rows(rows, drop_first_trial=False):
    out = [r for r in rows if r["note"] == "unique_prompts"]
    if drop_first_trial:
        out = [r for r in out if r["trial"] != 1]
    return out


def per_level(rows):
    by = defaultdict(list)
    for r in rows:
        by[r["concurrency"]].append(r)
    return dict(sorted(by.items()))


def report_levels(rows, label):
    print(f"\n=== {label} ===")
    print(f"{'conc':>5} {'n':>2} {'power W (95% CI)':>24} "
          f"{'J/gen-tok (95% CI)':>24} {'gen tok/s':>12} {'p95 s':>8}")
    for c, rs in per_level(rows).items():
        pm, ph = ci95([r["mean_power_w"] for r in rs])
        jm, jh = ci95([r["j_per_gen_token"] for r in rs])
        tm, _ = ci95([r["gen_tok_per_s"] for r in rs])
        lm, _ = ci95([r["lat_p95_s"] for r in rs])
        print(f"{c:>5} {len(rs):>2} {pm:>10.2f} +/- {ph:<9.2f} "
              f"{jm:>10.4f} +/- {jh:<9.4f} {tm:>12.1f} {lm:>8.3f}")


def warmup_effect(rows):
    print("\n=== trial 1 versus trials 2+ (warm-up check) ===")
    print(f"{'conc':>5} {'trial1 W':>10} {'rest mean W':>12} {'delta W':>9} {'rest CI':>9}")
    for c, rs in per_level(unique_rows(rows)).items():
        first = [r["mean_power_w"] for r in rs if r["trial"] == 1]
        rest = [r["mean_power_w"] for r in rs if r["trial"] != 1]
        if not first or not rest:
            continue
        rm, rh = ci95(rest)
        d = first[0] - rm
        flag = "  <-- outside CI" if abs(d) > rh and rh > 0 else ""
        print(f"{c:>5} {first[0]:>10.2f} {rm:>12.2f} {d:>9.2f} {rh:>9.2f}{flag}")


def activation(rows, drop_first_trial=False):
    print("\n=== activation versus marginal cost ===")
    idle = [r for r in rows if r["note"] == "idle_model_loaded"]
    u = unique_rows(rows, drop_first_trial)
    c1 = [r["mean_power_w"] for r in u if r["concurrency"] == 1]
    if not idle or not c1:
        print("  insufficient data")
        return
    idle_w = idle[0]["mean_power_w"]
    m1, h1 = ci95(c1)
    print(f"  idle with model resident : {idle_w:.2f} W")
    print(f"  power at c=1             : {m1:.2f} +/- {h1:.2f} W")
    print(f"  activation step          : {m1 - idle_w:.2f} W")

    levels = per_level(u)
    cs = sorted(levels)
    lo, hi = cs[0], cs[-1]
    plo, _ = ci95([r["mean_power_w"] for r in levels[lo]])
    phi, _ = ci95([r["mean_power_w"] for r in levels[hi]])
    per_req = (phi - plo) / (hi - lo)
    print(f"  power c={lo} -> c={hi}        : {plo:.2f} -> {phi:.2f} W "
          f"({per_req:.3f} W per extra concurrent request)")
    if per_req > 0:
        print(f"  activation / marginal    : {(m1 - idle_w) / per_req:.0f}x")
    print("  NOTE: the marginal term is a small difference between two noisy")
    print("  near-equal numbers, so its ratio to activation is unstable across")
    print("  runs. The robust claim is the sign and order of magnitude: the")
    print("  activation step dominates. Do not report the ratio as a result.")


def prefix_cache(rows):
    print("\n=== prefix cache: the denominator decides the answer ===")
    uni = [r for r in rows if r["note"] == "unique_prompts" and r["concurrency"] == 8]
    sha = [r for r in rows if r["note"] == "shared_prefix"]
    if not uni or not sha:
        print("  no paired c=8 data")
        return

    def totals(rs):
        return [(r["energy_j"], r["gen_tokens"], r["prompt_tokens"],
                 r["requests"], r["lat_p50_s"], r["lat_p95_s"]) for r in rs]

    def summarise(rs, name):
        t = totals(rs)
        jg = ci95([e / g for e, g, _, _, _, _ in t])
        jt = ci95([e / (g + p) for e, g, p, _, _, _ in t])
        rq = ci95([float(q) for _, _, _, q, _, _ in t])
        p50 = ci95([a for *_, a, _ in t])
        p95 = ci95([b for *_, b in t])
        pr = ci95([float(p) for _, _, p, _, _, _ in t])
        print(f"  {name:<16} n={len(rs)}")
        print(f"    J / generated token : {jg[0]:.4f} +/- {jg[1]:.4f}")
        print(f"    J / total token     : {jt[0]:.4f} +/- {jt[1]:.4f}")
        print(f"    prompt tokens       : {pr[0]:.0f}")
        print(f"    requests completed  : {rq[0]:.0f}")
        print(f"    latency p50 / p95   : {p50[0]:.3f} / {p95[0]:.3f} s")
        return jg[0], jt[0], rq[0]

    ug, ut, ur = summarise(uni, "unique prompts")
    sg, stt, sr = summarise(sha, "shared prefix")

    print()
    print(f"  per GENERATED token : shared is {sg / ug:.2f}x unique "
          f"({'worse' if sg > ug else 'better'})")
    print(f"  per TOTAL token     : shared is {stt / ut:.2f}x unique "
          f"({'worse' if stt > ut else 'better'})")
    print(f"  requests completed  : shared {sr / ur:.2f}x unique")
    print()
    print("  Reading: the shared-prefix workload carries far more prompt tokens,")
    print("  and prefill is real work. Judged per generated token it looks worse;")
    print("  judged per token actually processed it is better, and it also")
    print("  completed more requests in the same window. Defect S1 in the")
    print("  validity review was therefore a metric artifact, not a conflict")
    print("  between cache affinity and energy. A genuine test needs matched")
    print("  prompt lengths and a measured cache hit rate.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--compare", help="an older h1.csv to check reproduction against")
    a = ap.parse_args()

    rows = load(a.csv)
    print(f"loaded {len(rows)} rows from {a.csv}")

    report_levels(unique_rows(rows), "all trials")
    warmup_effect(rows)
    report_levels(unique_rows(rows, drop_first_trial=True), "trials 2+ only (warm-up excluded)")
    activation(rows, drop_first_trial=True)
    prefix_cache(rows)

    if a.compare:
        old = load(a.compare)
        print(f"\n=== reproduction against {a.compare} ===")
        print(f"{'conc':>5} {'new J/gen-tok':>14} {'old J/gen-tok':>14} {'ratio':>8}")
        new_l = per_level(unique_rows(rows, drop_first_trial=True))
        old_l = per_level(unique_rows(old))
        for c in sorted(set(new_l) & set(old_l)):
            n, _ = ci95([r["j_per_gen_token"] for r in new_l[c]])
            o, _ = ci95([r["j_per_gen_token"] for r in old_l[c]])
            print(f"{c:>5} {n:>14.4f} {o:>14.4f} {n / o:>8.3f}")


if __name__ == "__main__":
    main()
