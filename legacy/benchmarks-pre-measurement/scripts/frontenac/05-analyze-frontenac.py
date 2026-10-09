#!/usr/bin/env python3
"""
05-analyze-frontenac.py — Generate thesis-quality figures from Frontenac data.

Reads the CSV/JSON outputs from 02-profile-gpu and 03-power-sweep,
then produces:
  1. Power-vs-Utilization curve (proves non-linear power scaling)
  2. Energy-per-Token at different loads (proves ASIC advantage at decode)
  3. Prefill vs Decode scoring comparison (proves correct EPP routing)
  4. Token economics table (kWh, gCO2, $/1M tokens)

Usage:
    python3 benchmarks/scripts/frontenac/05-analyze-frontenac.py [RESULTS_DIR]
"""
import os
import sys
import json
import csv
from pathlib import Path

RESULTS_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / "energy-epp/benchmarks/results/frontenac"

# Ontario grid carbon intensity (gCO2/kWh) — 2024 average
CARBON_INTENSITY = 30  # Ontario is very clean (nuclear + hydro)
ELECTRICITY_PRICE = 0.12  # CAD$/kWh

print("═══════════════════════════════════════════════════════")
print("  Frontenac Benchmark Analysis")
print(f"  Results: {RESULTS_DIR}")
print("═══════════════════════════════════════════════════════")


def find_latest_dir(pattern):
    """Find most recent timestamped directory matching pattern."""
    candidates = sorted(RESULTS_DIR.glob(f"*{pattern}"), reverse=True)
    return candidates[0] if candidates else None


def load_sweep_csv(csv_path):
    """Load a sweep CSV into a list of dicts."""
    rows = []
    if not csv_path or not csv_path.exists():
        return rows
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append({k: float(v) if v.replace('.', '').replace('-', '').isdigit() else v
                        for k, v in row.items()})
    return rows


def load_json(path):
    """Load a JSON file."""
    if not path or not path.exists():
        return {}
    with open(path) as f:
        return json.load(f)


# ─── Find data ───────────────────────────────────────────────────────
profile_dir = find_latest_dir("_profile")
sweep_dir = find_latest_dir("_sweep")
scoring_dir = RESULTS_DIR / "epp_scoring" if (RESULTS_DIR / "epp_scoring").exists() else None

print(f"\nProfile data: {profile_dir}")
print(f"Sweep data:   {sweep_dir}")
print(f"Scoring data: {scoring_dir}")


# ═══════════════════════════════════════════════════════════════════════
# TABLE 1: GPU Profile Summary
# ═══════════════════════════════════════════════════════════════════════
print("\n" + "="*70)
print("TABLE 1: A100 GPU Power Profile")
print("="*70)

gpu_summary = load_json(profile_dir / "gpu_profile_summary.json") if profile_dir else {}
if gpu_summary:
    print(f"  GPU Model:    {gpu_summary.get('gpu', 'N/A')}")
    print(f"  GPU Memory:   {gpu_summary.get('gpu_memory_gb', 'N/A')} GB")
    print(f"  TDP:          {gpu_summary.get('tdp_watts', 'N/A')} W")
    print(f"  Idle Power:   {gpu_summary.get('idle_power_watts', 'N/A')} W")
    print(f"  Avg Load:     {gpu_summary.get('avg_load_power_watts', 'N/A')} W")
    print(f"  Max Observed: {gpu_summary.get('max_power_watts', 'N/A')} W")


# ═══════════════════════════════════════════════════════════════════════
# TABLE 2: Load vs Power vs Throughput (from profile)
# ═══════════════════════════════════════════════════════════════════════
print("\n" + "="*70)
print("TABLE 2: Load Sweep — Power vs Throughput")
print("="*70)
print(f"{'RPS':>6} {'TPS':>8} {'Power(W)':>10} {'p50(ms)':>10} {'EPT(mJ)':>10}")
print("-"*50)

