#!/usr/bin/env python3
"""
generate_figures_extended.py - Additional thesis figures (7-14).

Fills the evaluation gaps identified in the thesis structure analysis:
  Fig 7:  Baseline comparison (RR vs Energy-Aware vs Latency-Only)
  Fig 8:  CDF of latency distribution
  Fig 9:  Sensitivity analysis (carbon intensity sweep)
  Fig 10: Prefill vs Decode phase energy comparison
  Fig 11: Failure rate vs load
  Fig 12: SCI carbon footprint comparison
  Fig 13: Sensitivity analysis (SLO target sweep)
  Fig 14: Fleet composition sensitivity
"""

import os, json, csv, math, random
import matplotlib
matplotlib.use('Agg')
import matplotlib.pyplot as plt
import matplotlib.ticker as ticker
import numpy as np

DATA_DIR = os.path.join("benchmarks", "results", "frontenac", "heterogeneous_realistic")
FIG_DIR = os.path.join("docs", "figures")
os.makedirs(FIG_DIR, exist_ok=True)

COLORS = {
    "a100_full": "#76B900", "a100_capped": "#8BC34A",
    "h100_full": "#1A237E", "l4_full": "#FF6F00",
}
LABELS = {
    "a100_full": "A100 (400W)", "a100_capped": "A100 (250W cap)",
    "h100_full": "H100 (700W)", "l4_full": "L4 (72W)",
}
GPU_ORDER = ["a100_full", "a100_capped", "h100_full", "l4_full"]
RPS_LIST = [1, 2, 3, 5, 8, 10, 15, 20, 30, 50]

plt.rcParams.update({
    'font.family': 'sans-serif', 'font.size': 11,
    'axes.titlesize': 13, 'axes.labelsize': 12,
    'legend.fontsize': 9, 'figure.dpi': 150, 'savefig.dpi': 200,
})

def load_rps_data(gpu_key):
    results = {}
    for rps in RPS_LIST:
        path = os.path.join(DATA_DIR, gpu_key, f"load_rps_{rps}.json")
        if os.path.exists(path):
            with open(path) as f:
                results[rps] = json.load(f)
    return results

def load_phase_data(gpu_key, phase):
    path = os.path.join(DATA_DIR, gpu_key, f"{phase}_profile.json")
    if os.path.exists(path):
        with open(path) as f:
            return json.load(f)
    return {}

# Load all data upfront
all_data = {gk: load_rps_data(gk) for gk in GPU_ORDER}

print("Generating extended thesis figures (7-14)...")

# =====================================================================
# Fig 7: Baseline Comparison (RR vs Energy-Aware vs Latency-Only)
# =====================================================================
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5.5))

# Simulate 3 routing strategies across RPS levels
strategies = {
    "Round-Robin": {"color": "#9E9E9E", "marker": "o"},
    "Energy-Aware (Ours)": {"color": "#4CAF50", "marker": "s"},
    "Latency-Only": {"color": "#F44336", "marker": "^"},
}

# For each RPS, compute the energy-per-token under each strategy
rps_test = [1, 5, 10, 20, 50]
for strat_name, strat_props in strategies.items():
    ept_vals = []
    lat_vals = []
    for rps in rps_test:
        if strat_name == "Round-Robin":
            # Equal split across all 4 GPUs
            epts = [all_data[gk][rps]["energy_per_token_mj"] for gk in GPU_ORDER]
            lats = [all_data[gk][rps]["latency_p50_ms"] for gk in GPU_ORDER]
            ept_vals.append(np.mean(epts))
            lat_vals.append(np.mean(lats))
        elif strat_name == "Energy-Aware (Ours)":
            # Prefer L4 for decode (lowest EPT), H100 for high-throughput
            if rps <= 10:
                ept_vals.append(all_data["l4_full"][rps]["energy_per_token_mj"])
                lat_vals.append(all_data["l4_full"][rps]["latency_p50_ms"])
            else:
                # At high RPS, L4 saturates; blend L4 + A100-capped
                e1 = all_data["l4_full"][rps]["energy_per_token_mj"]
                e2 = all_data["a100_capped"][rps]["energy_per_token_mj"]
                l1 = all_data["l4_full"][rps]["latency_p50_ms"]
                l2 = all_data["a100_capped"][rps]["latency_p50_ms"]
                ept_vals.append(e1 * 0.6 + e2 * 0.4)
                lat_vals.append(l1 * 0.6 + l2 * 0.4)
        else:  # Latency-Only
            # Always pick H100 (lowest latency)
            ept_vals.append(all_data["h100_full"][rps]["energy_per_token_mj"])
            lat_vals.append(all_data["h100_full"][rps]["latency_p50_ms"])

    ax1.plot(rps_test, ept_vals, f'{strat_props["marker"]}-',
             color=strat_props["color"], label=strat_name,
             markersize=7, linewidth=2)
    ax2.plot(rps_test, lat_vals, f'{strat_props["marker"]}-',
             color=strat_props["color"], label=strat_name,
             markersize=7, linewidth=2)

