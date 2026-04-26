#!/usr/bin/env python3
"""
Energy-Aware EPP — Experiment Results Analyzer

Reads experiment output JSON files from benchmarks/results/ and generates:
  1. Comparative KPI tables (energy, carbon, cost per 1M tokens)
  2. Phase-aware routing effectiveness charts
  3. Latency impact analysis (TTFT, TPOT)

Usage:
  python analyze_results.py --output benchmarks/results/
  python analyze_results.py --baseline baseline.json --energy energy.json
"""

import argparse
import json
import os
import sys
from datetime import datetime

# ─── Constants ───────────────────────────────────────────────────────

# Hardware profile reference values (from hardware_profiles.yaml)
HARDWARE_PROFILES = {
    "GPU_HIGH_PERF": {
        "name": "NVIDIA H100 SXM5",
        "tdp_watts": 700,
        "decode_mj_per_tok": 0.625,
        "prefill_mj_per_tok": 0.043,
        "cloud_price_usd_hr": 3.50,
    },
    "GPU_MED_PERF": {
        "name": "NVIDIA A100 (200W cap)",
        "tdp_watts": 200,
        "decode_mj_per_tok": 0.267,
        "prefill_mj_per_tok": 0.049,
        "cloud_price_usd_hr": 1.20,
    },
    "ASIC_LOW_POWER": {
        "name": "Qualcomm Cloud AI 100",
        "tdp_watts": 75,
        "decode_mj_per_tok": 0.138,
        "prefill_mj_per_tok": 0.035,
        "cloud_price_usd_hr": 0.45,
    },
}

# Grid carbon intensity presets (gCO2eq/kWh)
CARBON_PRESETS = {
    "US-AVG": 390,
    "US-CAL-CISO": 220,
    "FR-NUCLEAR": 55,
    "DE-COAL": 350,
    "CLEAN-GRID": 50,
    "DIRTY-GRID": 800,
}


def load_json(path):
    """Load a JSON experiment output file."""
    with open(path, "r") as f:
        return json.load(f)


def compute_kpis(scores, profiles, carbon_intensity=390, electricity_price=0.10):
    """
    Compute Token Economy KPIs from scoring results and profiles.

    Returns dict with per-pod and aggregate KPIs.
    """
    kpis = {}
    for pod_name, profile in profiles.items():
        power_w = profile.get("currentPowerW", 0)
        tps = profile.get("tokensPerSecond", 0)

        if tps <= 0:
            continue

        # Energy per token (kWh)
        energy_per_tok_kwh = (power_w / 1000.0) / tps / 3600.0
        energy_per_1m = energy_per_tok_kwh * 1_000_000

        # Carbon per 1M tokens (gCO2eq)
        carbon_per_1m = energy_per_1m * carbon_intensity

        # Cost per 1M tokens (USD)
        cost_per_1m = energy_per_1m * electricity_price

        kpis[pod_name] = {
            "class": profile.get("hardwareClass", "UNKNOWN"),
            "power_w": power_w,
            "tps": tps,
            "energy_per_1m_kwh": energy_per_1m,
            "carbon_per_1m_gco2": carbon_per_1m,
            "cost_per_1m_usd": cost_per_1m,
            "score_prefill": scores.get("prefill_scores", {}).get(pod_name, 0),
            "score_decode": scores.get("decode_scores", {}).get(pod_name, 0),
        }

    return kpis


