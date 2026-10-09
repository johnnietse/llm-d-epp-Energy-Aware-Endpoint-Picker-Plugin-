import matplotlib.pyplot as plt
import matplotlib.patches as patches
import os

def create_scheduling_pipeline():
    fig, ax = plt.subplots(figsize=(14, 8))
    ax.set_xlim(0, 14)
    ax.set_ylim(0, 8)
    ax.axis('off')
    
    # Title
    plt.text(7, 7.5, "Updated Scheduling Pipeline (Filter → Score → Pick)", 
             fontsize=16, fontweight='bold', ha='center', va='center', color='#1a365d')
    
    # Colors
    bg_color = '#ebf8fa'
    box_color = '#2b6cb0'
    new_box_color = '#2f855a'
    text_color = 'white'
    
    # Draw Background Panels
    ax.add_patch(patches.Rectangle((0.5, 0.5), 4, 6.5, fill=True, color=bg_color, alpha=0.5, lw=2, ec=box_color))
    plt.text(2.5, 6.7, "PHASE 1: FILTER\n(ε-Constraint Enforcement)", fontsize=12, fontweight='bold', ha='center', va='center', color='#2c5282')

    ax.add_patch(patches.Rectangle((5.0, 0.5), 4, 6.5, fill=True, color=bg_color, alpha=0.5, lw=2, ec=box_color))
    plt.text(7.0, 6.7, "PHASE 2: SCORE\n(Multi-Objective)", fontsize=12, fontweight='bold', ha='center', va='center', color='#2c5282')

    ax.add_patch(patches.Rectangle((9.5, 0.5), 4, 6.5, fill=True, color=bg_color, alpha=0.5, lw=2, ec=box_color))
    plt.text(11.5, 6.7, "PHASE 3: PICK\n(Endpoint Selection)", fontsize=12, fontweight='bold', ha='center', va='center', color='#2c5282')

    # Draw Filter Boxes
    filters = [
        ("SLO Constraint Filter\n(TTFT ≤ ε₁, TPOT ≤ ε₂)", box_color),
        ("Energy Budget Filter\n(P < 90% TDP)", box_color),
        ("Thermal Throttling Filter\n(T < 85°C) [NEW]", new_box_color)
    ]
    for i, (text, color) in enumerate(filters):
        y = 5.0 - i*1.8
        ax.add_patch(patches.Rectangle((1.0, y), 3, 1, fill=True, color=color))
        plt.text(2.5, y+0.5, text, fontsize=10, ha='center', va='center', color=text_color, fontweight='bold')
        if i < 2:
            ax.annotate('', xy=(2.5, y-0.8), xytext=(2.5, y), arrowprops=dict(facecolor='black', shrink=0.05, width=2, headwidth=8))

    # Arrow to Score
    ax.annotate('N feasible\nendpoints', xy=(5.0, 3.5), xytext=(4.0, 3.5), arrowprops=dict(facecolor='black', shrink=0.05, width=2, headwidth=8), ha='center', va='center')

    # Draw Scorer Boxes
    scorers = [
        ("Energy-Aware Scorer\n(Phase-Aware Weights)", box_color),
        ("Carbon Intensity Scorer\n(SCI Calculation)", box_color),
        ("KV-Cache Transfer Scorer\n(Network Penalty)", box_color),
        ("RDMA Locality Scorer\n(InfiniBand Bonus) [NEW]", new_box_color)
    ]
    for i, (text, color) in enumerate(scorers):
        y = 5.2 - i*1.4
        ax.add_patch(patches.Rectangle((5.5, y), 3, 0.9, fill=True, color=color))
        plt.text(7.0, y+0.45, text, fontsize=9, ha='center', va='center', color=text_color, fontweight='bold')
        # Arrow to Pick
        ax.annotate('', xy=(9.5, 3.5), xytext=(8.5, y+0.45), arrowprops=dict(facecolor='black', shrink=0.05, width=1, headwidth=6))

    # Draw Pick Box
    ax.add_patch(patches.Rectangle((10.0, 3.0), 3, 1, fill=True, color=box_color))
    plt.text(11.5, 3.5, "MaxScore Picker\n→ Optimal Endpoint p*", fontsize=11, ha='center', va='center', color=text_color, fontweight='bold')

    plt.tight_layout()
    
    os.makedirs('docs/diagrams', exist_ok=True)
    plt.savefig('docs/diagrams/scheduling_pipeline.png', dpi=300, bbox_inches='tight')
    plt.close()