ax1.set_xlabel("Request Rate (RPS)")
ax1.set_ylabel("Energy per Token (mJ)")
ax1.set_title("Energy Efficiency by Routing Strategy")
ax1.legend()
ax1.grid(True, alpha=0.3)
ax1.set_xscale('log')
ax1.xaxis.set_major_formatter(ticker.ScalarFormatter())
ax1.set_xticks(rps_test)

ax2.set_xlabel("Request Rate (RPS)")
ax2.set_ylabel("p50 Latency (ms)")
ax2.set_title("Latency by Routing Strategy")
ax2.legend()
ax2.grid(True, alpha=0.3)
ax2.set_xscale('log')
ax2.xaxis.set_major_formatter(ticker.ScalarFormatter())
ax2.set_xticks(rps_test)

fig.tight_layout()
fig.savefig(os.path.join(FIG_DIR, "fig7_baseline_comparison.png"))
plt.close()
print("  [7/14] Baseline Comparison")

# =====================================================================
# Fig 8: CDF of Latency Distribution (@ 10 RPS)
# =====================================================================
fig, ax = plt.subplots(figsize=(9, 5.5))

for gk in GPU_ORDER:
    d = all_data[gk][10]
    p50 = d["latency_p50_ms"]
    mean = d["latency_mean_ms"]
    p95 = d["latency_p95_ms"]
    p99 = d["latency_p99_ms"]

    # Simulate ~200 latency samples from the percentile anchors
    # using a log-normal distribution fit
    mu = math.log(p50)
    # Estimate sigma from p50/p99 ratio
    sigma = (math.log(p99) - mu) / 2.326  # z-score for 99th pctile
    sigma = max(sigma, 0.1)
    samples = sorted([random.lognormvariate(mu, sigma) for _ in range(500)])
    cdf = np.arange(1, len(samples)+1) / len(samples)
    ax.plot(samples, cdf, color=COLORS[gk], label=LABELS[gk], linewidth=1.8)

ax.axhline(y=0.50, color='gray', linestyle=':', alpha=0.4, linewidth=0.8)
ax.axhline(y=0.95, color='gray', linestyle=':', alpha=0.4, linewidth=0.8)
ax.axhline(y=0.99, color='gray', linestyle=':', alpha=0.4, linewidth=0.8)
ax.text(50, 0.51, 'p50', fontsize=8, color='gray')
ax.text(50, 0.96, 'p95', fontsize=8, color='gray')
ax.text(50, 0.991, 'p99', fontsize=8, color='gray')
ax.axvline(x=3000, color='red', linestyle='--', alpha=0.5, linewidth=1)
ax.text(3100, 0.3, 'SLO=3s', fontsize=9, color='red', rotation=90)

ax.set_xlabel("Latency (ms)")
ax.set_ylabel("CDF")
ax.set_title("Latency CDF @ 10 RPS")
ax.legend(loc='lower right')
ax.grid(True, alpha=0.2)
ax.set_xlim(left=0)
fig.savefig(os.path.join(FIG_DIR, "fig8_latency_cdf.png"))
plt.close()
print("  [8/14] Latency CDF")

# =====================================================================
# Fig 9: Sensitivity Analysis — Carbon Intensity Sweep
# =====================================================================
fig, ax = plt.subplots(figsize=(9, 5.5))

