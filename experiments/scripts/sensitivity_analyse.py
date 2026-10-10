#!/usr/bin/env python3
"""Analysis for the vLLM batch-limit sensitivity study (exploratory).

    python experiments/scripts/sensitivity_analyse.py <olc_run_dir> [...]

Implements docs/plan/SENSITIVITY-VLLM-LIMITS.md exactly. It was committed
BEFORE the first sensitivity record was fetched. Changing a measure or the
rule afterwards is a deviation and must be reported as one.

Each run dir is one open-loop curve (openloop_curve.sbatch). Its GPU type,
max-num-seqs and max-num-batched-tokens are read from its instruments.txt,
never inferred from the directory name.

Outputs, in docs/figures/measured/sensitivity/:
  sensitivity_by_rate.csv     every (GPU, setting, rate): means and 95% CIs
  sensitivity_capacity.csv    every (GPU, setting, T): C(T) and the measures there
  sensitivity_rules.csv       per (GPU, T): the leader, ties, and the capacity ranking
and the same rules printed to stdout.
"""
import csv
import math
import os
import re
import statistics as st
import sys
from collections import defaultdict

from scipy import stats

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "docs", "figures", "measured",
                                    "sensitivity"))
TARGETS = (1.0, 1.5, 2.0, 3.0)
KEEPUP_MIN = 0.95
TYPES = (r"NVIDIA A100[^,\s]*|Quadro RTX 6000")


def keepup(row):
    k = row.get("keepup")
    return float(k) if k not in (None, "", "None") else float(row["rate_fidelity"])


def ci(xs):
    """Mean and 95% CI half-width (t). Half-width is nan for a single value."""
    m = st.mean(xs)
    if len(xs) < 2:
        return m, float("nan")
    return m, stats.t.ppf(0.975, len(xs) - 1) * st.stdev(xs) / math.sqrt(len(xs))


def describe(run):
    """(gpu, seqs, batched) from instruments.txt, or None with a reason."""
    try:
        text = open(os.path.join(run, "instruments.txt"), encoding="utf-8").read()
    except OSError:
        return None, "no instruments.txt"
    g = re.search(TYPES, text)
    m = re.search(r"--max-num-seqs (\d+) --max-num-batched-tokens (\d+)", text)
    if not g or not m:
        return None, "instruments.txt lacks GPU type or vLLM limits"
    return (g.group(0).replace(" ", "_"), int(m.group(1)), int(m.group(2))), None


def load(run):
    """{rate: [rows of trials 2+]}, or None with a reason (e.g. did not run)."""
    p = os.path.join(run, "curve.csv")
    if not os.path.exists(p):
        return None, "no curve.csv (vLLM may not have started; see vllm.log)"
    rows = defaultdict(list)
    with open(p, newline="", encoding="utf-8") as fh:
        for r in csv.DictReader(fh):
            if int(float(r["trial"])) != 1:
                rows[float(r["rate"])].append(r)
    if not rows:
        return None, "curve.csv has no usable trials"
    return rows, None


def per_rate(rows):
    """Ordered per-rate summaries, flagged stationary up to the first failure."""
    out, still = [], True
    for rate in sorted(rows):
        g = rows[rate]
        ok = all(keepup(x) >= KEEPUP_MIN and x["client_limited"] not in ("True", "1")
                 for x in g)
        still = still and ok
        rpj = [float(x["realized_rate_rps"] or x["achieved_rps"]) / float(x["power_w"])
               for x in g]
        jpt = [float(x["power_w"]) / float(x["tok_s"]) for x in g if float(x["tok_s"]) > 0]
        rec = {"rate": rate, "trials": len(g), "stationary": still,
               "keepup_min": min(keepup(x) for x in g)}
        for key, xs in (("p95_s", [float(x["lat_p95"]) for x in g]),
                        ("p50_s", [float(x["lat_p50"]) for x in g]),
                        ("ttft_p50_s", [float(x["ttft_p50"]) for x in g]),
                        ("power_w", [float(x["power_w"]) for x in g]),
                        ("req_per_j", rpj), ("j_per_token", jpt)):
            rec[key], rec[key + "_ci"] = ci(xs) if xs else (float("nan"), float("nan"))
        out.append(rec)
    return out


