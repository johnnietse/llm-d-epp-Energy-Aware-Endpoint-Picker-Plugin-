#!/usr/bin/env python3
"""Build an open-loop curve CSV from one openloop_curve.sbatch run.

    python openloop_build.py <run_dir>          # writes <run_dir>/curve.csv

Input: <run_dir>/olc-trial<t>-rate<r>.json, each one policy_harness.py cell
(one endpoint, round_robin, Poisson arrivals at rate r), and optionally
<run_dir>/idle.txt holding the idle power in watts with the model loaded.

One row per (trial, rate). policy_harness.load_openloop_curve reads this file,
drops trial 1 as warm-up, and ends the curve at the first rate where any trial
failed to keep up.
"""
import csv
import glob
import json
import os
import re
import sys

COLS = ["trial", "rate", "achieved_rps", "rate_fidelity", "client_limited",
        "server_saturated", "completed", "errors", "inflight_mean",
        "latency_mean", "lat_p50", "lat_p95", "lat_p99", "ttft_p50", "ttft_p95",
        "tpot_mean", "tok_s", "power_w", "energy_j", "window_s",
        "running_end", "waiting_end", "idle_power_w"]


def engine_delta(r, key):
    b, a = r.get("engine_metrics_before") or {}, r.get("engine_metrics_after") or {}
    if len(a) != 1 or len(b) != 1:
        raise SystemExit("expected exactly one endpoint per cell")
    (eb,), (ea,) = b.values(), a.values()
    return ea[key] - eb[key], ea


def main():
    run = sys.argv[1]
    idle = ""
    p = os.path.join(run, "idle.txt")
    if os.path.exists(p):
        idle = open(p).read().strip()
    rows = []
    for f in glob.glob(os.path.join(run, "olc-trial*-rate*.json")):
        m = re.search(r"olc-trial(\d+)-rate([0-9.]+)\.json$", f)
        res = json.load(open(f))["results"]
        if len(res) != 1:
            raise SystemExit("%s: expected one result" % f)
        r = res[0]
        gen, ea = engine_delta(r, "generation_tokens_total")
        win = r["energy"]["window_s"]
        g = r["energy"]["per_gpu"]
        if len(g) != 1:
            raise SystemExit("%s: expected one GPU" % f)
        rows.append({
            "trial": int(m.group(1)), "rate": float(m.group(2)),
            "achieved_rps": r["achieved_rate_rps"], "rate_fidelity": r["rate_fidelity"],
            "client_limited": r["client_limited"], "server_saturated": r["server_saturated"],
            "completed": r["completed"], "errors": r["errors"],
            "inflight_mean": r["inflight_mean"], "latency_mean": r["latency_mean"],
            "lat_p50": r["latency_p50"], "lat_p95": r["latency_p95"], "lat_p99": r["latency_p99"],
            "ttft_p50": r["ttft_p50"], "ttft_p95": r["ttft_p95"], "tpot_mean": r["tpot_mean"],
            "tok_s": gen / win, "power_w": g[0]["mean_power_w_counter"],
            "energy_j": g[0]["energy_j_counter"], "window_s": win,
            "running_end": ea.get("num_requests_running"),
            "waiting_end": ea.get("num_requests_waiting"),
            "idle_power_w": idle,
        })
    if not rows:
        raise SystemExit("no olc-trial*-rate*.json in " + run)
    rows.sort(key=lambda x: (x["trial"], x["rate"]))
    out = os.path.join(run, "curve.csv")
    with open(out, "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=COLS)
        w.writeheader()
        w.writerows(rows)
    print("wrote %s: %d rows, trials %s, rates %s" % (
        out, len(rows), sorted({x["trial"] for x in rows}),
        sorted({x["rate"] for x in rows})))


if __name__ == "__main__":
    main()