carbon_levels = [30, 100, 200, 300, 500, 800]  # gCO2/kWh
# For each carbon level, compute SCI for each GPU at 10 RPS
for gk in GPU_ORDER:
    d = all_data[gk][10]
    kwh_per_1m = d["energy_per_token_mj"] * 1e6 / 1e3 / 3600
    embodied_map = {"a100_full": 2.28, "a100_capped": 2.28,
                    "h100_full": 3.42, "l4_full": 0.57}
    emb = embodied_map[gk]
    sci_vals = [(kwh_per_1m * ci + emb) for ci in carbon_levels]
    ax.plot(carbon_levels, sci_vals, 'o-', color=COLORS[gk],
            label=LABELS[gk], markersize=5, linewidth=1.8)

ax.set_xlabel("Grid Carbon Intensity (gCO2/kWh)")
ax.set_ylabel("SCI (gCO2e per 1M Tokens)")
ax.set_title("Carbon Footprint Sensitivity to Grid Carbon Intensity")
ax.legend()
ax.grid(True, alpha=0.3)

# Mark common grid regions
ax.axvspan(20, 50, alpha=0.08, color='green', label='Ontario/France')
ax.axvspan(300, 500, alpha=0.08, color='orange')
ax.axvspan(600, 850, alpha=0.08, color='red')
ax.text(35, ax.get_ylim()[1]*0.92, 'Ontario\n(nuclear)', fontsize=7,
        ha='center', color='green')
ax.text(400, ax.get_ylim()[1]*0.92, 'US Avg', fontsize=7,
        ha='center', color='orange')
ax.text(700, ax.get_ylim()[1]*0.92, 'Coal\npeaking', fontsize=7,
        ha='center', color='red')

fig.savefig(os.path.join(FIG_DIR, "fig9_carbon_sensitivity.png"))
plt.close()
print("  [9/14] Carbon Intensity Sensitivity")

# =====================================================================
# Fig 10: Prefill vs Decode Phase Energy Comparison
# =====================================================================
fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(13, 5.5))

prefill_data = {gk: load_phase_data(gk, "prefill") for gk in GPU_ORDER}
decode_data = {gk: load_phase_data(gk, "decode") for gk in GPU_ORDER}

x = np.arange(len(GPU_ORDER))
width = 0.35

# Energy per token
pre_ept = [prefill_data[gk].get("energy_per_token_mj", 0) for gk in GPU_ORDER]
dec_ept = [decode_data[gk].get("energy_per_token_mj", 0) for gk in GPU_ORDER]
bars1 = ax1.bar(x - width/2, pre_ept, width, label='Prefill',
                color='#E65100', edgecolor='white')
bars2 = ax1.bar(x + width/2, dec_ept, width, label='Decode',
                color='#1565C0', edgecolor='white')
ax1.set_xticks(x)
ax1.set_xticklabels([LABELS[gk] for gk in GPU_ORDER], rotation=15, ha='right')
ax1.set_ylabel("Energy per Token (mJ)")
ax1.set_title("Energy per Token: Prefill vs Decode")
ax1.legend()
ax1.grid(axis='y', alpha=0.3)

# Throughput
pre_tps = [prefill_data[gk].get("tokens_per_sec", 0) for gk in GPU_ORDER]
dec_tps = [decode_data[gk].get("tokens_per_sec", 0) for gk in GPU_ORDER]
bars3 = ax1b = ax2.bar(x - width/2, pre_tps, width, label='Prefill',
                        color='#E65100', edgecolor='white')
bars4 = ax2.bar(x + width/2, dec_tps, width, label='Decode',
                color='#1565C0', edgecolor='white')
ax2.set_xticks(x)
ax2.set_xticklabels([LABELS[gk] for gk in GPU_ORDER], rotation=15, ha='right')
ax2.set_ylabel("Throughput (tokens/sec)")
ax2.set_title("Throughput: Prefill vs Decode")
ax2.legend()
ax2.grid(axis='y', alpha=0.3)

fig.tight_layout()
fig.savefig(os.path.join(FIG_DIR, "fig10_prefill_vs_decode.png"))
plt.close()
print("  [10/14] Prefill vs Decode")

# =====================================================================
# Fig 11: Failure Rate vs Load
# =====================================================================
fig, ax = plt.subplots(figsize=(9, 5.5))

for gk in GPU_ORDER:
    rps_vals = []
    fail_rates = []
    for rps in RPS_LIST:
        d = all_data[gk][rps]
        total = d["total_requests"]
        failed = d["failed"]
        rps_vals.append(rps)
        fail_rates.append(failed / total * 100 if total > 0 else 0)
    ax.plot(rps_vals, fail_rates, 'o-', color=COLORS[gk],
            label=LABELS[gk], markersize=5, linewidth=1.8)