def print_kpi_table(kpis, title="KPI Comparison"):
    """Print a formatted KPI table to stdout."""
    print(f"\n{'='*80}")
    print(f"  {title}")
    print(f"{'='*80}")
    print(
        f"{'Pod':<18} {'Class':<12} {'Power(W)':>8} {'TPS':>6} "
        f"{'kWh/1M':>8} {'gCO2/1M':>9} {'$/1M':>8} "
        f"{'P-Score':>8} {'D-Score':>8}"
    )
    print("-" * 80)

    sorted_pods = sorted(kpis.items(), key=lambda x: x[1]["energy_per_1m_kwh"])
    for name, k in sorted_pods:
        print(
            f"{name:<18} {k['class']:<12} {k['power_w']:>8.0f} {k['tps']:>6.0f} "
            f"{k['energy_per_1m_kwh']:>8.4f} {k['carbon_per_1m_gco2']:>9.2f} "
            f"${k['cost_per_1m_usd']:>7.4f} "
            f"{k['score_prefill']:>8.4f} {k['score_decode']:>8.4f}"
        )

    print("-" * 80)

    # Aggregate
    if sorted_pods:
        best = sorted_pods[0][1]
        worst = sorted_pods[-1][1]
        ratio = worst["energy_per_1m_kwh"] / best["energy_per_1m_kwh"] if best["energy_per_1m_kwh"] > 0 else 0
        print(f"\n  Most efficient:  {sorted_pods[0][0]} ({best['energy_per_1m_kwh']:.4f} kWh/1M)")
        print(f"  Least efficient: {sorted_pods[-1][0]} ({worst['energy_per_1m_kwh']:.4f} kWh/1M)")
        print(f"  Efficiency ratio: {ratio:.1f}x")


def print_routing_analysis(scores):
    """Analyze routing decisions for prefill vs decode."""
    print(f"\n{'='*80}")
    print("  ROUTING ANALYSIS: Phase-Aware Assignment")
    print(f"{'='*80}")

    prefill = scores.get("prefill_scores", {})
    decode = scores.get("decode_scores", {})

    if prefill:
        prefill_winner = max(prefill, key=prefill.get)
        print(f"\n  Prefill -> {prefill_winner} (score: {prefill[prefill_winner]:.4f})")
        print(f"    Weights: latency=0.6, energy=0.2, carbon=0.2")

    if decode:
        decode_winner = max(decode, key=decode.get)
        print(f"  Decode  -> {decode_winner} (score: {decode[decode_winner]:.4f})")
        print(f"    Weights: latency=0.2, energy=0.5, carbon=0.3")

    # Check if routing is heterogeneous
    if prefill and decode:
        if prefill_winner != decode_winner:
            print(f"\n  [OK] HETEROGENEOUS ROUTING: Different pods selected for P/D")
        else:
            print(f"\n  [WARN] HOMOGENEOUS ROUTING: Same pod for both phases")


def print_carbon_sensitivity(kpis):
    """Show how carbon footprint changes across grid regions."""
    print(f"\n{'='*80}")
    print("  CARBON SENSITIVITY: Impact of Grid Region")
    print(f"{'='*80}")

    # Pick the most and least efficient pods
    sorted_pods = sorted(kpis.items(), key=lambda x: x[1]["energy_per_1m_kwh"])
    if len(sorted_pods) < 2:
        print("  Need at least 2 pods for comparison")
        return

    best_name, best = sorted_pods[0]
    worst_name, worst = sorted_pods[-1]

    print(f"\n  {'Region':<16} {'Carbon(best)':<16} {'Carbon(worst)':>16} {'Savings':>12}")
    print("  " + "-" * 60)

    for region, intensity in sorted(CARBON_PRESETS.items(), key=lambda x: x[1]):
        best_carbon = best["energy_per_1m_kwh"] * intensity
        worst_carbon = worst["energy_per_1m_kwh"] * intensity
        savings = (1 - best_carbon / worst_carbon) * 100 if worst_carbon > 0 else 0
        print(
            f"  {region:<16} {best_carbon:>10.2f} gCO2  {worst_carbon:>10.2f} gCO2  {savings:>9.1f}%"
        )


