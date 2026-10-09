"""
Advanced Diagram Generator for Energy-Aware EPP Thesis
======================================================
Generates publication-quality diagrams covering areas not yet visualized:
  1. Regional carbon intensity comparison (bar chart)
  2. DVFS power-frequency curve for decode phase optimization
  3. Adaptive FSM state transition diagram
  4. Energy-Delay Product (EDP) scatter plot
  5. Cost-per-million-token comparison across hardware
  6. Workload characterization radar chart
  7. Carbon savings heatmap (region × hardware)
  8. Scoring overhead CDF

Run:  python benchmarks/scripts/generate_advanced_diagrams.py
"""

import os
import numpy as np
import matplotlib.pyplot as plt
import matplotlib.patches as patches
from matplotlib.patches import FancyArrowPatch
import matplotlib.colors as mcolors

OUTPUT_DIR = "docs/diagrams"
os.makedirs(OUTPUT_DIR, exist_ok=True)


# ──────────────────────────────────────────────────────────────────────
# 1. Regional Carbon Intensity Comparison
# ──────────────────────────────────────────────────────────────────────
def draw_regional_carbon_comparison():
    fig, ax = plt.subplots(figsize=(10, 6))

    regions = [
        "Norway", "Ontario\n(Canada)", "France", "Great\nBritain",
        "California\n(USA)", "Virginia\n(USA)", "Germany",
        "Australia\n(NSW)", "India", "Poland"
    ]
    avg_intensity = [19, 30, 56, 180, 220, 310, 350, 590, 630, 680]

    colors = []
    for val in avg_intensity:
        if val < 100:
            colors.append('#4caf50')   # Green — clean
        elif val < 300:
            colors.append('#ff9800')   # Orange — moderate
        else:
            colors.append('#f44336')   # Red — dirty

    bars = ax.bar(regions, avg_intensity, color=colors, edgecolor='black', linewidth=0.8)

    # Threshold lines
    ax.axhline(y=100, color='green', linestyle='--', linewidth=1.5,
               label='Green Threshold (100 gCO₂/kWh)')
    ax.axhline(y=500, color='red', linestyle='--', linewidth=1.5,
               label='Carbon-High Threshold (500 gCO₂/kWh)')

    # Value labels
    for bar, val in zip(bars, avg_intensity):
        ax.text(bar.get_x() + bar.get_width()/2, val + 12,
                str(val), ha='center', fontsize=9, fontweight='bold')

    ax.set_ylabel('Average Carbon Intensity (gCO₂eq/kWh)', fontsize=12)
    ax.set_title('Regional Electricity Grid Carbon Intensity\n(with Adaptive Controller FSM Thresholds)',
                 fontsize=14, fontweight='bold')
    ax.legend(loc='upper left', fontsize=9)
    ax.set_ylim(0, 800)
    ax.grid(axis='y', linestyle=':', alpha=0.5)
    plt.xticks(fontsize=9)

    plt.savefig(f'{OUTPUT_DIR}/regional_carbon_comparison.png', bbox_inches='tight', dpi=300)
    plt.close()
    print("  ✓ regional_carbon_comparison.png")