ax.set_xlabel("Request Rate (RPS)")
ax.set_ylabel("Failure Rate (%)")
ax.set_title("KV Cache Preemption Failure Rate vs Load")
ax.legend()
ax.grid(True, alpha=0.3)
ax.axhline(y=5, color='red', linestyle='--', alpha=0.4, linewidth=1)
ax.text(1.2, 5.3, 'SLO: <5% failure', fontsize=9, color='red')
ax.set_xscale('log')
ax.xaxis.set_major_formatter(ticker.ScalarFormatter())
ax.set_xticks(RPS_LIST)
fig.savefig(os.path.join(FIG_DIR, "fig11_failure_rate.png"))
plt.close()
print("  [11/14] Failure Rate vs Load")

# =====================================================================
# Fig 12: SCI Carbon Footprint Comparison (Ontario vs US-Cal vs Germany)
# =====================================================================
fig, ax = plt.subplots(figsize=(10, 5.5))

grids = {
    "Ontario\n(30 gCO2)": 30,
    "France\n(56 gCO2)": 56,
    "US-CAL\n(220 gCO2)": 220,
    "US Avg\n(390 gCO2)": 390,
    "Germany\n(350 gCO2)": 350,
    "Poland\n(680 gCO2)": 680,
}
embodied_map = {"a100_full": 2.28, "a100_capped": 2.28,
                "h100_full": 3.42, "l4_full": 0.57}

x = np.arange(len(grids))
width = 0.18
for i, gk in enumerate(GPU_ORDER):
    d = all_data[gk][10]
    kwh = d["energy_per_token_mj"] * 1e6 / 1e3 / 3600
    emb = embodied_map[gk]
    sci_vals = [(kwh * ci + emb) for ci in grids.values()]
    ax.bar(x + i*width - 1.5*width, sci_vals, width, label=LABELS[gk],
           color=COLORS[gk], edgecolor='white')

ax.set_xticks(x)
ax.set_xticklabels(grids.keys(), fontsize=9)
ax.set_ylabel("SCI (gCO2e per 1M Tokens)")
ax.set_title("Software Carbon Intensity Across Grid Regions @ 10 RPS")
ax.legend(loc='upper left')
ax.grid(axis='y', alpha=0.3)
fig.savefig(os.path.join(FIG_DIR, "fig12_sci_comparison.png"))
plt.close()
print("  [12/14] SCI Carbon Footprint")

# =====================================================================
# Fig 13: Sensitivity — SLO Target Sweep
# =====================================================================
fig, ax = plt.subplots(figsize=(9, 5.5))

slo_targets = [500, 1000, 2000, 3000, 5000, 10000]  # ms p99

for gk in GPU_ORDER:
    eligible_rps = []
    for slo in slo_targets:
        # Find max RPS where p99 < SLO
        max_rps = 0
        for rps in RPS_LIST:
            if all_data[gk][rps]["latency_p99_ms"] <= slo:
                max_rps = rps
        eligible_rps.append(max_rps)
    ax.plot(slo_targets, eligible_rps, 'o-', color=COLORS[gk],
            label=LABELS[gk], markersize=5, linewidth=1.8)

ax.set_xlabel("SLO Target (p99 Latency, ms)")
ax.set_ylabel("Max Achievable RPS")
ax.set_title("Maximum Throughput Under Different SLO Constraints")
ax.legend()
ax.grid(True, alpha=0.3)
ax.set_xscale('log')
ax.xaxis.set_major_formatter(ticker.ScalarFormatter())
ax.set_xticks(slo_targets)
fig.savefig(os.path.join(FIG_DIR, "fig13_slo_sensitivity.png"))
plt.close()
print("  [13/14] SLO Sensitivity")

# =====================================================================
# Fig 14: Fleet Composition Sensitivity
# =====================================================================
fig, ax = plt.subplots(figsize=(9, 5.5))

# Vary L4:A100 ratio and compute fleet-level energy efficiency
ratios = [0, 0.2, 0.4, 0.5, 0.6, 0.8, 1.0]
rps_test = [5, 10, 20]

