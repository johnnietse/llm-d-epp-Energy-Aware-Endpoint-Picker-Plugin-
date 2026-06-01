#!/usr/bin/env python3
"""
generate_figures.py - Thesis-quality figures from realistic heterogeneous data.

Produces 6 publication-ready figures for the upstream PR evidence section:
  Fig 1: Power vs Utilization (all 4 GPUs)
  Fig 2: Energy per Token vs RPS (efficiency crossover)
  Fig 3: Tokens/Watt comparison bar chart
  Fig 4: Latency vs Throughput tradeoff
  Fig 5: Power time series with thermal throttle visible
  Fig 6: Energy savings waterfall chart
"""

import os, json, csv, glob
import matplotlib
matplotlib.use('Agg')  # Non-interactive backend
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np

DATA_DIR = os.path.join("benchmarks", "results", "frontenac", "heterogeneous_realistic")
FIG_DIR = os.path.join("docs", "figures")
os.makedirs(FIG_DIR, exist_ok=True)

# Ontario grid carbon intensity
CARBON_gCO2_kWh = 30
ELEC_CAD_kWh = 0.12

# Colors matching GPU branding
COLORS = {
    "a100_full": "#76B900",   # NVIDIA green
    "a100_capped": "#8BC34A", # Lighter green
    "h100_full": "#1A237E",   # Deep blue
    "l4_full": "#FF6F00",     # Orange
}
LABELS = {
    "a100_full": "A100 (400W)",
    "a100_capped": "A100 (250W cap)",
    "h100_full": "H100 (700W)",
    "l4_full": "L4 (72W)",
}
GPU_ORDER = ["a100_full", "a100_capped", "h100_full", "l4_full"]
RPS_LIST = [1, 2, 3, 5, 8, 10, 15, 20, 30, 50]

plt.rcParams.update({
    'font.family': 'sans-serif',
    'font.size': 11,
    'axes.titlesize': 13,
    'axes.labelsize': 12,
    'legend.fontsize': 9,
    'figure.dpi': 150,
    'savefig.dpi': 200,
})

def load_rps_data(gpu_key):
    """Load all per-RPS JSON files for a GPU."""
    results = {}
    for rps in RPS_LIST:
        path = os.path.join(DATA_DIR, gpu_key, f"load_rps_{rps}.json")
        if os.path.exists(path):
            with open(path) as f:
                results[rps] = json.load(f)
    return results

def load_timeseries(gpu_key):
    """Load power time series CSV."""
    path = os.path.join(DATA_DIR, gpu_key, "power_timeseries.csv")
    times, powers, utils, temps = [], [], [], []
    with open(path) as f:
        reader = csv.DictReader(f)
        for i, row in enumerate(reader):
            times.append(i * 2)  # seconds
            powers.append(float(row["power_w"]))
            utils.append(float(row["gpu_util"]))
            temps.append(float(row["temperature"]))
    return times, powers, utils, temps

print("Generating thesis-quality figures...")

# =====================================================================
# Fig 1: Power vs Throughput (all GPUs)
# =====================================================================
fig, ax = plt.subplots(figsize=(9, 5.5))
for gk in GPU_ORDER:
    data = load_rps_data(gk)
    tps_vals = [data[r]["tokens_per_sec"] for r in RPS_LIST if r in data]
    pw_vals = [data[r]["power_watts"] for r in RPS_LIST if r in data]
    ax.plot(tps_vals, pw_vals, 'o-', color=COLORS[gk], label=LABELS[gk],
            markersize=5, linewidth=1.8)

ax.set_xlabel("Throughput (tokens/sec)")
ax.set_ylabel("Power Draw (W)")
ax.set_title("Power vs Throughput - Heterogeneous GPU Cluster")
ax.legend(loc='upper left')
ax.grid(True, alpha=0.3)
ax.set_xlim(left=0)
ax.set_ylim(bottom=0)
fig.savefig(os.path.join(FIG_DIR, "fig1_power_vs_throughput.png"))
plt.close()
print("  [1/6] Power vs Throughput")

