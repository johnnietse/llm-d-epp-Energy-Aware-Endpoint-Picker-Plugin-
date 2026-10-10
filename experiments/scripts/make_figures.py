#!/usr/bin/env python3
"""Figures from MEASURED data only, read from the committed cluster records.

    python experiments/scripts/make_figures.py

Writes PNGs and, beside each, a CSV of exactly the numbers plotted (the table
view: every value in a figure can be read without the picture). Output goes to
docs/figures/measured/.

Why this exists. The repository's older figures (docs/figures/, docs/diagrams/)
were drawn from a simulation of H100 and Qualcomm Cloud AI 100 hardware that
was never measured, and were withdrawn on 2026-10-08. Every figure here is
traced to a Slurm job id whose raw records are committed under
experiments/cluster-records/.

Two rules keep the figures honest:
  * The Stage 2 gate figure calls stage2_analyse.py's own functions (load,
    reclassify_legacy, best_feasible) rather than re-implementing them, so it
    cannot disagree with the verdict the plan quotes.
  * The Stage 1 curves are aggregated exactly as the routing policies consumed
    them (policy_harness.py load_curve: unique-prompt rows, trial 1 dropped as
    warm-up, mean power / mean token rate). That function cannot be imported
    on Windows (the harness imports `resource`), so its eight lines are
    mirrored in stage1_curve() below.

The CSVs are deterministic text and are what CI compares; PNG bytes differ
across operating systems through font rendering, so they are not compared.
"""
import csv
import glob
import json
import os
import statistics as st
import sys
from collections import defaultdict

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import stage2_analyse as gate  # noqa: E402

REPO = os.path.normpath(os.path.join(HERE, "..", ".."))
REC = os.path.join(REPO, "experiments", "cluster-records", "results")
OUT = os.path.join(REPO, "docs", "figures", "measured")

# ---------------------------------------------------------------- style
# Categorical slots in fixed order (validated: 5 slots pass the CVD and
# normal-vision gates on the light surface; three slots are below 3:1 contrast,
# so every figure carries a legend, distinct marker shapes and a CSV table).
POLICIES = ["round_robin", "least_loaded", "slo_packing",
            "energy_greedy", "energy_consolidate"]
COLOR = {"round_robin": "#2a78d6", "least_loaded": "#eb6834",
         "slo_packing": "#1baf7a", "energy_greedy": "#eda100",
         "energy_consolidate": "#e87ba4"}
MARKER = {"round_robin": "o", "least_loaded": "s", "slo_packing": "^",
          "energy_greedy": "D", "energy_consolidate": "v"}
# GPU types are a different entity set from policies, so they take slots the
# policies do not use (6 green, 7 violet); the four types not in the Stage 2
# fleet are de-emphasised in gray.
GPU_COLOR = {"Quadro_RTX_6000": "#008300", "NVIDIA_A100-PCIE-40GB": "#4a3aa7"}
MUTED = "#a8a7a2"
SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK2 = "#52514e"
GRID = "#e6e5e1"

plt.rcParams.update({
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE,
    "savefig.facecolor": SURFACE, "font.size": 10,
    "axes.edgecolor": GRID, "axes.labelcolor": INK2, "axes.titlecolor": INK,
    "xtick.color": INK2, "ytick.color": INK2, "axes.grid": True,
    "grid.color": GRID, "grid.linewidth": 0.6, "grid.linestyle": "-",
    "axes.spines.top": False, "axes.spines.right": False,
    "legend.frameon": False, "lines.linewidth": 1.6, "lines.markersize": 6,
    "svg.hashsalt": "fixed",
})


def save(fig, name):
    os.makedirs(os.path.dirname(os.path.join(OUT, name)), exist_ok=True)
    fig.savefig(os.path.join(OUT, name + ".png"), dpi=200, bbox_inches="tight",
                metadata={"Software": None})
    plt.close(fig)


def write_csv(name, header, rows):
    os.makedirs(os.path.dirname(os.path.join(OUT, name)), exist_ok=True)
    with open(os.path.join(OUT, name + ".csv"), "w", newline="", encoding="utf-8") as fh:
        w = csv.writer(fh, lineterminator="\n")
        w.writerow(header)
        for r in rows:
            w.writerow([("%.6g" % v) if isinstance(v, float) else v for v in r])


def label(p):
    return p.replace("_", " ")


