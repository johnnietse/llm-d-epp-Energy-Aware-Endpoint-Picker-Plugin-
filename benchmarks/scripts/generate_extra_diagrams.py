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

if __name__ == "__main__":
    print("Generating extra diagrams...")
    draw_epsilon_constraint()
    draw_system_components()
    draw_phase_aware_weights()
    draw_routing_algorithm_flow()
    print("Diagrams successfully generated in docs/diagrams/")
