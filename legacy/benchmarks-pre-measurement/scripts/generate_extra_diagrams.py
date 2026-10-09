import os
import matplotlib.pyplot as plt
import matplotlib.patches as patches
import numpy as np

def draw_epsilon_constraint():
    fig, ax = plt.subplots(figsize=(8, 6))
    
    # Generate mock Pareto frontier data
    energy = np.linspace(100, 400, 100)
    latency = 100000 / (energy - 80) + 100
    
    # Plot Pareto curve
    ax.plot(energy, latency, 'b-', linewidth=2, label='Pareto Frontier')
    
    # Epsilon bounds
    eps1 = 1000 # Latency SLO
    ax.axhline(y=eps1, color='r', linestyle='--', label=r'Latency SLO ($\epsilon_1$)')
    ax.fill_between(energy, eps1, 1500, color='red', alpha=0.1) # Infeasible region
    
    # Feasible region highlight
    feasible_idx = np.where(latency <= eps1)[0]
    ax.plot(energy[feasible_idx], latency[feasible_idx], 'g-', linewidth=4, label='Feasible Solution Space')
    
    # Optimal point
    opt_energy = energy[feasible_idx[0]]
    opt_latency = latency[feasible_idx[0]]
    ax.plot(opt_energy, opt_latency, 'g*', markersize=15, label='Optimal Endpoint $p^*$')
    
    ax.set_xlabel('Energy per Token (mJ)', fontsize=12)
    ax.set_ylabel('Latency (ms)', fontsize=12)
    ax.set_title(r'$\epsilon$-Constraint Multi-Objective Optimization', fontsize=14, fontweight='bold')
    ax.set_ylim(100, 1500)
    ax.set_xlim(100, 400)
    ax.legend(loc='upper right')
    ax.grid(True, linestyle=':', alpha=0.6)
    
    os.makedirs('docs/diagrams', exist_ok=True)
    plt.savefig('docs/diagrams/epsilon_constraint_pareto.png', bbox_inches='tight', dpi=300)
    plt.close()

def draw_system_components():
    fig, ax = plt.subplots(figsize=(10, 8))
    ax.axis('off')
    
    # Kubernetes Boundary
    ax.add_patch(patches.Rectangle((0.05, 0.05), 0.9, 0.9, fill=False, ec='black', lw=2, linestyle='--'))
    ax.text(0.1, 0.92, 'Kubernetes Cluster', fontsize=12, fontweight='bold')
    
    # Gateway API
    ax.add_patch(patches.Rectangle((0.1, 0.7), 0.8, 0.15, fill=True, color='#bbdefb', ec='black'))
    ax.text(0.5, 0.775, 'Kubernetes Gateway API (Envoy Proxy)\nInference Extension', ha='center', va='center', fontsize=12, fontweight='bold')
    
    # EPP Sidecar
    ax.add_patch(patches.Rectangle((0.1, 0.45), 0.35, 0.2, fill=True, color='#c8e6c9', ec='black'))
    ax.text(0.275, 0.6, 'Energy-Aware EPP\n(ext_proc gRPC)', ha='center', va='center', fontsize=11, fontweight='bold')
    ax.text(0.275, 0.52, '1. Filter (SLOs)\n2. Score (Energy/Carbon)\n3. Pick', ha='center', va='center', fontsize=9)
    
    # Telemetry Plane
    ax.add_patch(patches.Rectangle((0.55, 0.45), 0.35, 0.2, fill=True, color='#ffcc80', ec='black'))
    ax.text(0.725, 0.55, 'Telemetry & Control Plane\n(EnergyStore + FSM)', ha='center', va='center', fontsize=11, fontweight='bold')
    
    # vLLM Endpoints
    ax.add_patch(patches.Rectangle((0.1, 0.15), 0.2, 0.2, fill=True, color='#e1bee7', ec='black'))
    ax.text(0.2, 0.25, 'Endpoint A\n(H100)\nPrefill', ha='center', va='center', fontsize=10, fontweight='bold')
    
    ax.add_patch(patches.Rectangle((0.4, 0.15), 0.2, 0.2, fill=True, color='#e1bee7', ec='black'))
    ax.text(0.5, 0.25, 'Endpoint B\n(A100)\nGeneral', ha='center', va='center', fontsize=10, fontweight='bold')
    
    ax.add_patch(patches.Rectangle((0.7, 0.15), 0.2, 0.2, fill=True, color='#e1bee7', ec='black'))
    ax.text(0.8, 0.25, 'Endpoint C\n(L4 ASIC)\nDecode', ha='center', va='center', fontsize=10, fontweight='bold')
    
    # Arrows
    # User to Gateway
    ax.annotate('', xy=(0.5, 0.85), xytext=(0.5, 0.98), arrowprops=dict(facecolor='black', shrink=0.05, width=2))
    ax.text(0.5, 0.95, 'User Request (Phase: Prefill/Decode)', ha='center', va='center')
    
    # Gateway to EPP
    ax.annotate('', xy=(0.275, 0.65), xytext=(0.35, 0.7), arrowprops=dict(facecolor='blue', shrink=0.05, width=2, connectionstyle="arc3,rad=-0.2"))
    ax.text(0.2, 0.68, 'Routing Decision Req', fontsize=8, rotation=20)
    
    # EPP to Telemetry
    ax.annotate('', xy=(0.55, 0.55), xytext=(0.45, 0.55), arrowprops=dict(facecolor='black', shrink=0.05, width=2))
    
    # Gateway to Endpoints
    ax.annotate('', xy=(0.2, 0.35), xytext=(0.3, 0.7), arrowprops=dict(facecolor='green', shrink=0.05, width=1))
    ax.annotate('', xy=(0.5, 0.35), xytext=(0.5, 0.7), arrowprops=dict(facecolor='green', shrink=0.05, width=1))
    ax.annotate('', xy=(0.8, 0.35), xytext=(0.7, 0.7), arrowprops=dict(facecolor='green', shrink=0.05, width=1))
    
    plt.title('High-Level System Architecture and Request Flow', fontsize=14, fontweight='bold')
    plt.savefig('docs/diagrams/system_components.png', bbox_inches='tight', dpi=300)
    plt.close()