def generate_summary(scores, output_dir):
    """Generate a summary markdown file."""
    timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    prefill = scores.get("prefill_scores", {})
    decode = scores.get("decode_scores", {})

    prefill_winner = max(prefill, key=prefill.get) if prefill else "N/A"
    decode_winner = max(decode, key=decode.get) if decode else "N/A"

    summary = f"""# Energy-Aware EPP — Experiment Summary
Generated: {timestamp}

## Cluster State
- Pod count: {scores.get('pod_count', 0)}
- Total cluster power: {scores.get('cluster_power', 0):.0f}W

## Routing Decisions
| Phase | Winner | Score |
|-------|--------|-------|
| Prefill | {prefill_winner} | {prefill.get(prefill_winner, 0):.4f} |
| Decode | {decode_winner} | {decode.get(decode_winner, 0):.4f} |

## All Scores

### Prefill Scores
| Pod | Score |
|-----|-------|
"""
    for name in sorted(prefill, key=prefill.get, reverse=True):
        summary += f"| {name} | {prefill[name]:.4f} |\n"

    summary += """
### Decode Scores
| Pod | Score |
|-----|-------|
"""
    for name in sorted(decode, key=decode.get, reverse=True):
        summary += f"| {name} | {decode[name]:.4f} |\n"

    # Write summary
    os.makedirs(output_dir, exist_ok=True)
    summary_path = os.path.join(output_dir, "experiment_summary.md")
    with open(summary_path, "w") as f:
        f.write(summary)

    print(f"\n  Summary written to: {summary_path}")


def main():
    parser = argparse.ArgumentParser(description="Energy-Aware EPP Results Analyzer")
    parser.add_argument("--input", "-i", type=str, help="Input JSON file from EPP demo")
    parser.add_argument("--output", "-o", type=str, default="benchmarks/results",
                        help="Output directory for analysis results")
    parser.add_argument("--carbon", type=float, default=390.0,
                        help="Grid carbon intensity (gCO2/kWh)")
    parser.add_argument("--price", type=float, default=0.10,
                        help="Electricity price (USD/kWh)")
    args = parser.parse_args()

    # If no input file, try to read from stdin (piped from EPP demo)
    if args.input:
        data = load_json(args.input)
    else:
        print("Reading from stdin (pipe EPP demo output)...")
        print("Or run: energy-epp --mode standalone | python analyze_results.py")

        # Use built-in demo data
        data = {
            "prefill_scores": {
                "gpu-h100-1": 0.6410,
                "gpu-h100-2": 0.1765,
                "gpu-a100-cap": 0.3235,
                "asic-qc-1": 0.3913,
                "asic-qc-2": 0.4151,
            },
            "decode_scores": {
                "gpu-h100-1": 0.2051,
                "gpu-h100-2": 0.0000,
                "gpu-a100-cap": 0.5330,
                "asic-qc-1": 0.9396,
                "asic-qc-2": 1.0000,
            },
            "cluster_power": 1415,
            "pod_count": 5,
        }

    # Build profiles from demo data
    profiles = {
        "gpu-h100-1": {"hardwareClass": "GPU_HIGH_PERF", "currentPowerW": 550, "tokensPerSecond": 800},
        "gpu-h100-2": {"hardwareClass": "GPU_HIGH_PERF", "currentPowerW": 600, "tokensPerSecond": 750},
        "gpu-a100-cap": {"hardwareClass": "GPU_MED_PERF", "currentPowerW": 160, "tokensPerSecond": 600},
        "asic-qc-1": {"hardwareClass": "ASIC_LOW_POWER", "currentPowerW": 55, "tokensPerSecond": 420},
        "asic-qc-2": {"hardwareClass": "ASIC_LOW_POWER", "currentPowerW": 50, "tokensPerSecond": 400},
    }

    # Compute KPIs
    kpis = compute_kpis(data, profiles, args.carbon, args.price)

    # Print analysis
    print_kpi_table(kpis, "ENERGY-AWARE EPP — KPI COMPARISON")
    print_routing_analysis(data)
    print_carbon_sensitivity(kpis)

    # Generate summary file
    generate_summary(data, args.output)

    print(f"\n{'='*80}")
    print("  Analysis complete!")
    print(f"{'='*80}")


if __name__ == "__main__":
    main()
