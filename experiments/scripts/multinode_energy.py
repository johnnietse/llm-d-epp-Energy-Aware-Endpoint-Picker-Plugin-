#!/usr/bin/env python3
"""Stitch per-node energy sampler files into one window figure.

Used by the heterogeneous multi-node experiment, where NVML's node-locality
forces energy to be collected separately on each node (see
node_energy_sampler.py) and combined afterwards.

The one real hazard is clock alignment. Window boundaries come from the
harness's clock; the samples carry each node's own clock. If those disagree,
energy is attributed to the wrong window. Three things keep that honest:

  * the skew is MEASURED, not assumed, by stage2_het.sbatch running date(1) on
    every node from the batch host and recording the spread;
  * this module takes that measured skew and reports how much energy it could
    account for, so the uncertainty is a number rather than a hope;
  * boundaries are interpolated between bracketing samples instead of snapping
    to the nearest one, so sub-sample-period placement does not quantise.

On a 60 s window with a few milliseconds of skew the contribution is far below
the counter's own resolution, but today has produced enough
reported-but-unverified quantities that it gets computed anyway.
"""
# No "from __future__ import annotations" here. This module is read by
# the BATCH HOST's python, which on Rocky 8 is the system 3.6, and that
# import needs 3.7+: the het preflight (job 12304885) passed its first
# four checks and then died on
#   SyntaxError: future feature annotations is not defined
# The module uses no annotations, so the import was decoration. Keep
# this file 3.6-clean: percent formatting, no f-strings, no walrus.

import argparse
import glob
import json
import os


def load(path):
    header, samples = None, []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue          # a final truncated line if SIGTERM raced us
            if rec.get("kind") == "header":
                header = rec
            elif "t" in rec and "mj" in rec:
                samples.append(rec)
    samples.sort(key=lambda r: r["t"])
    return header, samples


def interp_cumulative(samples, t, gpu_count):
    """Cumulative mJ per GPU at wall time t, linearly interpolated.

    Returns None when t lies outside the sampled span: extrapolating a
    cumulative counter past the data would invent energy, and a window that is
    not fully covered by samples is a window this module must refuse rather
    than estimate.
    """
    if not samples or t < samples[0]["t"] or t > samples[-1]["t"]:
        return None
    lo, hi = 0, len(samples) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if samples[mid]["t"] <= t:
            lo = mid
        else:
            hi = mid
    a, b = samples[lo], samples[hi]
    span = b["t"] - a["t"]
    f = 0.0 if span <= 0 else (t - a["t"]) / span
    out = []
    for g in range(gpu_count):
        va = a["mj"][g] if g < len(a["mj"]) else None
        vb = b["mj"][g] if g < len(b["mj"]) else None
        if va is None or vb is None:
            out.append(None)
        else:
            out.append(va + f * (vb - va))
    return out