# ---------------------------------------------------------------- Stage 1
# The curves the Stage 2 routing policies actually loaded, as logged by
# stage2_het.sbatch ("curve for <type>: .../h1-<job>/h1.csv").
STAGE1 = {
    "NVIDIA_A100-PCIE-40GB": "h1-12304125",
    "Quadro_RTX_6000": "h1-12304133",
    "NVIDIA_L40S": "h1-12304129",
    "NVIDIA_A30": "h1-12304127",
    "NVIDIA_L4": "h1-12304128",
    "Quadro_RTX_8000": "h1-12304126",
}


def stage1_curve(path):
    """Mirror of policy_harness.load_curve: unique prompts, trials 2+."""
    pw, tk = defaultdict(list), defaultdict(list)
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            if r["note"] != "unique_prompts" or int(float(r["trial"])) == 1:
                continue
            c = int(float(r["concurrency"]))
            pw[c].append(float(r["mean_power_w"]))
            tk[c].append(float(r["gen_tok_per_s"]))
    return {c: (st.mean(pw[c]), st.mean(tk[c])) for c in sorted(pw)}


def fig_stage1():
    rows, fig = [], plt.figure(figsize=(7.6, 4.6))
    ax = fig.add_subplot(111)
    order = [t for t in STAGE1 if t not in GPU_COLOR] + list(GPU_COLOR)
    ends = []
    for t in order:
        cur = stage1_curve(os.path.join(REC, STAGE1[t], "h1.csv"))
        xs = list(cur)
        ys = [p / tok for p, tok in cur.values()]
        for c, (p, tok) in cur.items():
            rows.append([t, STAGE1[t], c, p, tok, p / tok])
        emph = t in GPU_COLOR
        ax.plot(xs, ys, color=GPU_COLOR.get(t, MUTED), marker="o",
                markersize=5 if emph else 3, linewidth=1.8 if emph else 1.0,
                zorder=3 if emph else 2)
        ends.append([xs[-1], ys[-1], t, emph])
    # Six curves end within a factor of three of each other, so labels at the
    # line ends collide. Put them in one column right of the data, spread to a
    # minimum gap in log space, with a hairline back to each line's end.
    import math
    xcol = 2 ** 8.45
    ends.sort(key=lambda e: e[1])
    ly = [math.log10(e[1]) for e in ends]
    gap = 0.085
    for i in range(1, len(ly)):
        ly[i] = max(ly[i], ly[i - 1] + gap)
    for (x, y, t, emph), l in zip(ends, ly):
        name = t.replace("NVIDIA_", "").replace("Quadro_", "").replace("-PCIE-40GB", "").replace("_", " ")
        ax.plot([x, xcol * 0.93], [y, 10 ** l], color=GPU_COLOR.get(t, MUTED),
                linewidth=0.6, zorder=1)
        ax.text(xcol, 10 ** l, name, va="center", fontsize=8.5,
                color=INK if emph else INK2,
                fontweight="bold" if emph else "normal")
    ax.set_xscale("log", base=2)
    ax.set_yscale("log")
    ax.set_xlim(right=2 ** 9.6)
    ax.set_xticks([2 ** k for k in range(0, 9)])
    ax.set_xlabel("Concurrent requests per GPU")
    ax.set_ylabel("GPU energy per generated token (J)")
    ax.set_title("Stage 1: measured energy curves the routing policies used",
                 loc="left", fontsize=11)
    ax.text(0, -0.2, "Qwen2.5-1.5B-Instruct, vLLM 0.30.0, NVML energy counter. "
            "Mean power / mean token rate per level, trial 1 dropped as warm-up. "
            "Stage 2 fleet in colour.", transform=ax.transAxes, fontsize=7.5,
            color=INK2)
    save(fig, "stage1_energy_per_token")
    write_csv("stage1_energy_per_token",
              ["gpu_type", "job", "concurrency", "mean_power_w",
               "gen_tok_per_s", "j_per_gen_token"], rows)


# ---------------------------------------------------------------- Stage 2
def cells(run_dirs):
    """(policy, rate) -> list of per-trial cells."""
    out = defaultdict(list)
    for d in run_dirs:
        for r in gate.load(os.path.join(REC, d)):
            out[(r["policy"], float(r["offered_rate_rps"]))].append(r)
    return out