def create_telemetry_model():
    fig, ax = plt.subplots(figsize=(14, 8))
    ax.set_xlim(0, 14)
    ax.set_ylim(0, 8)
    ax.axis('off')
    
    # Title
    plt.text(7, 7.5, "Updated Telemetry and Signal Processing Model", 
             fontsize=16, fontweight='bold', ha='center', va='center', color='#1a365d')
    
    box_color = '#2b6cb0'
    new_box_color = '#2f855a'
    store_color = '#edf2f7'
    text_color = 'white'
    
    # Writers
    plt.text(2.5, 6.7, "Writer Goroutines\n(Background Async)", fontsize=12, fontweight='bold', ha='center', va='center', color='#2c5282')
    writers = [
        ("DCGM GPU Scraper", box_color),
        ("RAPL CPU Scraper", box_color),
        ("Carbon API Scraper", box_color),
        ("eBPF Map Reader [NEW]", new_box_color),
        ("Stale Profile Evictor", box_color)
    ]
    for i, (text, color) in enumerate(writers):
        y = 5.5 - i*1.2
        ax.add_patch(patches.Rectangle((1.0, y), 3, 0.8, fill=True, color=color))
        plt.text(2.5, y+0.4, text, fontsize=10, ha='center', va='center', color=text_color, fontweight='bold')
        ax.annotate('', xy=(5.0, y+0.4), xytext=(4.0, y+0.4), arrowprops=dict(facecolor='black', shrink=0.05, width=1.5, headwidth=7))

    # EnergyStore
    ax.add_patch(patches.Rectangle((5.0, 0.5), 4, 6.5, fill=True, color=store_color, lw=2, ec=box_color))
    plt.text(7.0, 6.5, "EnergyStore\n(sync.RWMutex Telemetry Hub)", fontsize=11, fontweight='bold', ha='center', va='center', color='#2c5282')
    
    ax.add_patch(patches.Rectangle((5.2, 4.5), 3.6, 1.5, fill=True, color='white', lw=1, ec='gray'))
    plt.text(7.0, 5.25, "Time-Aware EWMA\nα = Δt / (τ + Δt)", fontsize=10, ha='center', va='center', fontweight='bold')

    ax.add_patch(patches.Rectangle((5.2, 2.5), 3.6, 1.5, fill=True, color='white', lw=1, ec='gray'))
    plt.text(7.0, 3.25, "Welford's Variance\nσ² Update", fontsize=10, ha='center', va='center', fontweight='bold')
    
    ax.add_patch(patches.Rectangle((5.2, 0.8), 3.6, 1.2, fill=True, color='#ebf8fa', lw=1, ec='gray'))
    plt.text(7.0, 1.4, "EnergyProfile State:\nPower, Temp, RDMA, NUMA", fontsize=9, ha='center', va='center', color='#2c5282', fontweight='bold')

    # Readers
    plt.text(11.5, 6.7, "Reader Goroutines\n(Request Critical Path)", fontsize=12, fontweight='bold', ha='center', va='center', color='#2c5282')
    readers = [
        ("EnergyAware Scorer", box_color),
        ("CarbonIntensity Scorer", box_color),
        ("Thermal Throttling Filter [NEW]", new_box_color),
        ("RDMA Locality Scorer [NEW]", new_box_color)
    ]
    for i, (text, color) in enumerate(readers):
        y = 5.0 - i*1.4
        ax.add_patch(patches.Rectangle((10.0, y), 3, 0.9, fill=True, color=color))
        plt.text(11.5, y+0.45, text, fontsize=9, ha='center', va='center', color=text_color, fontweight='bold')
        ax.annotate('', xy=(10.0, y+0.45), xytext=(9.0, y+0.45), arrowprops=dict(facecolor='black', shrink=0.05, width=1.5, headwidth=7))

    plt.tight_layout()
    plt.savefig('docs/diagrams/telemetry_goroutine_model.png', dpi=300, bbox_inches='tight')
    plt.close()

if __name__ == '__main__':
    create_scheduling_pipeline()
    create_telemetry_model()
    print("Generated updated diagrams successfully.")