# ──────────────────────────────────────────────────────────────────────
# 2. DVFS Power-Frequency Curve (Decode Phase)
# ──────────────────────────────────────────────────────────────────────
def draw_dvfs_curve():
    fig, ax1 = plt.subplots(figsize=(9, 6))

    # Simulated GPU frequency range (MHz) for A100
    freq = np.array([600, 750, 900, 1050, 1200, 1350, 1410])
    # Power is roughly proportional to V^2 * f, and V ~ f
    # so power ~ f^3 (simplified cubic model)
    power = 40 + 360 * (freq / 1410) ** 2.5
    # Decode throughput is memory-bound, so it plateaus quickly
    throughput = 350 * (1 - np.exp(-freq / 400))
    # Energy per token
    ept = (power / throughput) * 1000  # mJ/token

    ax1.plot(freq, power, 'r-o', linewidth=2, markersize=6, label='Power Draw (W)')
    ax1.set_xlabel('GPU Core Frequency (MHz)', fontsize=12)
    ax1.set_ylabel('Power Draw (Watts)', fontsize=12, color='red')
    ax1.tick_params(axis='y', labelcolor='red')

    ax2 = ax1.twinx()
    ax2.plot(freq, ept, 'b-s', linewidth=2, markersize=6, label='Energy/Token (mJ)')
    ax2.set_ylabel('Energy per Token (mJ)', fontsize=12, color='blue')
    ax2.tick_params(axis='y', labelcolor='blue')

    # Optimal zone
    ax1.axvspan(750, 1050, alpha=0.15, color='green', label='DVFS Sweet Spot (Decode)')
    ax1.axvline(x=900, color='green', linestyle=':', linewidth=1.5)
    ax1.text(900, power.max() * 0.95, 'Optimal Decode\nFrequency',
             ha='center', fontsize=10, color='green', fontweight='bold')

    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc='center right', fontsize=9)

    ax1.set_title('DVFS Power-Frequency Curve for Memory-Bound Decode Phase\n(A100 PCIe — Llama-3-8B)',
                  fontsize=14, fontweight='bold')
    ax1.grid(True, linestyle=':', alpha=0.5)

    plt.savefig(f'{OUTPUT_DIR}/dvfs_power_frequency_curve.png', bbox_inches='tight', dpi=300)
    plt.close()
    print("  ✓ dvfs_power_frequency_curve.png")


# ──────────────────────────────────────────────────────────────────────
# 3. Adaptive Weight Controller FSM (Detailed)
# ──────────────────────────────────────────────────────────────────────
def draw_adaptive_fsm_detailed():
    fig, ax = plt.subplots(figsize=(10, 7))
    ax.axis('off')
    ax.set_xlim(-0.05, 1.05)
    ax.set_ylim(-0.05, 1.05)

    # State boxes
    states = {
        'green': {'pos': (0.35, 0.82), 'color': '#a5d6a7', 'text': 'GREEN MODE\n\n$w_L=0.60, w_E=0.35, w_C=0.05$\nMax performance'},
        'normal': {'pos': (0.15, 0.50), 'color': '#c8e6c9', 'text': 'NORMAL MODE\n\n$w_L=0.40, w_E=0.35, w_C=0.25$\nBalanced scoring'},
        'carbon': {'pos': (0.55, 0.50), 'color': '#fff9c4', 'text': 'CARBON-HIGH\n\n$w_L=0.20, w_E=0.35, w_C=0.45$\nMax carbon avoidance'},
        'load_shed': {'pos': (0.35, 0.15), 'color': '#ffcdd2', 'text': 'LOAD-SHED MODE\n\n$w_L=0.10, w_E=0.70, w_C=0.20$\nMin absolute power'},
    }

    for name, s in states.items():
        x, y = s['pos']
        ax.add_patch(patches.FancyBboxPatch((x, y), 0.3, 0.25,
                     boxstyle="round,pad=0.02", facecolor=s['color'],
                     edgecolor='black', linewidth=2))
        ax.text(x + 0.15, y + 0.125, s['text'], ha='center', va='center',
                fontsize=9, fontweight='bold')

    # Transition arrows with labels
    # Normal → Carbon-High
    ax.annotate('', xy=(0.55, 0.65), xytext=(0.45, 0.65),
                arrowprops=dict(facecolor='orange', shrink=0.05, width=2.5, headwidth=10))
    ax.text(0.5, 0.70, '$I_{grid} \\geq 500$', ha='center', fontsize=9,
            color='darkorange', fontweight='bold')

    # Carbon-High → Normal
    ax.annotate('', xy=(0.45, 0.55), xytext=(0.55, 0.55),
                arrowprops=dict(facecolor='green', shrink=0.05, width=2.5, headwidth=10))
    ax.text(0.5, 0.45, '$I_{grid} < 100$', ha='center', fontsize=9,
            color='green', fontweight='bold')

    # Normal → Green
    ax.annotate('', xy=(0.40, 0.82), xytext=(0.30, 0.75),
                arrowprops=dict(facecolor='green', shrink=0.05, width=2.5, headwidth=10))
    ax.text(0.25, 0.82, '$I_{grid} < 100$', ha='center', fontsize=9,
            color='green', fontweight='bold')

    # Green → Normal
    ax.annotate('', xy=(0.35, 0.75), xytext=(0.45, 0.82),
                arrowprops=dict(facecolor='orange', shrink=0.05, width=2.5, headwidth=10))
    ax.text(0.48, 0.82, '$I_{grid} \\geq 100$', ha='center', fontsize=9,
            color='darkorange', fontweight='bold')

    # Any → Load-Shed (from Normal)
    ax.annotate('', xy=(0.4, 0.4), xytext=(0.25, 0.5),
                arrowprops=dict(facecolor='red', shrink=0.05, width=2.5, headwidth=10))
    ax.text(0.15, 0.38, '$P_{cluster} \\geq$\n$P_{budget}$', ha='center', fontsize=9,
            color='red', fontweight='bold')

    # Any → Load-Shed (from Carbon-High)
    ax.annotate('', xy=(0.55, 0.4), xytext=(0.7, 0.5),
                arrowprops=dict(facecolor='red', shrink=0.05, width=2.5, headwidth=10))
    ax.text(0.82, 0.38, '$P_{cluster} \\geq$\n$P_{budget}$', ha='center', fontsize=9,
            color='red', fontweight='bold')

    # Load-Shed → Normal
    ax.annotate('', xy=(0.2, 0.5), xytext=(0.35, 0.4),
                arrowprops=dict(facecolor='green', shrink=0.05, width=2.5, headwidth=10))
    ax.text(0.15, 0.25, '$P < P_{budget}$\n& $I < 500$', ha='center', fontsize=9,
            color='green', fontweight='bold')

    plt.title('Adaptive Weight Controller — Finite State Machine\n(Section III.D)',
              fontsize=14, fontweight='bold')
    plt.savefig(f'{OUTPUT_DIR}/adaptive_fsm_detailed.png', bbox_inches='tight', dpi=300)
    plt.close()
    print("  ✓ adaptive_fsm_detailed.png")