def fig_policy_sweep(run_dirs, name, title, note):
    c = cells(run_dirs)
    rates = sorted({k[1] for k in c})
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(7.2, 6.4), sharex=True,
                                 gridspec_kw={"height_ratios": [3, 2]})
    rows = []
    for p in POLICIES:
        xs, gm, glo, ghi, sm = [], [], [], [], []
        for x in rates:
            rs = c.get((p, x), [])
            if not rs:
                continue
            g = [r["goodput_per_joule"] for r in rs]
            s = [r["slo_rate"] * 100 for r in rs]
            xs.append(x); gm.append(st.mean(g)); glo.append(min(g)); ghi.append(max(g))
            sm.append(st.mean(s))
            rows.append([p, x, len(rs), st.mean(g), min(g), max(g), st.mean(s)])
        kw = dict(color=COLOR[p], marker=MARKER[p], label=label(p))
        a1.plot(xs, gm, **kw)
        if len(run_dirs) > 1:
            a1.vlines(xs, glo, ghi, color=COLOR[p], linewidth=0.9, alpha=0.8)
        a2.plot(xs, sm, **kw)
    a2.axhline(95, color=INK2, linewidth=0.8, zorder=1)
    # In the right margin, outside the plot: inside it, the label collides with
    # markers at 100% above the line or with lines crossing below it.
    a2.text(1.01, 95, "95%\nfeasible", transform=a2.get_yaxis_transform(),
            fontsize=7.5, color=INK2, va="center", ha="left")
    a1.set_ylabel("SLO-goodput per joule\n(requests meeting SLO / J)")
    a2.set_ylabel("Requests meeting\nthe 2.0 s SLO (%)")
    a2.set_xlabel("Offered load (requests per second)")
    a2.set_ylim(0, 105)
    a1.set_title(title, loc="left", fontsize=11)
    a1.legend(loc="upper left", fontsize=8, ncol=2)
    a2.text(0, -0.42, note, transform=a2.transAxes, fontsize=7.5, color=INK2)
    save(fig, name)
    write_csv(name, ["policy", "offered_rps", "n_trials", "gp_per_j_mean",
                     "gp_per_j_min", "gp_per_j_max", "slo_pct_mean"], rows)


HET = ["stage2het-12305232", "stage2het-12319685", "stage2het-12321476"]
HOMOG = ["stage2-12321478"]


def fig_gate():
    """Per-trial margin over slo_packing at each policy's best feasible point,
    computed by stage2_analyse's own functions."""
    trials = {d: gate.load(os.path.join(REC, d)) for d in HET}
    gate.reclassify_legacy([r for rs in trials.values() for r in rs])
    rows, data = [], defaultdict(list)
    for i, d in enumerate(HET, 1):
        best = gate.best_feasible(trials[d])
        base = best["slo_packing"]["goodput_per_joule"]
        seed = sorted({r.get("seed") for r in trials[d]})[0]
        for p in ("energy_greedy", "energy_consolidate"):
            m = (best[p]["goodput_per_joule"] - base) / base * 100
            data[p].append(m)
            rows.append([p, d, seed, best[p]["offered_rate_rps"],
                         best[p]["goodput_per_joule"], base, m])
    pooled = gate.best_feasible(gate.mean_cells(trials))
    pbase = pooled["slo_packing"]["goodput_per_joule"]
    fig = plt.figure(figsize=(7.2, 3.2))
    ax = fig.add_subplot(111)
    for yi, p in enumerate(("energy_greedy", "energy_consolidate")):
        ys = [yi] * len(data[p])
        ax.scatter(data[p], ys, color=COLOR[p], marker=MARKER[p], s=46,
                   zorder=3, edgecolors=SURFACE, linewidths=1.2, label=label(p) + ", per trial")
        pm = (pooled[p]["goodput_per_joule"] - pbase) / pbase * 100
        ax.plot([pm, pm], [yi - 0.28, yi + 0.28], color=INK, linewidth=1.6, zorder=4)
        ax.annotate("pooled %+.1f%%" % pm, (pm, yi + 0.3), ha="center", fontsize=8, color=INK)
        rows.append([p, "pooled (mean cells)", "", pooled[p]["offered_rate_rps"],
                     pooled[p]["goodput_per_joule"], pbase, pm])
    ax.axvline(0, color=INK2, linewidth=0.9)
    ax.set_yticks([0, 1])
    ax.set_yticklabels(["energy greedy", "energy consolidate"])
    ax.set_ylim(-0.6, 1.75)
    ax.set_xlim(-0.5, 2.6)
    ax.set_xlabel("SLO-goodput per joule vs slo_packing, at each policy's best "
                  "feasible point (%)")
    ax.set_title("Stage 2 gate, mixed fleet: small but consistent margins",
                 loc="left", fontsize=11)
    ax.text(0, -0.42, "Jobs 12305232, 12319685, 12321476 (seeds 7, 11, 13); "
            "4x A100 + 4x RTX 6000. round_robin (-68.9%) and least_loaded "
            "(-34.1%) are off this scale.", transform=ax.transAxes, fontsize=7.5,
            color=INK2)
    ax.grid(axis="y", visible=False)
    save(fig, "stage2_gate_margins")
    write_csv("stage2_gate_margins", ["policy", "trial", "seed", "best_rps",
                                      "gp_per_j", "slo_packing_gp_per_j",
                                      "margin_pct"], rows)