def draw_phase_aware_weights():
    fig, ax = plt.subplots(figsize=(8, 6))
    
    categories = ['Prefill Phase', 'Decode Phase']
    latency_weights = [0.60, 0.20]
    energy_weights = [0.20, 0.50]
    carbon_weights = [0.20, 0.30]
    
    x = np.arange(len(categories))
    width = 0.25
    
    ax.bar(x - width, latency_weights, width, label='Latency Weight ($w_L$)', color='#ef5350')
    ax.bar(x, energy_weights, width, label='Energy Weight ($w_E$)', color='#66bb6a')
    ax.bar(x + width, carbon_weights, width, label='Carbon Weight ($w_C$)', color='#42a5f5')
    
    ax.set_ylabel('Weight Value', fontsize=12)
    ax.set_title('Phase-Aware Multi-Objective Scoring Weights', fontsize=14, fontweight='bold')
    ax.set_xticks(x)
    ax.set_xticklabels(categories, fontsize=12, fontweight='bold')
    ax.legend()
    ax.grid(axis='y', linestyle='--', alpha=0.7)
    ax.set_ylim(0, 0.8)
    
    # Add value labels
    for i in range(len(categories)):
        ax.text(i - width, latency_weights[i] + 0.02, f'{latency_weights[i]:.2f}', ha='center', fontsize=10)
        ax.text(i, energy_weights[i] + 0.02, f'{energy_weights[i]:.2f}', ha='center', fontsize=10)
        ax.text(i + width, carbon_weights[i] + 0.02, f'{carbon_weights[i]:.2f}', ha='center', fontsize=10)
        
    plt.savefig('docs/diagrams/phase_aware_weights.png', bbox_inches='tight', dpi=300)
    plt.close()

