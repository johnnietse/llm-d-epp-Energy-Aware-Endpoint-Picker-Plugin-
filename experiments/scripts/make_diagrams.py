#!/usr/bin/env python3
"""Design and architecture diagrams for the CURRENT design (2026-10-09).

    python experiments/scripts/make_diagrams.py   # writes docs/diagrams/current/

These are drawings of how the system and the study are built, not results.
The few numbers they show are labelled with the job or commit they come from.
Measured data figures are in docs/figures/measured/ (make_figures.py). The
older drawings in docs/diagrams/ describe the superseded first design.

Drawn with matplotlib so the output is deterministic and needs nothing beyond
requirements.txt. (The Mermaid CLI on the author's machine lacks its browser
dependency.)
"""
import os
import textwrap

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.patches import FancyArrowPatch, FancyBboxPatch  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "docs", "diagrams", "current"))

SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK2 = "#52514e"
LINE = "#8a8984"
GRID = "#e6e5e1"
A100 = "#4a3aa7"     # same entity colours as docs/figures/measured
RTX = "#008300"
ROUTER = "#2a78d6"
MEASURE = "#eda100"
DONE = "#1baf7a"
WARN = "#eb6834"
PENDING = "#a8a7a2"

plt.rcParams.update({"font.size": 9, "figure.facecolor": SURFACE,
                     "savefig.facecolor": SURFACE, "svg.hashsalt": "fixed"})


def canvas(w, h, title, subtitle=None, top=None):
    """x runs 0-100; y runs 0-top, chosen per diagram to fit its content."""
    fig = plt.figure(figsize=(w, h))
    ax = fig.add_axes([0, 0, 1, 1])
    top = top or 100 * h / w
    ax.set_xlim(0, 100)
    ax.set_ylim(0, top)
    ax.axis("off")
    ax.text(2, top - 2.5, title, fontsize=13, color=INK, va="top", weight="bold")
    if subtitle:
        ax.text(2, top - 6.2, subtitle, fontsize=8.5, color=INK2, va="top")
    return fig, ax, top


def box(ax, x, y, w, h, text, color=LINE, fill=None, size=8.5, bold_first=True,
        wrap=None, align="center"):
    """Rounded box; first line bold. (x, y) is the lower-left corner."""
    ax.add_patch(FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.25,rounding_size=0.8",
                                fc=fill or "white", ec=color, lw=1.3))
    lines = text.split("\n")
    if wrap:
        lines = [seg for ln in lines for seg in (textwrap.wrap(ln, wrap) or [""])]
    n = len(lines)
    step = min(2.6, (h - 1.2) / max(n, 1))
    y0 = y + h / 2 + step * (n - 1) / 2
    xt = x + w / 2 if align == "center" else x + 1.2
    for i, ln in enumerate(lines):
        ax.text(xt, y0 - i * step, ln, ha=align, va="center",
                fontsize=size + (0.5 if i == 0 and bold_first else 0),
                color=INK if i == 0 else INK2,
                weight="bold" if i == 0 and bold_first else "normal")


def arrow(ax, p, q, text=None, color=LINE, style="-|>", ls="-", off=(0, 1.2), size=7.5,
          rad=0.0, both=False):
    ax.add_patch(FancyArrowPatch(p, q, arrowstyle=("<|-|>" if both else style),
                                 mutation_scale=11, color=color, lw=1.2, linestyle=ls,
                                 connectionstyle="arc3,rad=%s" % rad))
    if text:
        mx, my = (p[0] + q[0]) / 2 + off[0], (p[1] + q[1]) / 2 + off[1]
        ax.text(mx, my, text, ha="center", va="bottom", fontsize=size, color=INK2,
                bbox=dict(fc=SURFACE, ec="none", pad=0.3))


def note(ax, x, y, text, size=7.5, color=INK2, width=None, ha="left"):
    if width:
        text = "\n".join(textwrap.wrap(text, width))
    ax.text(x, y, text, fontsize=size, color=color, va="top", ha=ha)


def save(fig, name):
    os.makedirs(OUT, exist_ok=True)
    fig.savefig(os.path.join(OUT, name + ".png"), dpi=170, metadata={"Software": None})
    plt.close(fig)