def fig_node_split():
    """Per-GPU-type energy at one load level, mean over the three trials."""
    rate = 300.0
    c = cells(HET)
    rows = []
    fig = plt.figure(figsize=(7.2, 3.6))
    ax = fig.add_subplot(111)
    ys = list(range(len(POLICIES)))
    for yi, p in enumerate(POLICIES):
        # Sum per trial per GPU type, then mean over trials. per_gpu names use
        # spaces ("Quadro RTX 6000"); normalise to the curve-type spelling.
        totals = defaultdict(list)
        for r in c[(p, rate)]:
            acc = defaultdict(float)
            for g in r["energy"]["per_gpu"]:
                acc[(g.get("name") or "?").replace(" ", "_")] += g["energy_j"]
            for k, v in acc.items():
                totals[k].append(v)
        left = 0.0
        for k in sorted(totals, key=lambda k: (k not in GPU_COLOR, k)):
            v = st.mean(totals[k]) / 1000.0
            ax.barh(yi, v, left=left, color=GPU_COLOR.get(k, MUTED), height=0.6,
                    edgecolor=SURFACE, linewidth=2)
            rows.append([p, rate, k, len(totals[k]), v])
            left += v
    ax.set_yticks(ys)
    ax.set_yticklabels([label(p) for p in POLICIES])
    ax.invert_yaxis()
    ax.set_xlabel("GPU energy in the 60 s measurement window (kJ), mean of 3 trials")
    # Legend in the same left-to-right order as the stacked segments.
    stack = sorted(GPU_COLOR, key=lambda k: (k not in GPU_COLOR, k))
    handles = [plt.Rectangle((0, 0), 1, 1, color=GPU_COLOR[k]) for k in stack]
    ax.legend(handles, [k.replace("_", " ") for k in stack], fontsize=8,
              loc="lower right")
    ax.set_axisbelow(True)
    ax.set_title("Where the energy goes at 300 req/s, mixed fleet", loc="left",
                 fontsize=11)
    ax.grid(axis="y", visible=False)
    save(fig, "stage2_energy_by_gpu_type")
    write_csv("stage2_energy_by_gpu_type", ["policy", "offered_rps", "gpu_type",
                                            "n_trials", "energy_kj_mean"], rows)


def fig_itl():
    rows = []
    for d in ("stage2het-12319685", "stage2het-12321476"):
        for r in gate.load(os.path.join(REC, d)):
            x = r.get("latency_cross_check") or {}
            if x.get("server_itl_mean_s") and x.get("client_itl_mean_s"):
                rows.append([d, r["policy"], float(r["offered_rate_rps"]),
                             x["server_itl_mean_s"] * 1000, x["client_itl_mean_s"] * 1000])
    fig = plt.figure(figsize=(4.8, 4.6))
    ax = fig.add_subplot(111)
    xs = [r[3] for r in rows]
    ys = [r[4] for r in rows]
    lo, hi = min(xs + ys) * 0.95, max(xs + ys) * 1.05
    ax.plot([lo, hi], [lo, hi], color=INK2, linewidth=0.9, zorder=1)
    ax.scatter(xs, ys, color="#2a78d6", s=22, zorder=3, edgecolors=SURFACE,
               linewidths=1.0)
    worst = max(abs(b / a - 1) * 100 for a, b in zip(xs, ys))
    ax.set_xlim(lo, hi); ax.set_ylim(lo, hi); ax.set_aspect("equal")
    ax.set_xlabel("vLLM's own inter-token latency, mean (ms)")
    ax.set_ylabel("Load generator's measurement (ms)")
    ax.set_title("Generator accuracy: %d cells, worst %.2f%% apart" % (len(rows), worst),
                 loc="left", fontsize=11)
    ax.text(0, -0.2, "Jobs 12319685 and 12321476. Line: perfect agreement.",
            transform=ax.transAxes, fontsize=7.5, color=INK2)
    save(fig, "generator_itl_crosscheck")
    write_csv("generator_itl_crosscheck", ["job", "policy", "offered_rps",
                                           "engine_itl_ms", "client_itl_ms"], rows)