# =====================================================================
# Fig 2: Energy per Token vs RPS (efficiency crossover)
# =====================================================================
fig, ax = plt.subplots(figsize=(9, 5.5))
for gk in GPU_ORDER:
    data = load_rps_data(gk)
    rps_vals = [r for r in RPS_LIST if r in data]
    ept_vals = [data[r]["energy_per_token_mj"] for r in rps_vals]
    ax.plot(rps_vals, ept_vals, 's-', color=COLORS[gk], label=LABELS[gk],
            markersize=5, linewidth=1.8)

ax.set_xlabel("Request Rate (RPS)")
ax.set_ylabel("Energy per Token (mJ)")
ax.set_title("Energy Efficiency vs Load - Lower is Better")
ax.legend()
ax.grid(True, alpha=0.3)
ax.set_xscale('log')
ax.xaxis.set_major_formatter(ticker.ScalarFormatter())
ax.set_xticks(RPS_LIST)
fig.savefig(os.path.join(FIG_DIR, "fig2_energy_per_token.png"))
plt.close()
print("  [2/6] Energy per Token vs RPS")

# =====================================================================
# Fig 3: Tokens/Watt Bar Chart (@ 10 RPS)
# =====================================================================
fig, ax = plt.subplots(figsize=(8, 5))
labels = [LABELS[gk] for gk in GPU_ORDER]
tokw = []
for gk in GPU_ORDER:
    data = load_rps_data(gk)
    r = data[10]
    tokw.append(r["tokens_per_sec"] / r["power_watts"])

bars = ax.bar(labels, tokw, color=[COLORS[gk] for gk in GPU_ORDER],
              edgecolor='white', linewidth=1.5)
ax.set_ylabel("Tokens per Watt")
ax.set_title("Energy Efficiency @ 10 RPS - Higher is Better")
ax.grid(axis='y', alpha=0.3)
for bar, val in zip(bars, tokw):
    ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 0.05,
            f'{val:.2f}', ha='center', va='bottom', fontsize=10, fontweight='bold')
fig.savefig(os.path.join(FIG_DIR, "fig3_tokens_per_watt.png"))
plt.close()
print("  [3/6] Tokens/Watt Bar Chart")

# =====================================================================
# Fig 4: Latency vs Throughput Tradeoff
# =====================================================================
fig, ax = plt.subplots(figsize=(9, 5.5))
for gk in GPU_ORDER:
    data = load_rps_data(gk)
    tps_vals = [data[r]["tokens_per_sec"] for r in RPS_LIST if r in data]
    p99_vals = [data[r]["latency_p99_ms"] for r in RPS_LIST if r in data]
    ax.plot(tps_vals, p99_vals, '^-', color=COLORS[gk], label=LABELS[gk],
            markersize=5, linewidth=1.8)

ax.set_xlabel("Throughput (tokens/sec)")
ax.set_ylabel("p99 Latency (ms)")
ax.set_title("Latency-Throughput Tradeoff (p99)")
ax.legend()
ax.grid(True, alpha=0.3)
ax.axhline(y=3000, color='red', linestyle='--', alpha=0.5, label='SLO Target')
ax.set_xlim(left=0)
fig.savefig(os.path.join(FIG_DIR, "fig4_latency_throughput.png"))
plt.close()
print("  [4/6] Latency vs Throughput")

# =====================================================================
# Fig 5: Power Time Series (A100 full - shows thermal throttle & glitches)
# =====================================================================
fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 7), sharex=True)

times, powers, utils, temps = load_timeseries("a100_full")
t_min = [t/60 for t in times]

ax1.plot(t_min, powers, color=COLORS["a100_full"], linewidth=0.6, alpha=0.8)
ax1.axhline(y=400, color='red', linestyle='--', alpha=0.4, linewidth=1)
ax1.set_ylabel("Power (W)")
ax1.set_title("A100-400W Power Time Series (nvidia-smi, 2s intervals)")
ax1.grid(True, alpha=0.2)
ax1.annotate('TDP = 400W', xy=(t_min[-1]*0.85, 405), color='red', fontsize=9)
# Mark glitches
glitch_t = [t_min[i] for i, p in enumerate(powers) if p == 0]
glitch_p = [0] * len(glitch_t)
if glitch_t:
    ax1.scatter(glitch_t, glitch_p, color='red', marker='x', s=40, zorder=5,
                label=f'Sensor glitches ({len(glitch_t)})')
    ax1.legend(loc='upper right')