if profile_dir:
    for rps in [1, 2, 5, 10, 20]:
        data = load_json(profile_dir / f"load_rps_{rps}.json")
        snap_path = profile_dir / f"snapshot_rps_{rps}.txt"
        power = "N/A"
        if snap_path.exists():
            with open(snap_path) as f:
                parts = f.readline().strip().split(",")
                power = parts[0].strip() if parts else "N/A"

        tps = data.get("tokens_per_sec", 0)
        p50 = data.get("latency_p50_ms", 0)
        try:
            ept = round(float(power) / float(tps) * 1000, 2) if float(tps) > 0 else 0
        except (ValueError, TypeError):
            ept = 0

        print(f"{rps:>6} {tps:>8.1f} {power:>10} {p50:>10.1f} {ept:>10.2f}")


# ═══════════════════════════════════════════════════════════════════════
# TABLE 3: Multi-GPU Sweep (from sweep job)
# ═══════════════════════════════════════════════════════════════════════
if sweep_dir:
    for gpu_idx in [0, 1]:
        sweep_path = sweep_dir / f"sweep_gpu{gpu_idx}.csv"
        sweep_data = load_sweep_csv(sweep_path)
        if not sweep_data:
            continue

        role = "Prefill" if gpu_idx == 0 else "Decode"
        print(f"\n{'='*70}")
        print(f"TABLE 3{chr(ord('a')+gpu_idx)}: GPU {gpu_idx} Sweep ({role})")
        print("="*70)
        print(f"{'RPS':>6} {'TPS':>8} {'Power(W)':>10} {'Util%':>8} {'p50(ms)':>10} {'EPT(mJ)':>10}")
        print("-"*56)

        for row in sweep_data:
            print(f"{row.get('rps',0):>6.1f} "
                  f"{row.get('tps',0):>8.1f} "
                  f"{row.get('power_w',0):>10.1f} "
                  f"{row.get('gpu_util',0):>8.0f} "
                  f"{row.get('p50_ms',0):>10.1f} "
                  f"{row.get('energy_per_token_mj',0):>10.2f}")


# ═══════════════════════════════════════════════════════════════════════
# TABLE 4: Token Economics (Energy/Carbon/Cost per 1M tokens)
# ═══════════════════════════════════════════════════════════════════════
print(f"\n{'='*70}")
print("TABLE 4: Token Economics — Energy, Carbon & Cost per 1M Tokens")
print(f"  Grid: Ontario (IESO) | Carbon: {CARBON_INTENSITY} gCO2/kWh | Price: ${ELECTRICITY_PRICE}/kWh")
print("="*70)

measured_profiles = load_json(scoring_dir / "measured_profiles.json") if scoring_dir else {}
profiles = measured_profiles.get("profiles", [])

if profiles:
    print(f"{'Endpoint':<28} {'Power(W)':>10} {'TPS':>8} {'kWh/1M':>10} {'gCO2/1M':>10} {'$/1M':>8}")
    print("-"*78)

    for p in profiles:
        power = p.get("current_power_w", 0)
        tps = p.get("tokens_per_sec", 1)
        # Time to generate 1M tokens (seconds)
        time_1m = 1_000_000 / tps if tps > 0 else 0
        # Energy = power × time (Wh then kWh)
        kwh_1m = (power * time_1m) / 3600 / 1000
        co2_1m = kwh_1m * CARBON_INTENSITY
        cost_1m = kwh_1m * ELECTRICITY_PRICE

        print(f"{p['name']:<28} {power:>10.1f} {tps:>8.1f} {kwh_1m:>10.4f} {co2_1m:>10.2f} {cost_1m:>8.4f}")

    # Energy savings calculation
    if len(profiles) >= 2:
        high_prof = profiles[0]
        low_prof = profiles[-1]
        high_ept = high_prof["current_power_w"] / high_prof["tokens_per_sec"]
        low_ept = low_prof["current_power_w"] / low_prof["tokens_per_sec"]
        savings_pct = (1 - low_ept / high_ept) * 100
        print(f"\n  Energy savings (decode on low-power vs prefill on high-power):")
        print(f"    {low_prof['name']} vs {high_prof['name']}: {savings_pct:.1f}% lower energy/token")