def fig_overhead():
    run = os.path.join(REC, "router-overhead-12321497")
    arms = {"A": "direct to vLLM", "B": "router, metrics polling on",
            "C": "router, polling off"}
    acol = {"A": "#2a78d6", "B": "#eb6834", "C": "#1baf7a"}
    amk = {"A": "o", "B": "s", "C": "^"}
    rows = []
    with open(os.path.join(run, "runs.tsv")) as fh:
        for line in fh:
            rate, arm, name, polls = line.rstrip("\n").split("\t")
            b = json.load(open(os.path.join(run, name + ".json")))
            first_a = arm == "A" and name.split("-")[1] == "1"
            rows.append([int(rate), arm, name, int(polls), b["p50_ttft_ms"],
                         b["p50_e2el_ms"], "first-at-rate (excluded)" if first_a else ""])
    fig, axes = plt.subplots(1, 2, figsize=(7.6, 3.6))
    for ax, key, idx in ((axes[0], "Median time to first token (ms)", 4),
                         (axes[1], "Median end-to-end latency (ms)", 5)):
        for k, rate in enumerate(sorted({r[0] for r in rows})):
            for j, arm in enumerate("ABC"):
                pts = [r for r in rows if r[0] == rate and r[1] == arm]
                for q, r in enumerate(pts):
                    x = k * 4 + j + (q - 0.5) * 0.18
                    hollow = bool(r[6])
                    ax.scatter([x], [r[idx]], marker=amk[arm], s=36, zorder=3,
                               facecolors="none" if hollow else acol[arm],
                               edgecolors=acol[arm], linewidths=1.2,
                               label=arms[arm] if (k == 0 and q == 0) else None)
        ax.set_xticks([1, 5])
        ax.set_xticklabels(["10 req/s", "20 req/s"])
        ax.set_ylabel(key)
        ax.grid(axis="x", visible=False)
    # The first direct run at 10 req/s is far off-scale (p50 TTFT 56 ms, e2e
    # 1930 ms); keep the axes on the clean runs and say so.
    clean = [r for r in rows if not r[6]]
    axes[0].set_ylim(min(r[4] for r in clean) * 0.9, max(r[4] for r in clean) * 1.15)
    axes[1].set_ylim(min(r[5] for r in clean) * 0.97, max(r[5] for r in clean) * 1.04)
    axes[0].legend(fontsize=7.5, loc="upper left")
    fig.suptitle("Router overhead, job 12321497 (order A B C C B A per rate)",
                 x=0.01, ha="left", fontsize=11, color=INK)
    fig.text(0.01, -0.04, "Hollow markers: first direct run at each new rate, "
             "a vLLM transient, excluded from the comparison and partly off-scale. "
             "vllm bench serve, 256 in / 128 out tokens.", fontsize=7.5, color=INK2)
    fig.tight_layout()
    save(fig, "router_overhead")
    write_csv("router_overhead", ["offered_rps", "arm", "run", "metrics_polls",
                                  "p50_ttft_ms", "p50_e2el_ms", "note"], rows)


# ------------------------------------------------------------ checkpoints
# Superseded data, kept as a record (author's instruction 2026-10-09). Each
# figure says in its own title that it is a checkpoint, what was wrong, and
# where the decision that followed is recorded. They are not results.
CAL_V1 = {"homog": ["stage2-12325155", "stage2-12325158", "stage2-12325161"],
          "het": ["stage2het-12325156", "stage2het-12325159", "stage2het-12325162"]}