def draw_routing_algorithm_flow():
    fig, ax = plt.subplots(figsize=(8, 10))
    ax.axis('off')
    
    def add_box(x, y, w, h, text, color, shape='rect'):
        if shape == 'rect':
            ax.add_patch(patches.Rectangle((x, y), w, h, fill=True, color=color, ec='black', lw=2))
        elif shape == 'diamond':
            ax.add_patch(patches.Polygon([[x+w/2, y], [x+w, y+h/2], [x+w/2, y+h], [x, y+h/2]], fill=True, color=color, ec='black', lw=2))
        elif shape == 'round':
            ax.add_patch(patches.FancyBboxPatch((x, y), w, h, boxstyle="round,pad=0.05", fill=True, color=color, ec='black', lw=2))
        ax.text(x+w/2, y+h/2, text, ha='center', va='center', fontsize=10, fontweight='bold')

    add_box(0.3, 0.85, 0.4, 0.1, '1. Request Arrives\nIdentify Phase (Prefill/Decode)', '#bbdefb', 'round')
    add_box(0.3, 0.70, 0.4, 0.1, '2. Filter Candidates\nDrop SLO/Thermal Violations', '#ffcc80', 'rect')
    add_box(0.3, 0.55, 0.4, 0.1, '3. Fetch Adaptive Weights\n(Based on Grid Carbon/Power)', '#c8e6c9', 'rect')
    add_box(0.3, 0.40, 0.4, 0.1, '4. Multi-Objective Score\n$S = w_L S_L + w_E S_E + w_C S_C - S_K$', '#e1bee7', 'rect')
    add_box(0.3, 0.25, 0.4, 0.1, '5. Endpoint Selection\nReturn highest scored Endpoint $p^*$', '#cfd8dc', 'round')
    
    # Arrows
    for y in [0.85, 0.70, 0.55, 0.40]:
        ax.annotate('', xy=(0.5, y-0.05), xytext=(0.5, y), arrowprops=dict(facecolor='black', shrink=0.05, width=2))
    
    # Rejected flow
    ax.annotate('', xy=(0.85, 0.75), xytext=(0.7, 0.75), arrowprops=dict(facecolor='red', shrink=0.05, width=2))
    ax.text(0.775, 0.77, 'Violations', ha='center', color='red', fontsize=9)
    add_box(0.85, 0.70, 0.15, 0.1, 'Drop\nRequest', '#ffcdd2', 'round')
    
    plt.title('Algorithm 1: Phase-Aware Routing Pipeline', fontsize=14, fontweight='bold')
    plt.savefig('docs/diagrams/routing_algorithm_flow.png', bbox_inches='tight', dpi=300)
    plt.close()

def draw_sci_calculation_flow():
    fig, ax = plt.subplots(figsize=(9, 6))
    ax.axis('off')
    
    # Components
    ax.add_patch(patches.Rectangle((0.1, 0.7), 0.25, 0.15, fill=True, color='#ffe0b2', ec='black', lw=2))
    ax.text(0.225, 0.775, 'Operational Energy ($E$)\n(kWh)', ha='center', va='center', fontsize=10, fontweight='bold')
    
    ax.add_patch(patches.Rectangle((0.4, 0.7), 0.25, 0.15, fill=True, color='#ffcc80', ec='black', lw=2))
    ax.text(0.525, 0.775, 'Grid Intensity ($I$)\n(gCO₂/kWh)', ha='center', va='center', fontsize=10, fontweight='bold')
    
    ax.add_patch(patches.Rectangle((0.7, 0.7), 0.2, 0.15, fill=True, color='#bcaaa4', ec='black', lw=2))
    ax.text(0.8, 0.775, 'Embodied Carbon\n($M$) (gCO₂)', ha='center', va='center', fontsize=10, fontweight='bold')
    
    # Operational Carbon
    ax.add_patch(patches.Rectangle((0.25, 0.4), 0.25, 0.15, fill=True, color='#ffab91', ec='black', lw=2))
    ax.text(0.375, 0.475, 'Operational Carbon\n($E \\times I$)', ha='center', va='center', fontsize=11, fontweight='bold')
    
    # Total Carbon
    ax.add_patch(patches.Rectangle((0.5, 0.2), 0.25, 0.15, fill=True, color='#ef9a9a', ec='black', lw=2))
    ax.text(0.625, 0.275, 'Total Carbon\n$(E \\times I) + M$', ha='center', va='center', fontsize=11, fontweight='bold')
    
    # Functional Unit
    ax.add_patch(patches.Rectangle((0.8, 0.2), 0.15, 0.15, fill=True, color='#e6ee9c', ec='black', lw=2))
    ax.text(0.875, 0.275, 'Tokens ($R$)\n(Generated)', ha='center', va='center', fontsize=10, fontweight='bold')
    
    # SCI Output
    ax.add_patch(patches.FancyBboxPatch((0.5, -0.05), 0.35, 0.15, boxstyle="round,pad=0.05", fill=True, color='#a5d6a7', ec='black', lw=2))
    ax.text(0.675, 0.025, 'Software Carbon Intensity (SCI)\n$SCI = ((E \\times I) + M) / R$', ha='center', va='center', fontsize=12, fontweight='bold')
    
    # Arrows
    ax.annotate('', xy=(0.35, 0.55), xytext=(0.225, 0.7), arrowprops=dict(facecolor='black', shrink=0.05, width=2))
    ax.annotate('', xy=(0.4, 0.55), xytext=(0.525, 0.7), arrowprops=dict(facecolor='black', shrink=0.05, width=2))
    ax.annotate('', xy=(0.6, 0.35), xytext=(0.375, 0.4), arrowprops=dict(facecolor='black', shrink=0.05, width=2))
    ax.annotate('', xy=(0.65, 0.35), xytext=(0.8, 0.7), arrowprops=dict(facecolor='black', shrink=0.05, width=2))
    ax.annotate('', xy=(0.6, 0.1), xytext=(0.625, 0.2), arrowprops=dict(facecolor='black', shrink=0.05, width=2))
    ax.annotate('', xy=(0.7, 0.1), xytext=(0.875, 0.2), arrowprops=dict(facecolor='black', shrink=0.05, width=2))
    
    plt.title('Green Software Foundation SCI Calculation Flow', fontsize=14, fontweight='bold')
    plt.savefig('docs/diagrams/sci_calculation_flow.png', bbox_inches='tight', dpi=300)
    plt.close()