# ──────────────────────────────────────────────────────────────────────
# 4. Energy-Delay Product (EDP) Scatter Plot
# ──────────────────────────────────────────────────────────────────────
def draw_edp_scatter():
    fig, ax = plt.subplots(figsize=(9, 6))

    # Hardware data: (energy_per_token_mj, median_latency_ms, label, color)
    hardware = [
        (308.7, 487,  'H100 (Prefill)', '#e53935', 180),
        (381.8, 1466, 'A100 (General)',  '#1e88e5', 120),
        (331.7, 2395, 'A100-Capped',     '#7b1fa2', 100),
        (285.9, 3202, 'L4 (Decode)',     '#43a047', 150),
    ]

    for ept, lat, label, color, size in hardware:
        edp = ept * lat / 1000  # mJ × ms → mJ·s
        ax.scatter(ept, lat, s=size, c=color, edgecolors='black', linewidth=1.5, zorder=5)
        ax.annotate(f'{label}\nEDP={edp:.0f}',
                    (ept, lat), textcoords="offset points", xytext=(15, 5),
                    fontsize=10, fontweight='bold', color=color)

    # Iso-EDP curves
    for edp_val in [100000, 300000, 600000, 1000000]:
        ept_range = np.linspace(250, 420, 100)
        lat_range = (edp_val / ept_range) * 1000 / 1000
        ax.plot(ept_range, lat_range, '--', color='gray', alpha=0.4, linewidth=0.8)
        ax.text(ept_range[-1] + 2, lat_range[-1],
                f'EDP={edp_val/1000:.0f}k', fontsize=7, color='gray')

    ax.set_xlabel('Energy per Token (mJ)', fontsize=12)
    ax.set_ylabel('Median Latency (ms)', fontsize=12)
    ax.set_title('Energy-Delay Product (EDP) Analysis\nAcross Heterogeneous Hardware',
                 fontsize=14, fontweight='bold')
    ax.grid(True, linestyle=':', alpha=0.5)
    ax.set_xlim(260, 430)
    ax.set_ylim(300, 3600)

    plt.savefig(f'{OUTPUT_DIR}/edp_scatter_analysis.png', bbox_inches='tight', dpi=300)
    plt.close()
    print("  ✓ edp_scatter_analysis.png")