CAL_CELLS = {"homog": (100.0, 150.0), "het": (300.0, 400.0)}
PACKERS = ["slo_packing", "energy_greedy", "energy_consolidate"]


def cal_rows(fleet):
    """Every calibration-v1 cell: (seed, h, rate, policy, row)."""
    out = []
    for d in CAL_V1[fleet]:
        for p in sorted(glob.glob(os.path.join(REC, d, "policies-*rate*.json"))):
            for r in json.load(open(p, encoding="utf-8"))["results"]:
                if float(r["offered_rate_rps"]) in CAL_CELLS[fleet]:
                    out.append((r["seed"], round(float(r.get("headroom", 0.0)), 3),
                                float(r["offered_rate_rps"]), r["policy"], r))
    return out


def fig_checkpoint_calibration_v1():
    fig, axes = plt.subplots(1, 2, figsize=(10, 4.2), sharey=True)
    rows = []
    for ax, fleet, ttl in ((axes[0], "homog", "8x RTX 6000 (100 and 150 req/s)"),
                           (axes[1], "het", "4x A100 + 4x RTX 6000 (300 and 400 req/s)")):
        data = cal_rows(fleet)
        for pol in PACKERS:
            hs = sorted({h for _, h, _, p, _ in data if p == pol})
            sel = [[r["slo_rate"] for _, h2, _, p, r in data if p == pol and h2 == h] for h in hs]
            mean = [100 * st.mean(v) for v in sel]
            low = [100 * min(v) for v in sel]
            ax.plot(hs, mean, color=COLOR[pol], marker=MARKER[pol], label=label(pol))
            ax.plot(hs, low, color=COLOR[pol], lw=0.8, ls=":")
            rows += [[fleet, pol, h, m, w] for h, m, w in zip(hs, mean, low)]
        ax.axhline(95, color=INK2, lw=0.8)
        ax.set_title(ttl, fontsize=9.5, loc="left")
        ax.set_xlabel("headroom h (packers aim at (1 - h) x 2.0 s)")
        ax.set_xticks([0, 0.1, 0.2, 0.3])
    axes[0].set_ylabel("requests meeting the 2.0 s SLO (%)\nsolid: mean of cells and seeds; dotted: worst")
    axes[0].legend(fontsize=8, loc="lower right")
    fig.suptitle("CHECKPOINT, superseded: headroom calibration v1 on closed-loop curves "
                 "- no h qualified", x=0.01, ha="left", fontsize=11)
    fig.text(0.01, -0.06, "Jobs 12325155/58/61 and 12325156/59/62, seeds 901-903. The one-type "
             "fleet passes from h = 0.1; the mixed fleet fails at every h, because closed-loop "
             "curves cannot see queueing at vLLM's 256 limit.\nDecision: approach A, open-loop "
             "curves with p95 and a 256 cap; rule v3 (plan 12.14d, "
             "docs/plan/CHECKPOINT-2026-10-09.md).", fontsize=7.5, color=INK2)
    save(fig, "checkpoints/c1_calibration_v1_closedloop")
    write_csv("checkpoints/c1_calibration_v1_closedloop",
              ["fleet", "policy", "headroom", "slo_met_pct_mean", "slo_met_pct_worst"], rows)