def draw_inference_timeline_gantt():
    fig, ax = plt.subplots(figsize=(10, 4))
    
    # Task names and temporal start/duration
    tasks = ['Prefill Phase (H100)', 'KV-Cache Transfer (Network)', 'Decode Phase (L4 ASIC)']
    colors = ['#ef5350', '#90caf9', '#66bb6a']
    start_times = [0, 150, 350]
    durations = [150, 200, 800]
    power_draw = ['700W', 'Switch Overhead', '72W']
    
    for i, task in enumerate(tasks):
        ax.barh(task, durations[i], left=start_times[i], color=colors[i], edgecolor='black', height=0.5)
        ax.text(start_times[i] + durations[i]/2, i, f'{durations[i]}ms\n{power_draw[i]}', ha='center', va='center', color='white' if i != 1 else 'black', fontweight='bold', fontsize=10)
        
    # TTFT and TPOT markers
    ax.axvline(x=150, color='r', linestyle='--', label='TTFT (Time-To-First-Token)')
    ax.axvline(x=1150, color='g', linestyle='--', label='Total Request Completion')
    
    ax.set_xlabel('Time (milliseconds)', fontsize=12)
    ax.set_title('Temporal Execution Timeline of Disaggregated Inference', fontsize=14, fontweight='bold')
    ax.invert_yaxis()
    ax.legend()
    ax.grid(axis='x', linestyle=':', alpha=0.6)
    
    plt.savefig('docs/diagrams/inference_timeline_gantt.png', bbox_inches='tight', dpi=300)
    plt.close()

def draw_hardware_spec_comparison():
    fig, ax = plt.subplots(figsize=(9, 6))
    
    hardware = ['H100 80GB\n(Prefill)', 'A100 40GB\n(General)', 'L4 24GB\n(Decode)']
    tdp = [700, 400, 72]
    energy_per_token = [308.7, 381.8, 285.9]
    
    x = np.arange(len(hardware))
    width = 0.35
    
    ax1 = ax
    ax2 = ax1.twinx()
    
    bar1 = ax1.bar(x - width/2, tdp, width, color='#ef5350', label='TDP (W)')
    bar2 = ax2.bar(x + width/2, energy_per_token, width, color='#42a5f5', label='Energy/Token (mJ)')
    
    ax1.set_ylabel('Thermal Design Power (Watts)', fontsize=12, color='#c62828')
    ax2.set_ylabel('Energy per Token (mJ)', fontsize=12, color='#1565c0')
    ax1.set_title('Heterogeneous Hardware Specification Comparison', fontsize=14, fontweight='bold')
    ax1.set_xticks(x)
    ax1.set_xticklabels(hardware, fontsize=12, fontweight='bold')
    
    # Adding values on top of bars
    for i, v in enumerate(tdp):
        ax1.text(i - width/2, v + 10, f'{v}W', ha='center', fontweight='bold')
    for i, v in enumerate(energy_per_token):
        ax2.text(i + width/2, v + 5, f'{v}mJ', ha='center', fontweight='bold')
        
    lines1, labels1 = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines1 + lines2, labels1 + labels2, loc='upper right')
    
    plt.savefig('docs/diagrams/hardware_spec_comparison.png', bbox_inches='tight', dpi=300)
    plt.close()

if __name__ == "__main__":
    print("Generating extra diagrams...")
    draw_epsilon_constraint()
    draw_system_components()
    draw_phase_aware_weights()
    draw_routing_algorithm_flow()
    draw_sci_calculation_flow()
    draw_inference_timeline_gantt()
    draw_hardware_spec_comparison()
    print("Diagrams successfully generated in docs/diagrams/")