# ------------------------------------------------------------------ D1
def d1_architecture():
    fig, ax, top = canvas(13, 7.2, "System architecture: the Stage 5 path",
                          "llm-d's router running without Kubernetes on a Slurm cluster. "
                          "The energy-aware scorers in the EPP are Stage 4 work, not yet built.", top=70)
    box(ax, 2, 30, 17, 16, "Load generator\npolicy_harness.py\nopen-loop Poisson arrivals\n"
        "Stage 2 prompt mix\n128 output tokens", color=INK2)
    box(ax, 25, 30, 13, 16, "Envoy 1.39.2\nproxy, sends each\nrequest's headers\nto the EPP", color=ROUTER)
    box(ax, 23, 3, 34, 21, "llm-d EPP v0.11.0  (file-discovery mode)\n"
        "filters + scorers pick ONE endpoint per request\n"
        "ours: energy_consolidate | energy_greedy\n"
        "        slo_packing | round_robin   (Go, Stage 4)\n"
        "upstream: random, stock profile, latency-scorer 'least'",
        color=ROUTER, fill="#f2f7fd")
    box(ax, 62, 3, 25, 21, "What the scorers read\nper-GPU-type open-loop curve:\n"
        "power, tokens/s, p95 latency\nagainst mean in-flight\n"
        "+ EPP's own in-flight count\n(no metrics polling needed)", color=MEASURE)
    arrow(ax, (57.5, 13.5), (61.5, 13.5), color=MEASURE)
    arrow(ax, (19.4, 38), (24.6, 38), "HTTP", color=INK2)
    arrow(ax, (31.5, 29.6), (31.5, 24.4), "ext-proc gRPC:\nwhich endpoint?", color=ROUTER, both=True,
          off=(-6.5, -1.5))
    # nodes
    box(ax, 46, 42, 24, 17, "frnt154: 4x A100-PCIE-40GB\n4 vLLM 0.30.0 servers\n"
        "--max-num-seqs 256\n--max-num-batched-tokens 2048", color=A100, fill="#f4f2fb")
    box(ax, 46, 24.8, 24, 15.5, "frnt149: 4x Quadro RTX 6000\n4 vLLM 0.30.0 servers\n"
        "same pinned limits", color=RTX, fill="#f1f8f1")
    arrow(ax, (38.4, 41), (45.6, 50), color=INK2)
    arrow(ax, (38.4, 35), (45.6, 32), color=INK2)
    # measurement plane
    box(ax, 75, 42, 23, 17, "Measurement plane\nNVML energy counter,\nper GPU, per node\n"
        "(GPU-package energy only)", color=MEASURE)
    arrow(ax, (70.4, 50), (74.6, 50), color=MEASURE, ls="--")
    arrow(ax, (70.4, 32), (74.6, 45), color=MEASURE, ls="--")
    box(ax, 75, 26, 23, 12.5, "experiments/\ncluster-records/\nevery raw record,\ncommitted", color=INK2)
    arrow(ax, (86.5, 41.6), (86.5, 38.9), color=MEASURE, ls="--")
    note(ax, 2, 26, "Per-request timings (TTFT, ITL, end-to-end) are recorded by the "
         "generator; energy windows are aligned across nodes by a measured clock skew.",
         width=36)
    save(fig, "d1_system_architecture")


# ------------------------------------------------------------------ D2
def d2_paths():
    fig, ax, top = canvas(13, 5.6, "Where the routing decision is made: Stage 2 versus Stage 5",
                          "Stage 2 measured the RULE; Stage 5 measures llm-d delivering it.", top=60)
    ax.add_patch(FancyBboxPatch((1, 30), 98, 18, boxstyle="round,pad=0.2", fc="#f7f7f5", ec=GRID))
    ax.add_patch(FancyBboxPatch((1, 1.5), 98, 24.5, boxstyle="round,pad=0.2", fc="#f2f7fd", ec=GRID))
    note(ax, 2.5, 46.5, "Stage 2 (done, jobs 12305232, 12319685, 12321476, 12321478)", size=8.5, color=INK)
    box(ax, 4, 32, 30, 11, "Load generator\n+ routing rule inside it (Python)", color=INK2)
    box(ax, 50, 32, 20, 11, "vLLM servers", color=INK2)
    arrow(ax, (34.4, 37.5), (49.6, 37.5), "request sent straight\nto the chosen server")
    note(ax, 73, 42, "No Envoy, no EPP. Shows the rule saves energy, not that a router "
         "plugin delivers it.", width=34)
    note(ax, 2.5, 24.5, "Stage 5 (planned, after Stage 4 builds the Go scorers)", size=8.5, color=INK)
    box(ax, 4, 7, 16, 11, "Load generator\n(no routing)", color=INK2)
    box(ax, 27, 7, 13, 11, "Envoy", color=ROUTER)
    box(ax, 47, 7, 20, 11, "EPP + our scorer\nmakes the decision", color=ROUTER)
    box(ax, 76, 7, 16, 11, "vLLM servers", color=INK2)
    arrow(ax, (20.4, 12.5), (26.6, 12.5))
    arrow(ax, (40.4, 12.5), (46.6, 12.5), both=True)
    arrow(ax, (67.4, 12.5), (75.6, 12.5))
    note(ax, 27, 5.6, "Measured cost of this path (job 12321497): +1.2 to +2.4 ms median "
         "time to first token; EPP decision about 0.2 ms.", width=80)
    save(fig, "d2_routing_paths_stage2_vs_stage5")