def capacity(recs, target):
    """C(T): highest stationary measured rate whose mean p95 <= T (no interpolation)."""
    best = None
    for r in recs:
        if r["stationary"] and r["p95_s"] <= target:
            best = r
    return best


def main():
    runs = sys.argv[1:]
    if not runs:
        raise SystemExit(__doc__)
    os.makedirs(OUT, exist_ok=True)
    table, notrun = {}, []
    for run in runs:
        key, why = describe(run)
        if key is None:
            notrun.append((run, why))
            continue
        rows, why = load(run)
        if rows is None:
            notrun.append((run, "%s: %s" % (key, why)))
            continue
        if key in table:
            raise SystemExit("two runs for the same setting %s: %s" % (key, run))
        table[key] = (run, per_rate(rows))

    with open(os.path.join(OUT, "sensitivity_by_rate.csv"), "w", newline="",
              encoding="utf-8") as fh:
        w = csv.writer(fh, lineterminator="\n")
        cols = ["rate", "trials", "stationary", "keepup_min", "p95_s", "p95_s_ci", "p50_s",
                "ttft_p50_s", "power_w", "req_per_j", "req_per_j_ci", "j_per_token"]
        w.writerow(["gpu", "max_num_seqs", "max_num_batched_tokens", "run"] + cols)
        for (gpu, s, b), (run, recs) in sorted(table.items()):
            for r in recs:
                w.writerow([gpu, s, b, os.path.basename(run.rstrip("/\\"))] +
                           [("%.6g" % r[c]) if isinstance(r[c], float) else r[c] for c in cols])

    cap_rows, rule_rows = [], []
    for gpu in sorted({k[0] for k in table}):
        for T in TARGETS:
            cands = []
            for (g, s, b), (run, recs) in sorted(table.items()):
                if g != gpu:
                    continue
                c = capacity(recs, T)
                cap_rows.append([gpu, s, b, T] + ([c["rate"], c["req_per_j"], c["req_per_j_ci"],
                                                   c["j_per_token"], c["p95_s"], c["ttft_p50_s"]]
                                                  if c else ["none", "", "", "", "", ""]))
                if c:
                    cands.append(((s, b), c))
            if not cands:
                rule_rows.append([gpu, T, "no setting meets T", "", "", ""])
                continue
            cands.sort(key=lambda x: -x[1]["req_per_j"])
            lead = cands[0]
            lo = lead[1]["req_per_j"] - (lead[1]["req_per_j_ci"]
                                         if not math.isnan(lead[1]["req_per_j_ci"]) else 0.0)
            ties = [k for k, c in cands[1:] if c["req_per_j"] >= lo]
            by_cap = [k for k, c in sorted(cands, key=lambda x: -x[1]["rate"])]
            rule_rows.append([gpu, T, "%s/%s" % lead[0],
                              " ".join("%s/%s" % t for t in ties) or "none",
                              "%.4g" % lead[1]["req_per_j"],
                              " > ".join("%s/%s" % k for k in by_cap)])

    with open(os.path.join(OUT, "sensitivity_capacity.csv"), "w", newline="",
              encoding="utf-8") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(["gpu", "max_num_seqs", "max_num_batched_tokens", "target_s",
                    "capacity_rps", "req_per_j", "req_per_j_ci", "j_per_token", "p95_s",
                    "ttft_p50_s"])
        for r in cap_rows:
            w.writerow([("%.6g" % v) if isinstance(v, float) else v for v in r])
    with open(os.path.join(OUT, "sensitivity_rules.csv"), "w", newline="",
              encoding="utf-8") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(["gpu", "target_s", "leader_seqs/batched", "tied_with_leader",
                    "leader_req_per_j", "capacity_ranking_high_to_low"])
        w.writerows(rule_rows)

    print("Settings analysed: %d. Not run or unusable: %d." % (len(table), len(notrun)))
    for run, why in notrun:
        print("  NOT RUN  %s: %s" % (run, why))
    print("\nRules (highest SLO-met requests per joule at C(T); ties = within the "
          "leader's 95% CI):")
    for r in rule_rows:
        print("  %-24s T=%.1fs  leader %-10s ties: %-20s  capacity order: %s"
              % (r[0], r[1], r[2], r[3], r[5]))
    print("\nTables in", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