def fig_checkpoint_closedloop_projection():
    path = os.path.join(REC, "h1-12325153", "h1.csv")
    by = defaultdict(list)
    for r in csv.DictReader(open(path, newline="", encoding="utf-8")):
        if r["note"] == "unique_prompts" and r["trial"] not in ("0", "1"):
            by[int(r["concurrency"])].append(r)
    cs = sorted(by)
    p50 = [st.mean(float(x["lat_p50_s"]) for x in by[c]) for c in cs]
    p95 = [st.mean(float(x["lat_p95_s"]) for x in by[c]) for c in cs]
    proj = [st.mean(128 * c / float(x["gen_tok_per_s"]) for x in by[c]) for c in cs]
    col = GPU_COLOR["NVIDIA_A100-PCIE-40GB"]
    fig, ax = plt.subplots(figsize=(7.4, 4.2))
    ax.plot(cs, p50, color=col, marker="o", label="measured p50")
    ax.plot(cs, p95, color=col, marker="^", ls="--", label="measured p95")
    ax.plot(cs, proj, color=MUTED, marker="s", label="router's projection: 128 c / tokens per s")
    ax.axvline(256, color=INK2, lw=0.8)
    ax.text(270, 0.35, "vLLM runs at most 256\n(--max-num-seqs default);\nthe rest wait",
            fontsize=7.5, color=INK2)
    ax.axhline(2.0, color=INK2, lw=0.6, ls=":")
    ax.set_xscale("log", base=2)
    ax.set_xlabel("concurrent requests, held fixed (closed loop)")
    ax.set_ylabel("end-to-end latency (s)")
    ax.legend(fontsize=8, loc="upper left")
    ax.set_title("CHECKPOINT: a closed-loop curve cannot see queueing (A100, h1-12325153)",
                 loc="left", fontsize=10.5)
    fig.text(0.01, -0.07, "Six trials, five used. With concurrency held fixed there are no "
             "arrival bursts, so p50 ~ p95. Superseded for routing by open-loop curves "
             "(approach A, plan 12.14d).", fontsize=7.5, color=INK2)
    save(fig, "checkpoints/c2_closedloop_projection_a100")
    write_csv("checkpoints/c2_closedloop_projection_a100",
              ["concurrency", "lat_p50_s", "lat_p95_s", "projection_s"],
              [[c, a, b, d] for c, a, b, d in zip(cs, p50, p95, proj)])


def fig_checkpoint_ttft():
    data = cal_rows("het")
    hs = sorted({h for _, h, _, _, _ in data})
    ref = [r for (pol, rate), lst in cells(HET).items()
           if pol in PACKERS and rate in (300.0, 400.0) for r in lst]
    ref_ttft = st.mean(r["ttft_p50"] for r in ref)
    fig, ax = plt.subplots(figsize=(7.4, 4.0))
    rows = []
    for pol in PACKERS:
        ys = [st.mean(r["ttft_p50"] for _, h2, _, p, r in data if p == pol and h2 == h) for h in hs]
        ax.plot(hs, ys, color=COLOR[pol], marker=MARKER[pol], label=label(pol))
        rows += [[pol, h, y] for h, y in zip(hs, ys)]
    ax.axhline(ref_ttft, color=INK2, lw=0.8, ls="--")
    ax.text(0.3, ref_ttft + 0.04, "Stage 2, A100 curve ending at 128: %.2f s" % ref_ttft,
            fontsize=7.5, color=INK2, ha="right")
    ax.set_xticks([0, 0.1, 0.2, 0.3])
    ax.set_xlabel("headroom h")
    ax.set_ylabel("median time to first token (s)")
    ax.legend(fontsize=8)
    ax.set_title("CHECKPOINT: mixed-fleet requests waiting for a vLLM slot (calibration v1)",
                 loc="left", fontsize=10.5)
    fig.text(0.01, -0.08, "Mean over 300 and 400 req/s and seeds 901-903. The generator was "
             "ruled out (about 4 cores, send-delay p99 1 ms). Decision: open-loop curves and "
             "a 256 cap (plan 12.14d).", fontsize=7.5, color=INK2)
    save(fig, "checkpoints/c3_ttft_by_headroom_mixed")
    rows.append(["stage2_reference", "", ref_ttft])
    write_csv("checkpoints/c3_ttft_by_headroom_mixed", ["policy", "headroom", "ttft_p50_s"], rows)


def main():
    fig_stage1()
    fig_policy_sweep(HET, "stage2_mixed_fleet",
                     "Stage 2, mixed fleet: energy-aware policies lead",
                     "Jobs 12305232, 12319685, 12321476 (3 seeds); 4x A100 + 4x RTX 6000. "
                     "Lines: mean of trials; whiskers: min to max.")
    fig_policy_sweep(HOMOG, "stage2_homogeneous_control",
                     "Single-type fleet: packing to the 2.0 s target fails",
                     "Job 12321478; 8x RTX 6000, one trial, load inside the fleet's "
                     "capacity. The three packing policies never reach 95% attainment "
                     "(they aimed at 2.0 s with no margin; plan 12.14d).")
    fig_gate()
    fig_node_split()
    fig_itl()
    fig_overhead()
    fig_checkpoint_calibration_v1()
    fig_checkpoint_closedloop_projection()
    fig_checkpoint_ttft()
    print("figures and tables written to", os.path.relpath(OUT, REPO))


if __name__ == "__main__":
    main()