# ------------------------------------------------------------------ D3
def d3_decision():
    fig, ax, top = canvas(13, 8.4, "How a packing policy picks an endpoint (current design)",
                          "slo_packing, energy_greedy and energy_consolidate share the "
                          "feasibility test; they differ only in the final choice.", top=111)
    box(ax, 38, 92, 24, 7, "Request arrives\nfor each endpoint i: n_i in flight", color=INK2)
    box(ax, 6, 76, 26, 9, "1. Cap\nn_i + 1 > 256 ?\n(vLLM --max-num-seqs)", color=WARN)
    box(ax, 37, 76, 26, 9, "2. Curve range\nn_i + 1 beyond the curve's\nstationary rates ?", color=WARN)
    box(ax, 68, 76, 27, 9, "3. Latency target\nmeasured p95(n_i + 1)\n> (1 - h) x 2.0 s ?", color=WARN)
    arrow(ax, (50, 91.6), (19, 85.4))
    arrow(ax, (50, 91.6), (50, 85.4))
    arrow(ax, (50, 91.6), (81.5, 85.4))
    box(ax, 23, 62, 54, 8, "Any 'yes': endpoint i is infeasible for this request\n"
        "all three tests 'no': i is in the feasible set F", color=LINE)
    for x in (19, 50, 81.5):
        arrow(ax, (x, 75.6), (min(max(x, 26), 74), 70.4))
    box(ax, 2, 40, 30, 15, "F is empty\nfall back to least_loaded\ncounted: 'saturated' if the curve\n"
        "answered, 'ungrounded' if no endpoint\nhad data (> 2% ungrounded = invalid cell)",
        color=PENDING, size=7.8)
    arrow(ax, (40, 61.6), (20, 55.4), "F empty", off=(-3, 0))
    arrow(ax, (60, 61.6), (68, 55.4), "F not empty", off=(3, 0))
    box(ax, 40, 34, 57, 21, "Choose from F\n"
        "slo_packing: the busiest feasible endpoint (pack; energy-blind)\n"
        "energy_greedy: lowest J/token at n_i + 1\n"
        "energy_consolidate: busy endpoints first; wake an idle one\n"
        "    only if no busy endpoint is feasible; then lowest J/token\n"
        "J/token = power(n+1) / tokens_per_s(n+1), from the curve",
        color=ROUTER, fill="#f2f7fd", size=8.2, align="left")
    box(ax, 2, 4, 95, 13, "What changed on 2026-10-09 and why\n"
        "Before: test 3 used projected MEAN latency from a closed-loop curve, aimed exactly at "
        "2.0 s (h = 0), with no cap.\n"
        "Audit: on one GPU type packers ran ON the 2.0 s line (30-83% met). Calibration v1: "
        "on the mixed fleet, Poisson arrivals queued\n"
        "behind vLLM's 256 limit (TTFT p50 1.44 s vs 0.05 s). Now: p95 from an OPEN-LOOP curve, "
        "a declared headroom h, and the cap (plan 12.14d).",
        color=MEASURE, size=7.8, align="left")
    save(fig, "d3_packing_decision")