# ═══════════════════════════════════════════════════════════════════════
# TABLE 5: EPP Scoring Validation
# ═══════════════════════════════════════════════════════════════════════
epp_output_path = scoring_dir / "epp_output.txt" if scoring_dir else None
if epp_output_path and epp_output_path.exists():
    print(f"\n{'='*70}")
    print("TABLE 5: EPP Scoring Output (from real hardware profiles)")
    print("="*70)
    with open(epp_output_path) as f:
        print(f.read())


# ═══════════════════════════════════════════════════════════════════════
# Generate Matplotlib plots (if available)
# ═══════════════════════════════════════════════════════════════════════
try:
    import matplotlib
    matplotlib.use('Agg')  # Non-interactive backend for HPC
    import matplotlib.pyplot as plt
    import numpy as np

    FIGURES_DIR = RESULTS_DIR / "figures"
    FIGURES_DIR.mkdir(exist_ok=True)

    # ─── Figure 1: Power Timeline ────────────────────────────────────
    if profile_dir and (profile_dir / "power_timeseries.csv").exists():
        power_data = []
        with open(profile_dir / "power_timeseries.csv") as f:
            reader = csv.DictReader(f)
            for row in reader:
                try:
                    power_data.append(float(row['power_w']))
                except (ValueError, KeyError):
                    pass

        if power_data:
            fig, ax = plt.subplots(figsize=(12, 5))
            t = np.arange(len(power_data)) * 2  # 2-second intervals
            ax.plot(t, power_data, color='#2196F3', linewidth=1.5, alpha=0.8)
            ax.fill_between(t, power_data, alpha=0.2, color='#2196F3')
            ax.set_xlabel('Time (seconds)', fontsize=12)
            ax.set_ylabel('GPU Power (W)', fontsize=12)
            ax.set_title('A100 GPU Power Draw During Inference Workload', fontsize=14)
            ax.grid(True, alpha=0.3)
            ax.set_ylim(bottom=0)
            fig.tight_layout()
            fig.savefig(FIGURES_DIR / "power_timeline.png", dpi=150)
            print(f"\n  Figure saved: {FIGURES_DIR / 'power_timeline.png'}")

    # ─── Figure 2: RPS vs Energy-per-Token ───────────────────────────
    if sweep_dir:
        fig, axes = plt.subplots(1, 2, figsize=(14, 5))

        for gpu_idx, (ax, color, role) in enumerate(
            zip(axes, ['#FF5722', '#4CAF50'], ['Prefill (GPU 0)', 'Decode (GPU 1)'])):
            sweep_path = sweep_dir / f"sweep_gpu{gpu_idx}.csv"
            data = load_sweep_csv(sweep_path)
            if not data:
                continue

            rps_vals = [d['rps'] for d in data]
            ept_vals = [d['energy_per_token_mj'] for d in data]
            power_vals = [d['power_w'] for d in data]

            ax.bar(range(len(rps_vals)), ept_vals, color=color, alpha=0.8)
            ax.set_xticks(range(len(rps_vals)))
            ax.set_xticklabels([f"{r:.1f}" for r in rps_vals])
            ax.set_xlabel('Request Rate (RPS)', fontsize=11)
            ax.set_ylabel('Energy per Token (mJ)', fontsize=11)
            ax.set_title(f'{role}', fontsize=13)
            ax.grid(True, axis='y', alpha=0.3)

            # Add power labels on bars
            for i, (e, p) in enumerate(zip(ept_vals, power_vals)):
                ax.text(i, e + 0.5, f'{p:.0f}W', ha='center', fontsize=8, color='gray')

        fig.suptitle('Energy per Token vs Load — A100 GPU on Frontenac', fontsize=14)
        fig.tight_layout()
        fig.savefig(FIGURES_DIR / "ept_vs_load.png", dpi=150)
        print(f"  Figure saved: {FIGURES_DIR / 'ept_vs_load.png'}")

    # ─── Figure 3: Token Economics Bar Chart ─────────────────────────
    if profiles:
        fig, axes = plt.subplots(1, 3, figsize=(15, 5))
        names = [p['name'].replace('a100-', '').replace('asic-', '') for p in profiles]
        colors = ['#F44336', '#FF9800', '#4CAF50']

        # kWh per 1M tokens
        kwh_vals = []
        co2_vals = []
        cost_vals = []
        for p in profiles:
            tps = p.get("tokens_per_sec", 1)
            power = p.get("current_power_w", 0)
            time_1m = 1_000_000 / tps if tps > 0 else 0
            kwh = (power * time_1m) / 3600 / 1000
            kwh_vals.append(kwh)
            co2_vals.append(kwh * CARBON_INTENSITY)
            cost_vals.append(kwh * ELECTRICITY_PRICE)

        for ax, vals, ylabel, title in [
            (axes[0], kwh_vals, 'kWh', 'Energy per 1M Tokens'),
            (axes[1], co2_vals, 'gCO₂e', 'Carbon per 1M Tokens'),
            (axes[2], cost_vals, 'CAD$', 'Cost per 1M Tokens'),
        ]:
            bars = ax.bar(names, vals, color=colors[:len(names)], alpha=0.85)
            ax.set_ylabel(ylabel, fontsize=11)
            ax.set_title(title, fontsize=12)
            ax.grid(True, axis='y', alpha=0.3)
            for bar, v in zip(bars, vals):
                ax.text(bar.get_x() + bar.get_width()/2, v + v*0.02,
                       f'{v:.3f}', ha='center', fontsize=9)

        fig.suptitle('Token Economics — Frontenac A100 (Ontario Grid)', fontsize=14)
        fig.tight_layout()
        fig.savefig(FIGURES_DIR / "token_economics.png", dpi=150)
        print(f"  Figure saved: {FIGURES_DIR / 'token_economics.png'}")

    print(f"\n  All figures: {FIGURES_DIR}/")