ax2.plot(t_min, temps, color='#E65100', linewidth=0.6, alpha=0.8)
ax2.axhline(y=83, color='red', linestyle='--', alpha=0.4, linewidth=1)
ax2.set_xlabel("Time (minutes)")
ax2.set_ylabel("Temperature (C)")
ax2.grid(True, alpha=0.2)
ax2.annotate('Throttle zone', xy=(t_min[-1]*0.85, 84), color='red', fontsize=9)

fig.tight_layout()
fig.savefig(os.path.join(FIG_DIR, "fig5_power_timeseries.png"))
plt.close()
print("  [5/6] Power Time Series")

# =====================================================================
# Fig 6: Energy Savings Waterfall
# =====================================================================
fig, ax = plt.subplots(figsize=(9, 5.5))

# Compute kWh/1M tokens for each GPU at 10 RPS
kwh_data = {}
for gk in GPU_ORDER:
    data = load_rps_data(gk)
    r = data[10]
    kwh = r["energy_per_token_mj"] * 1e6 / 1e3 / 3600
    kwh_data[gk] = kwh

baseline = kwh_data["a100_full"]
savings_pct = {gk: (1 - kwh_data[gk]/baseline)*100 for gk in GPU_ORDER}

x = np.arange(len(GPU_ORDER))
bars = ax.bar(x, [kwh_data[gk] for gk in GPU_ORDER],
              color=[COLORS[gk] for gk in GPU_ORDER],
              edgecolor='white', linewidth=1.5)
ax.set_xticks(x)
ax.set_xticklabels([LABELS[gk] for gk in GPU_ORDER], rotation=15, ha='right')
ax.set_ylabel("kWh per 1M Tokens")
ax.set_title("Energy Cost per 1M Tokens @ 10 RPS")
ax.grid(axis='y', alpha=0.3)

for i, (bar, gk) in enumerate(zip(bars, GPU_ORDER)):
    val = kwh_data[gk]
    pct = savings_pct[gk]
    label = f'{val:.1f}\n({pct:+.1f}%)' if pct != 0 else f'{val:.1f}\n(baseline)'
    ax.text(bar.get_x() + bar.get_width()/2, bar.get_height() + 1,
            label, ha='center', va='bottom', fontsize=9, fontweight='bold')

fig.savefig(os.path.join(FIG_DIR, "fig6_energy_savings.png"))
plt.close()
print("  [6/6] Energy Savings Waterfall")

# =====================================================================
# LaTeX-ready summary table
# =====================================================================
print("\n" + "=" * 70)
print("  LaTeX Table: Heterogeneous Cluster Energy Profile @ 10 RPS")
print("=" * 70)
TDP_MAP = {"a100_full": 400, "a100_capped": 250, "h100_full": 700, "l4_full": 72}

print(r"\begin{tabular}{lrrrrrr}")
print(r"\hline")
print(r"GPU & TDP & TPS & Power & EPT (mJ) & Tok/W & kWh/1M \\")
print(r"\hline")
for gk in GPU_ORDER:
    data = load_rps_data(gk)[10]
    tw = data["tokens_per_sec"] / data["power_watts"]
    kwh = kwh_data[gk]
    print(f"{LABELS[gk]:18s} & {TDP_MAP[gk]}W & "
          f"{data['tokens_per_sec']:.1f} & {data['power_watts']:.1f}W & "
          f"{data['energy_per_token_mj']:.1f} & {tw:.2f} & {kwh:.1f} \\\\")
print(r"\hline")
print(r"\end{tabular}")

print(f"\nFigures saved to: {FIG_DIR}/")
print("Done!")