# ------------------------------------------------------------------ D4
def d4_curves():
    fig, ax, top = canvas(13, 6.6, "Measuring a GPU type: closed loop versus open loop",
                          "Why the router's latency model changed (approach A, author's "
                          "decision 2026-10-09)", top=64)
    box(ax, 2, 30, 46, 46 * 0 + 24, "Closed loop  (h1_sweep, Stage 1 to 2026-10-09)\n"
        "c clients; each sends its next request when the last one ends\n"
        "-> exactly c in flight, always; no arrival bursts\n"
        "-> p50 ~ p95; the queue for a vLLM slot is never seen\n"
        "Evidence it misleads above 256 (h1-12325153, A100):\n"
        "   c=384: measured p50 1.63 s, projection 2.01 s; vLLM\n"
        "   ran 256 and queued the rest", color=PENDING, size=8, align="left")
    box(ax, 52, 30, 46, 24, "Open loop  (openloop_curve.sbatch, from 2026-10-09)\n"
        "Poisson arrivals at a fixed rate, whatever finishes\n"
        "-> in flight fluctuates; mean in-flight L = rate x mean latency\n"
        "-> p95 latency includes bursts and slot queueing\n"
        "This is what the router faces in Stages 2 and 5;\n"
        "the router now reads p95 at the next in-flight level", color=DONE, size=8, align="left")
    box(ax, 2, 4, 96, 20, "What exposed it  (calibration v1 on closed-loop curves, records 0ad7dee)\n"
        "Mixed fleet: packers put all load on three A100s and none on the RTX 6000s; median TTFT "
        "1.44 s at h = 0, 0.55 s at h = 0.3,\n"
        "against 0.05 s in Stage 2. The load generator was ruled out (about 4 cores, send-delay "
        "p99 1 ms).\n"
        "Rejected alternative (B): keep closed-loop curves and tune a cap below 256 - a second "
        "parameter tuned on pilot data, still blind to queueing.",
        color=MEASURE, size=8, align="left")
    save(fig, "d4_curve_measurement_closed_vs_open")


# ------------------------------------------------------------------ D5
def d5_timeline():
    fig, ax, top = canvas(13, 9.2, "Checkpoints: what was found, and what was decided",
                          "Each finding changed the design before the next measurement. "
                          "Full record: docs/plan/FINAL-PLAN-2026-10.md and "
                          "docs/plan/CHECKPOINT-2026-10-09.md.", top=82)
    rows = [
        ("May-Jun 2026", "First design, evaluated by simulation only", PENDING,
         "Proposal PDF and drafts; chapter 5 synthetic. Kept in legacy/, labelled."),
        ("2026-10-03", "Rescope; Stage 1 measured on Frontenac", DONE,
         "Active power near-constant over a 32x load range; TDP proxy refuted."),
        ("2026-10-04..07", "Stage 2: rule inside the load generator", DONE,
         "Mixed fleet: energy_consolidate +1.4% over slo_packing, 3 of 3 trials."),
        ("2026-10-08", "Figures rebuilt from records; old figures synthetic", WARN,
         "fig1-16 traced to 'Production-Grade Synthetic Telemetry'. ITL claim corrected."),
        ("2026-10-09", "Pre-registration v1 frozen (prereg-stage5-v1)", DONE,
         "H1-H3, 16 + 6 trials from a power analysis."),
        ("2026-10-09", "Audit: unequal binding constraints", WARN,
         "Mixed fleet capped by the A100 curve edge (c=128); one-type fleet aimed AT 2.0 s."),
        ("2026-10-09", "Fix: headroom h + matched curves; rule committed first", DONE,
         "Author: 25 + 25 Stage 5 trials, 6-trial curves, A100 to 512, 3 seeds."),
        ("2026-10-09", "Calibration v1 (closed-loop curves): no h qualified", WARN,
         "One-type fleet solved from h=0.1. Mixed: queueing at vLLM's 256 limit."),
        ("2026-10-09", "Approach A: open-loop curves, p95, cap 256; rule v3", DONE,
         "vLLM limits pinned (256 / 2048). Smoke 12325343 before full runs."),
        ("next", "Open-loop curves -> calibration v3 -> amendment (prereg-stage5-v2)", PENDING,
         "Then Stage 4 (Go scorers + fidelity test) and Stage 5."),
    ]
    y = top - 12
    # Markers, not Circle patches: the canvas is not 1:1 in data units, so a
    # Circle would draw as an ellipse.
    ax.plot([16.5, 16.5], [y - 6.3 * (len(rows) - 1), y + 2], color=GRID, lw=2, zorder=0)
    for when, what, col, detail in rows:
        ax.plot([16.5], [y], marker="o", ms=11, color=col, zorder=2)
        ax.text(14.6, y, when, ha="right", va="center", fontsize=8.2, color=INK2)
        ax.text(18.8, y + 0.9, what, va="center", fontsize=8.8, color=INK, weight="bold")
        ax.text(18.8, y - 2.0, detail, va="center", fontsize=7.8, color=INK2)
        y -= 6.3
    for i, (lab, col) in enumerate((("done / held", DONE), ("problem found", WARN),
                                    ("superseded or pending", PENDING))):
        ax.plot([60 + i * 12], [top - 9.5], marker="o", ms=9, color=col)
        ax.text(61.2 + i * 12, top - 9.5, lab, va="center", fontsize=7.5, color=INK2)
    save(fig, "d5_checkpoints_timeline")