except ImportError:
    print("\n  [WARN] matplotlib not available — skipping figure generation.")
    print("  Install with: pip install matplotlib")


# ═══════════════════════════════════════════════════════════════════════
# Write LaTeX-ready table
# ═══════════════════════════════════════════════════════════════════════
latex_path = RESULTS_DIR / "tables.tex"
with open(latex_path, "w") as f:
    f.write("% Auto-generated from Frontenac benchmark results\n")
    f.write("% Include in thesis with: \\input{tables.tex}\n\n")

    if profiles:
        f.write("\\begin{table}[htbp]\n")
        f.write("\\centering\n")
        f.write("\\caption{Token Economics — Measured on NVIDIA A100 (Frontenac 2.0)}\n")
        f.write("\\label{tab:token-economics}\n")
        f.write("\\begin{tabular}{lrrrrr}\n")
        f.write("\\toprule\n")
        f.write("Endpoint & Power (W) & TPS & kWh/1M & gCO\\textsubscript{2}/1M & \\$/1M \\\\\n")
        f.write("\\midrule\n")
        for p in profiles:
            tps = p.get("tokens_per_sec", 1)
            power = p.get("current_power_w", 0)
            time_1m = 1_000_000 / tps if tps > 0 else 0
            kwh = (power * time_1m) / 3600 / 1000
            f.write(f"{p['name']} & {power:.0f} & {tps:.0f} & {kwh:.4f} "
                    f"& {kwh*CARBON_INTENSITY:.2f} & {kwh*ELECTRICITY_PRICE:.4f} \\\\\n")
        f.write("\\bottomrule\n")
        f.write("\\end{tabular}\n")
        f.write("\\end{table}\n")

print(f"\n  LaTeX tables: {latex_path}")
print("\n═══════════════════════════════════════════════════════")
print("  ANALYSIS COMPLETE")
print("═══════════════════════════════════════════════════════")