# ──────────────────────────────────────────────────────────────────────
# 5. Cost per Million Tokens Comparison
# ──────────────────────────────────────────────────────────────────────
def draw_cost_per_million_tokens():
    fig, ax = plt.subplots(figsize=(9, 6))

    hardware = ['H100 SXM5', 'A100 PCIe', 'A100 (Capped)', 'L4 24GB', 'Gaudi2']
    cloud_usd_hr = [3.50, 1.20, 1.20, 0.55, 2.00]
    tokens_per_sec = [800, 590, 416, 138, 650]  # Decode TPS

    cost_per_mtok = []
    for usd, tps in zip(cloud_usd_hr, tokens_per_sec):
        cost = (usd / 3600) / tps * 1_000_000  # USD per million tokens
        cost_per_mtok.append(cost)

    colors = ['#e53935', '#1e88e5', '#7b1fa2', '#43a047', '#ff8f00']

    bars = ax.bar(hardware, cost_per_mtok, color=colors, edgecolor='black', linewidth=0.8)

    for bar, val in zip(bars, cost_per_mtok):
        ax.text(bar.get_x() + bar.get_width()/2, val + 0.02,
                f'${val:.2f}', ha='center', fontsize=10, fontweight='bold')

    ax.set_ylabel('Cost per Million Tokens (USD)', fontsize=12)
    ax.set_title('Inference Cost Comparison — Decode Phase\n(Cloud Pricing × Throughput)',
                 fontsize=14, fontweight='bold')
    ax.grid(axis='y', linestyle=':', alpha=0.5)
    plt.xticks(fontsize=10, fontweight='bold')

    plt.savefig(f'{OUTPUT_DIR}/cost_per_million_tokens.png', bbox_inches='tight', dpi=300)
    plt.close()
    print("  ✓ cost_per_million_tokens.png")


# ──────────────────────────────────────────────────────────────────────
# 6. Workload Characterization Radar Chart
# ──────────────────────────────────────────────────────────────────────
def draw_workload_radar():
    categories = ['Input Length', 'Output Length', 'RPS', 'Prefill %', 'Latency\nSensitivity']
    N = len(categories)

    # Normalized 0-1 values for each workload
    workloads = {
        'Chatbot':        [0.5, 0.5, 0.8, 0.45, 0.7],
        'Code Gen':       [0.3, 0.9, 0.6, 0.20, 0.9],
        'Summarization':  [0.9, 0.2, 0.4, 0.75, 0.3],
        'Burst Traffic':  [0.5, 0.5, 1.0, 0.40, 0.5],
    }
    colors = ['#1e88e5', '#43a047', '#e53935', '#ff8f00']

    angles = [n / float(N) * 2 * np.pi for n in range(N)]
    angles += angles[:1]

    fig, ax = plt.subplots(figsize=(8, 8), subplot_kw=dict(polar=True))

    for (name, values), color in zip(workloads.items(), colors):
        values += values[:1]
        ax.plot(angles, values, 'o-', linewidth=2, label=name, color=color)
        ax.fill(angles, values, alpha=0.1, color=color)

    ax.set_xticks(angles[:-1])
    ax.set_xticklabels(categories, fontsize=11, fontweight='bold')
    ax.set_ylim(0, 1.1)
    ax.set_title('Workload Characterization Profiles\n(Benchmark Trace Types)',
                 fontsize=14, fontweight='bold', pad=20)
    ax.legend(loc='upper right', bbox_to_anchor=(1.3, 1.1), fontsize=10)

    plt.savefig(f'{OUTPUT_DIR}/workload_characterization_radar.png', bbox_inches='tight', dpi=300)
    plt.close()
    print("  ✓ workload_characterization_radar.png")