# ------------------------------------------------------------------ D6
def d6_stage5():
    fig, ax, top = canvas(13, 7.4, "Stage 5 design (pre-registration v1 + amendment draft)",
                          "Frozen before any Stage 5 trial. Values marked * come from the "
                          "amendment and are final only at tag prereg-stage5-v2.", top=72)
    box(ax, 2, 42, 30, 20, "Fleets (nodes pinned)\nmixed: 4x A100 (frnt154)\n"
        "         + 4x RTX 6000 (frnt149)\none type: 8x RTX 6000 (frnt155)\n"
        "trials: 25 + 25 *", color=INK2, align="left")
    box(ax, 35, 42, 30, 20, "Arms (all through llm-d)\nenergy_consolidate (ours)\n"
        "energy_greedy (ablation)\nslo_packing, round_robin\nrandom, stock llm-d,\n"
        "llm-d latency-scorer 'least' *", color=ROUTER, align="left")
    box(ax, 68, 42, 30, 20, "Outcome\nSLO-goodput per joule\n(= 1 / energy per SLO-met request)\n"
        "at each arm's best load with\n>= 95% of requests within 2.0 s\nGPU-package energy only",
        color=MEASURE, align="left")
    box(ax, 2, 15, 96, 22, "Hypotheses  (one-sided alpha 0.025)\n"
        "H1, primary: on the mixed fleet, energy_consolidate beats slo_packing  "
        "(t-test on per-trial margins)\n"
        "H2: on the one-type fleet, energy_consolidate does not beat round_robin  "
        "(exact sign test)\n"
        "H3: on the mixed fleet, energy_consolidate beats energy_greedy, isolating "
        "the activation rule  (t-test)\n"
        "H4 *: on the mixed fleet, energy_consolidate beats llm-d's latency-scorer  (t-test)\n"
        "H2, H3 and H4 form one family, Holm-corrected; H1 is tested alone",
        color=DONE, size=8, align="left")
    box(ax, 2, 2, 96, 9, "Order of events\nprereg-stage5-v1 (tagged) -> audit -> calibration v3 -> "
        "amendment, tag prereg-stage5-v2 -> Stage 4 builds the arms; materials addendum tagged -> "
        "trial 1", color=PENDING, size=8, align="left")
    save(fig, "d6_stage5_design")


# ------------------------------------------------------------------ D7
def d7_provenance():
    fig, ax, top = canvas(13, 5.4, "Data provenance: from a GPU to a published number",
                          "Every number in the README, plan or a figure traces back along "
                          "these arrows. Nothing is deleted; superseded data is labelled.", top=42)
    xs = [2, 22, 42, 62, 82]
    texts = ["Slurm job on Frontenac\nnode pinned, --exclusive\ninstruments.txt recorded",
             "fr-fetchall.sh\nrsync to the repo;\nprepare_records.sh\ngzips logs > 1 MiB",
             "experiments/\ncluster-records/\ncommitted and pushed\n(archive tags)",
             "Analysis scripts\nstage2_analyse,\nprereg_analysis,\nheadroom_calibrate,\nmake_figures",
             "docs/figures/measured/\nPNG + CSV of the exact\nplotted numbers;\nREADME and plan"]
    cols = [INK2, INK2, MEASURE, ROUTER, DONE]
    for x, t, c in zip(xs, texts, cols):
        box(ax, x, 12, 16, 18, t, color=c, size=8)
    for a, b in zip(xs, xs[1:]):
        arrow(ax, (a + 16.5, 21), (b - 0.5, 21))
    note(ax, 2, 9.5, "Checks along the way: verify_fixes.sh before every submission "
         "(53/53 on 2026-10-09); decision rules committed before their data; CI regenerates "
         "the figures and fails if any plotted CSV changes.", width=150)
    save(fig, "d7_data_provenance")


def main():
    for f in (d1_architecture, d2_paths, d3_decision, d4_curves, d5_timeline, d6_stage5,
              d7_provenance):
        f()
    print("diagrams written to", OUT)


if __name__ == "__main__":
    main()