def window_energy(path, t0, t1, skew_s=0.0, tolerance_s=0.0):
    header, samples = load(path)
    if header is None or not samples:
        return {"path": os.path.basename(path), "error": "no samples"}
    gpus = header.get("gpus", [])
    n = len(gpus)

    # The window's end is "now" in the harness, while the newest sample can be
    # up to one sampling interval older - the sampler is always slightly
    # behind. Requiring t1 to lie strictly inside the sampled span therefore
    # rejected every cell of job 12305215 for being ~0.3 s ahead of the data,
    # even though the samplers were working perfectly (1644 and 1627 samples at
    # a 0.29 s interval). Allow t1 to be pulled back onto the last sample when
    # the gap is within tolerance, and record that it happened rather than
    # hiding it. The same for t0 against the first sample.
    clamped_end = clamped_start = 0.0
    last_t, first_t = samples[-1]["t"], samples[0]["t"]
    if t1 > last_t and (t1 - last_t) <= tolerance_s:
        clamped_end = t1 - last_t
        t1 = last_t
    if t0 < first_t and (first_t - t0) <= tolerance_s:
        clamped_start = first_t - t0
        t0 = first_t

    c0 = interp_cumulative(samples, t0, n)
    c1 = interp_cumulative(samples, t1, n)
    if c0 is None or c1 is None:
        return {
            "path": os.path.basename(path),
            "host": header.get("host"),
            "error": "window not covered by samples",
            "sample_span": [samples[0]["t"], samples[-1]["t"]],
            "requested": [t0, t1],
            "tolerance_s": tolerance_s,
        }

    per_gpu, total = [], 0.0
    for g in range(n):
        if c0[g] is None or c1[g] is None:
            per_gpu.append({"index": gpus[g]["index"], "energy_j": None})
            continue
        j = (c1[g] - c0[g]) / 1000.0
        total += j
        window = max(1e-9, t1 - t0)
        per_gpu.append({
            "index": gpus[g]["index"],
            "name": gpus[g]["name"],
            "uuid": gpus[g]["uuid"],
            "energy_j": round(j, 3),
            "mean_power_w": round(j / window, 2),
        })

    # What the measured clock skew could be worth, in joules, at this node's
    # mean power. Reported so the cross-node figure carries its own error bar.
    window = max(1e-9, t1 - t0)
    mean_w = total / window
    return {
        "path": os.path.basename(path),
        "host": header.get("host"),
        "driver": header.get("driver"),
        "n_samples_in_window": sum(1 for s in samples if t0 <= s["t"] <= t1),
        "window_s": round(window, 4),
        "per_gpu": per_gpu,
        "total_energy_j": round(total, 3),
        "mean_power_w": round(mean_w, 2),
        "skew_s": skew_s,
        "skew_energy_uncertainty_j": round(abs(skew_s) * mean_w, 3),
        "skew_energy_uncertainty_pct": (round(abs(skew_s) / window * 100, 4)
                                        if window > 0 else None),
        # Non-zero means the window was trimmed to the sampled span. Small
        # values are the sampler lagging by under one interval; anything large
        # would mean the window and the samples genuinely disagree.
        "window_clamped_start_s": round(clamped_start, 4),
        "window_clamped_end_s": round(clamped_end, 4),
    }


def aggregate(sample_dir, t0, t1, skew_s=0.0, tolerance_s=0.0):
    nodes = []
    for path in sorted(glob.glob(os.path.join(sample_dir, "energy-*.jsonl"))):
        nodes.append(window_energy(path, t0, t1, skew_s, tolerance_s))
    ok = [n for n in nodes if "error" not in n]
    bad = [n for n in nodes if "error" in n]
    total = sum(n["total_energy_j"] for n in ok)
    unc = sum(n["skew_energy_uncertainty_j"] for n in ok)
    return {
        "nodes": nodes,
        "nodes_ok": len(ok),
        "nodes_failed": len(bad),
        "total_energy_j": round(total, 3),
        "skew_energy_uncertainty_j": round(unc, 3),
        "skew_energy_uncertainty_pct": (round(unc / total * 100, 4)
                                        if total > 0 else None),
        # A fleet-wide energy figure missing a node is not a smaller figure, it
        # is a wrong one. Callers must refuse on this rather than scale.
        "complete": len(bad) == 0 and len(ok) > 0,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sample_dir")
    ap.add_argument("--t0", type=float, required=True)
    ap.add_argument("--t1", type=float, required=True)
    ap.add_argument("--tolerance", type=float, default=0.0,
                    help="how far outside the sampled span a window boundary "
                         "may be pulled back, in seconds; roughly two "
                         "sampling intervals")
    ap.add_argument("--skew", type=float, default=0.0,
                    help="measured max clock skew across nodes, seconds")
    args = ap.parse_args()
    print(json.dumps(aggregate(args.sample_dir, args.t0, args.t1, args.skew,
                               args.tolerance), indent=2))


if __name__ == "__main__":
    main()
