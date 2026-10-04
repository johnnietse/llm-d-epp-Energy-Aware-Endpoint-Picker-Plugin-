#!/usr/bin/env python3
"""Summarises an h1 curve: the measured concurrency range and the energy
signal across it.

The two numbers that decide whether a curve is usable for Stage 2 routing:
the top measured concurrency (above which interp() now refuses to answer) and
how much J/token actually varies across the range. A curve whose J/token is
flat gives an energy-aware policy nothing to act on, which is what the clamped
RTX 6000 curve effectively did when it froze J/token at its c=32 value.
"""
from __future__ import annotations

import argparse
import csv
import glob
import os
import re


def summarise(run_dir):
    csv_path = os.path.join(run_dir, "h1.csv")
    inst_path = os.path.join(run_dir, "instruments.txt")
    if not os.path.exists(csv_path):
        return None
    try:
        text = open(inst_path).read()
    except OSError:
        text = ""
    gpu = re.search(r"NVIDIA A30|Quadro RTX 6000|NVIDIA L4|NVIDIA A100[^,\s]*"
                    r"|NVIDIA L40S|Quadro RTX 8000|Tesla V100[^,\s]*", text)
    model = re.search(r"model=(\S+)", text)
    rows = {}
    with open(csv_path) as fh:
        for r in csv.DictReader(fh):
            if r.get("note") != "unique_prompts":
                continue
            try:
                c = int(r["concurrency"])
                rows.setdefault(c, []).append((
                    float(r["throughput_rps"]), float(r["gen_tok_per_s"]),
                    float(r["mean_power_w"]), float(r["lat_p95_s"]),
                    float(r["j_per_gen_token"] or 0)))
            except (TypeError, ValueError, KeyError):
                continue
    if not rows:
        return None
    return {
        "dir": os.path.basename(run_dir),
        "gpu": gpu.group(0) if gpu else "unknown",
        "model": model.group(1) if model else "unknown",
        "rows": {c: [sum(x[i] for x in v) / len(v) for i in range(5)]
                 for c, v in rows.items()},
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results_dir")
    ap.add_argument("--jobs", nargs="*", default=[])
    args = ap.parse_args()

    dirs = ([os.path.join(args.results_dir, "h1-" + j) for j in args.jobs]
            if args.jobs
            else sorted(glob.glob(os.path.join(args.results_dir, "h1-*"))))

    for d in dirs:
        info = summarise(d)
        if not info:
            print("\n### %s: no usable h1.csv yet" % os.path.basename(d))
            continue
        rows = info["rows"]
        cs = sorted(rows)
        print("\n### %s  %s  %s" % (info["dir"], info["gpu"], info["model"]))
        print("%6s %9s %11s %9s %9s %10s" % (
            "conc", "req/s", "gen_tok/s", "power_W", "p95_s", "J/gen_tok"))
        for c in cs:
            m = rows[c]
            print("%6d %9.2f %11.1f %9.2f %9.3f %10.4f"
                  % (c, m[0], m[1], m[2], m[3], m[4]))
        jt = [rows[c][4] for c in cs if rows[c][4] > 0]
        if jt and len(cs) > 1:
            print("  top measured concurrency: %d" % cs[-1])
            print("  J/gen_token %.4f at c=%d down to %.4f at c=%d "
                  "(%.0f%% reduction)"
                  % (jt[0], cs[0], jt[-1], cs[-1],
                     (1 - jt[-1] / jt[0]) * 100))
            # Where p95 crosses a 2 s SLO, which bounds usable concurrency.
            crossed = [c for c in cs if rows[c][3] > 2.0]
            if crossed:
                print("  p95 first exceeds 2.0 s at c=%d" % crossed[0])
            else:
                print("  p95 never exceeds 2.0 s in the measured range")


if __name__ == "__main__":
    main()