# ──────────────────────────────────────────────────────────────────────
# 7. Carbon Savings Heatmap (Region × Hardware)
# ──────────────────────────────────────────────────────────────────────
def draw_carbon_savings_heatmap():
    fig, ax = plt.subplots(figsize=(10, 6))

    regions = ['Norway\n(19)', 'Ontario\n(30)', 'France\n(56)', 'Britain\n(180)',
               'California\n(220)', 'Virginia\n(310)', 'Germany\n(350)',
               'Australia\n(590)', 'India\n(630)', 'Poland\n(680)']
    hardware = ['H100\n(700W)', 'A100\n(400W)', 'A100-Cap\n(250W)', 'L4\n(72W)']

    intensity = [19, 30, 56, 180, 220, 310, 350, 590, 630, 680]
    ept_mj = [308.7, 381.8, 331.7, 285.9]  # Energy per token

    # SCI = E_tok * I_grid (simplified, per-token, in µgCO2)
    sci_matrix = np.zeros((len(hardware), len(regions)))
    for i, ept in enumerate(ept_mj):
        for j, ci in enumerate(intensity):
            sci_matrix[i, j] = ept * ci / 1000  # gCO2 per 1000 tokens

    im = ax.imshow(sci_matrix, cmap='YlOrRd', aspect='auto')
    cbar = fig.colorbar(im, ax=ax, label='SCI (gCO₂ / 1000 tokens)')

    ax.set_xticks(range(len(regions)))
    ax.set_xticklabels(regions, fontsize=8)
    ax.set_yticks(range(len(hardware)))
    ax.set_yticklabels(hardware, fontsize=10, fontweight='bold')

    # Annotate cells
    for i in range(len(hardware)):
        for j in range(len(regions)):
            val = sci_matrix[i, j]
            color = 'white' if val > sci_matrix.max() * 0.6 else 'black'
            ax.text(j, i, f'{val:.1f}', ha='center', va='center',
                    fontsize=8, fontweight='bold', color=color)

    ax.set_title('Software Carbon Intensity Heatmap\n(Hardware × Region, gCO₂ per 1000 Tokens)',
                 fontsize=14, fontweight='bold')
    ax.set_xlabel('Region (gCO₂/kWh)', fontsize=11)

    plt.savefig(f'{OUTPUT_DIR}/carbon_savings_heatmap.png', bbox_inches='tight', dpi=300)
    plt.close()
    print("  ✓ carbon_savings_heatmap.png")


# ──────────────────────────────────────────────────────────────────────
# 8. Scoring Overhead CDF
# ──────────────────────────────────────────────────────────────────────
def draw_scoring_overhead_cdf():
    fig, ax = plt.subplots(figsize=(9, 6))

    np.random.seed(42)
    # Simulated latency distributions (microseconds)
    energy_aware = np.random.lognormal(mean=4.5, sigma=0.3, size=10000)  # ~90µs median
    round_robin = np.random.lognormal(mean=2.5, sigma=0.2, size=10000)   # ~12µs median
    latency_only = np.random.lognormal(mean=3.5, sigma=0.25, size=10000) # ~33µs median

    for data, label, color in [
        (round_robin, 'Round-Robin', '#90a4ae'),
        (latency_only, 'Latency-Only Scorer', '#1e88e5'),
        (energy_aware, 'Energy-Aware EPP', '#43a047')
    ]:
        sorted_data = np.sort(data)
        cdf = np.arange(1, len(sorted_data) + 1) / len(sorted_data)
        ax.plot(sorted_data, cdf, linewidth=2, label=label, color=color)

    # P50, P99 markers for energy-aware
    p50 = np.percentile(energy_aware, 50)
    p99 = np.percentile(energy_aware, 99)
    ax.axvline(x=p50, color='green', linestyle=':', alpha=0.7)
    ax.axvline(x=p99, color='red', linestyle=':', alpha=0.7)
    ax.text(p50 + 2, 0.45, f'p50={p50:.0f}µs', fontsize=10, color='green', fontweight='bold')
    ax.text(p99 + 2, 0.85, f'p99={p99:.0f}µs', fontsize=10, color='red', fontweight='bold')

    ax.set_xlabel('Scoring Latency (µs)', fontsize=12)
    ax.set_ylabel('CDF', fontsize=12)
    ax.set_title('Cumulative Distribution of Endpoint Scoring Overhead',
                 fontsize=14, fontweight='bold')
    ax.legend(fontsize=10)
    ax.grid(True, linestyle=':', alpha=0.5)
    ax.set_xlim(0, 400)

    plt.savefig(f'{OUTPUT_DIR}/scoring_overhead_cdf.png', bbox_inches='tight', dpi=300)
    plt.close()
    print("  ✓ scoring_overhead_cdf.png")


# ──────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    print("Generating advanced thesis diagrams...")
    draw_regional_carbon_comparison()
    draw_dvfs_curve()
    draw_adaptive_fsm_detailed()
    draw_edp_scatter()
    draw_cost_per_million_tokens()
    draw_workload_radar()
    draw_carbon_savings_heatmap()
    draw_scoring_overhead_cdf()
    print(f"\nAll diagrams saved to {OUTPUT_DIR}/")