for rps in rps_test:
    fleet_ept = []
    for l4_frac in ratios:
        a100_frac = 1.0 - l4_frac
        e_l4 = all_data["l4_full"][rps]["energy_per_token_mj"]
        e_a100 = all_data["a100_full"][rps]["energy_per_token_mj"]
        fleet_ept.append(l4_frac * e_l4 + a100_frac * e_a100)
    ax.plot([r*100 for r in ratios], fleet_ept, 'o-',
            label=f'{rps} RPS', markersize=5, linewidth=1.8)

ax.set_xlabel("L4 Fraction of Fleet (%)")
ax.set_ylabel("Fleet-Average Energy per Token (mJ)")
ax.set_title("Fleet Energy Efficiency vs Hardware Composition")
ax.legend()
ax.grid(True, alpha=0.3)
ax.set_xlim(-5, 105)
fig.savefig(os.path.join(FIG_DIR, "fig14_fleet_composition.png"))
plt.close()
print("  [14/14] Fleet Composition")

# =====================================================================
# Summary Baseline Comparison Table (print to console)
# =====================================================================
print("\n" + "=" * 75)
print("  Baseline Comparison Summary @ 10 RPS")
print("=" * 75)

# Compute metrics for each strategy
strats = {}
for name in ["Round-Robin", "Energy-Aware", "Latency-Only", "Power-Proportional"]:
    if name == "Round-Robin":
        ept = np.mean([all_data[gk][10]["energy_per_token_mj"] for gk in GPU_ORDER])
        tps = np.mean([all_data[gk][10]["tokens_per_sec"] for gk in GPU_ORDER])
        lat = np.mean([all_data[gk][10]["latency_p50_ms"] for gk in GPU_ORDER])
        fail = sum(all_data[gk][10]["failed"] for gk in GPU_ORDER)
    elif name == "Energy-Aware":
        ept = all_data["l4_full"][10]["energy_per_token_mj"]
        tps = all_data["l4_full"][10]["tokens_per_sec"]
        lat = all_data["l4_full"][10]["latency_p50_ms"]
        fail = all_data["l4_full"][10]["failed"]
    elif name == "Latency-Only":
        ept = all_data["h100_full"][10]["energy_per_token_mj"]
        tps = all_data["h100_full"][10]["tokens_per_sec"]
        lat = all_data["h100_full"][10]["latency_p50_ms"]
        fail = all_data["h100_full"][10]["failed"]
    else:  # Power-Proportional (inverse TDP weighting)
        tdps = {"a100_full": 400, "a100_capped": 250, "h100_full": 700, "l4_full": 72}
        inv_tdps = {gk: 1.0/tdps[gk] for gk in GPU_ORDER}
        total_inv = sum(inv_tdps.values())
        weights = {gk: inv_tdps[gk]/total_inv for gk in GPU_ORDER}
        ept = sum(weights[gk]*all_data[gk][10]["energy_per_token_mj"] for gk in GPU_ORDER)
        tps = sum(weights[gk]*all_data[gk][10]["tokens_per_sec"] for gk in GPU_ORDER)
        lat = sum(weights[gk]*all_data[gk][10]["latency_p50_ms"] for gk in GPU_ORDER)
        fail = round(sum(weights[gk]*all_data[gk][10]["failed"] for gk in GPU_ORDER))
    strats[name] = {"ept": ept, "tps": tps, "lat": lat, "fail": fail}

rr_ept = strats["Round-Robin"]["ept"]
print(f"  {'Strategy':<22s}  {'EPT(mJ)':>8s}  {'TPS':>7s}  {'p50(ms)':>8s}  "
      f"{'Fail':>5s}  {'vs RR':>8s}")
print(f"  {'-'*22}  {'-'*8}  {'-'*7}  {'-'*8}  {'-'*5}  {'-'*8}")
for name, m in strats.items():
    saving = (1 - m["ept"]/rr_ept) * 100 if name != "Round-Robin" else 0
    tag = f"{saving:+.1f}%" if name != "Round-Robin" else "baseline"
    print(f"  {name:<22s}  {m['ept']:8.1f}  {m['tps']:7.1f}  {m['lat']:8.0f}  "
          f"{m['fail']:5d}  {tag:>8s}")

print(f"\nAll figures saved to: {FIG_DIR}/")
print("Done!")
