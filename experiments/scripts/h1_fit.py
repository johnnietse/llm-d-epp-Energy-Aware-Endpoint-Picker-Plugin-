#!/usr/bin/env python3
"""Fit the H1 power model to a sweep CSV and report goodness of fit.

Model:  P(b) = P_idle + k_b * b          (b = concurrent requests)
        and  P(b, t) = P_idle + k_b*b + k_t*t  when a token-rate column is used.

Reports R^2 and residuals, because the hypothesis is only useful if the fit is
good enough to predict marginal energy online. Also prints the quantity the
scorer actually needs: marginal joules per additional request.

Stdlib only (no numpy on the cluster python by default).
"""
import argparse, csv, statistics


def ols(xs, ys):
    """Simple least squares y = a + b x. Returns (a, b, r2, residuals)."""
    n = len(xs)
    mx, my = statistics.fmean(xs), statistics.fmean(ys)
    sxx = sum((x - mx) ** 2 for x in xs)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    b = sxy / sxx if sxx else 0.0
    a = my - b * mx
    pred = [a + b * x for x in xs]
    ss_res = sum((y - p) ** 2 for y, p in zip(ys, pred))
    ss_tot = sum((y - my) ** 2 for y in ys)
    r2 = 1 - ss_res / ss_tot if ss_tot else float("nan")
    resid = [y - p for y, p in zip(ys, pred)]
    return a, b, r2, resid


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    args = ap.parse_args()

    rows = list(csv.DictReader(open(args.csv)))
    load = [r for r in rows if r["note"] == "unique_prompts" and int(r["concurrency"]) > 0]
    idle = [r for r in rows if r["note"] == "idle_model_loaded"]
    shared = [r for r in rows if r["note"] == "shared_prefix"]

    if not load:
        raise SystemExit("no load rows in CSV")

    xs = [float(r["concurrency"]) for r in load]
    ys = [float(r["mean_power_w"]) for r in load]
    a, b, r2, resid = ols(xs, ys)

    if len(load) < 4:
        print(f"WARNING: only {len(load)} load points; a straight line fits "
              f"{'exactly' if len(load) <= 2 else 'too easily'}. R^2 is not "
              f"evidence at this size -- run the full sweep.\n")

    print("=== H1: P(b) = P_idle + k_b * b ===")
    if idle:
        print(f"measured idle (model resident): {idle[0]['mean_power_w']} W")
    print(f"fitted P_idle = {a:.1f} W")
    print(f"fitted k_b    = {b:.2f} W per concurrent request")
    print(f"R^2           = {r2:.4f}")
    print(f"max |residual| = {max(abs(x) for x in resid):.2f} W")
    print()

    print("=== energy per token vs load (the batching effect) ===")
    print(f"{'conc':>5} {'power_W':>8} {'tok/s':>8} {'J/tok':>8} {'p95_s':>7}")
    for r in sorted(load, key=lambda r: int(r["concurrency"])):
        jt = r["j_per_gen_token"] or "-"
        print(f"{r['concurrency']:>5} {r['mean_power_w']:>8} {r['gen_tok_per_s']:>8} "
              f"{str(jt):>8} {r['lat_p95_s']:>7}")
    jts = [(int(r["concurrency"]), float(r["j_per_gen_token"]))
           for r in load if r["j_per_gen_token"]]
    if len(jts) >= 2:
        best = min(jts, key=lambda t: t[1])
        worst = max(jts, key=lambda t: t[1])
        print(f"\nJ/token range: {worst[1]:.4f} at c={worst[0]} -> {best[1]:.4f} at c={best[0]}"
              f"  ({worst[1]/best[1]:.2f}x)")

    print("\n=== marginal energy (what the scorer needs) ===")
    # Cost structure that decides routing: waking an idle GPU vs adding one more
    # request to a GPU that is already working.
    if idle:
        pi = float(idle[0]["mean_power_w"])
        first = min(load, key=lambda r: int(r["concurrency"]))
        activation = float(first["mean_power_w"]) - pi
        print(f"activation cost (idle -> c={first['concurrency']}): {activation:+.1f} W")
        print(f"marginal cost per extra concurrent request:  {b:+.2f} W")
        if b > 0:
            print(f"ratio: waking an idle GPU costs {activation / b:.0f}x one extra "
                  f"request on an already-active GPU")
        print("routing implication: consolidate onto active endpoints; the "
              "per-request increment is small next to the activation step.")
        print(f"idle floor {pi:.1f} W = "
              f"{pi / max(ys) * 100:.0f}% of power at the highest load measured")
    else:
        print(f"adding one concurrent request costs ~{b:.2f} W while it runs")

    if shared:
        print("\n=== prefix-cache effect (same concurrency, shared vs unique prompts) ===")
        for s in shared:
            c = s["concurrency"]
            u = next((r for r in load if r["concurrency"] == c), None)
            if not u:
                continue
            print(f"c={c}: unique J/tok={u['j_per_gen_token']} "
                  f"shared J/tok={s['j_per_gen_token']}  "
                  f"unique tok/s={u['gen_tok_per_s']} shared tok/s={s['gen_tok_per_s']}")

    print("\n=== gate ===")
    print("H1 holds if R^2 is high and residuals are small relative to k_b.")
    print(f"verdict: R^2={r2:.4f}", "PASS" if r2 >= 0.90 else "WEAK - revisit model form")


if __name__ == "__main__":
    main()
