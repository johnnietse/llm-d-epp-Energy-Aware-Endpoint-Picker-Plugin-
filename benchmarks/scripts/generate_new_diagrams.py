import os
import matplotlib.pyplot as plt
import matplotlib.patches as patches

def draw_telemetry_model():
    fig, ax = plt.subplots(figsize=(10, 6))
    ax.axis('off')
    
    # Draw Goroutine Scraper Box
    ax.add_patch(patches.Rectangle((0.1, 0.6), 0.3, 0.3, fill=True, color='#e0f7fa', ec='black', lw=2))
    ax.text(0.25, 0.85, 'Telemetry Scraper\n(Goroutine)', ha='center', va='center', fontsize=12, fontweight='bold')
    ax.text(0.25, 0.72, 'time.Ticker(500ms)\nCGO: NVML.GetPower()\nHTTP: CO2Signal API', ha='center', va='center', fontsize=10)
    
    # Draw Energy Store (Thread-safe)
    ax.add_patch(patches.Rectangle((0.55, 0.6), 0.35, 0.3, fill=True, color='#ffe0b2', ec='black', lw=2))
    ax.text(0.725, 0.85, 'EnergyStore\n(sync.RWMutex)', ha='center', va='center', fontsize=12, fontweight='bold')
    ax.text(0.725, 0.72, 'Map[PodID] -> Metrics\n(Kalman Filter Smoothed)', ha='center', va='center', fontsize=10)
    
    # Draw Envoy ext_proc threads
    ax.add_patch(patches.Rectangle((0.55, 0.1), 0.35, 0.3, fill=True, color='#e8f5e9', ec='black', lw=2))
    ax.text(0.725, 0.35, 'gRPC Scoring Threads\n(Envoy ext_proc)', ha='center', va='center', fontsize=12, fontweight='bold')
    ax.text(0.725, 0.22, 'Concurrent Readers\n(mu.RLock() evaluation)', ha='center', va='center', fontsize=10)
    
    # Arrows
    ax.annotate('', xy=(0.55, 0.75), xytext=(0.4, 0.75), arrowprops=dict(facecolor='black', shrink=0.05, width=3))
    ax.text(0.475, 0.8, 'Write Lock\nmu.Lock()', ha='center', va='center', fontsize=10, fontweight='bold')
    
    ax.annotate('', xy=(0.725, 0.4), xytext=(0.725, 0.6), arrowprops=dict(facecolor='black', shrink=0.05, width=3))
    ax.text(0.82, 0.5, 'Read Lock\nmu.RLock()', ha='center', va='center', fontsize=10, fontweight='bold')
    
    plt.title('Asynchronous Telemetry Goroutine Concurrency Model', fontsize=14, fontweight='bold')
    
    os.makedirs('docs/diagrams', exist_ok=True)
    plt.savefig('docs/diagrams/telemetry_goroutine_model.png', bbox_inches='tight', dpi=300)
    plt.close()

def draw_kv_cache_topology():
    fig, ax = plt.subplots(figsize=(10, 6))
    ax.axis('off')
    
    # Source Node (Prefill)
    ax.add_patch(patches.Rectangle((0.05, 0.4), 0.3, 0.4, fill=True, color='#fce4ec', ec='black', lw=2))
    ax.text(0.2, 0.75, 'Prefill Node\n(H100 80GB)', ha='center', va='center', fontsize=12, fontweight='bold')
    ax.text(0.2, 0.55, 'Phase: Prefill\nGenerates KV-Cache\n(e.g., 2.5 GB)', ha='center', va='center', fontsize=10)
    
    # Target Node (Decode)
    ax.add_patch(patches.Rectangle((0.65, 0.4), 0.3, 0.4, fill=True, color='#e8eaf6', ec='black', lw=2))
    ax.text(0.8, 0.75, 'Decode Node\n(L4 24GB)', ha='center', va='center', fontsize=12, fontweight='bold')
    ax.text(0.8, 0.55, 'Phase: Decode\nRequires KV-Cache\nfor Autoregression', ha='center', va='center', fontsize=10)
    
    # Network Switch
    ax.add_patch(patches.Circle((0.5, 0.2), 0.12, fill=True, color='#cfd8dc', ec='black', lw=2))
    ax.text(0.5, 0.2, '100GbE\nTop-of-Rack\nSwitch', ha='center', va='center', fontsize=10, fontweight='bold')
    
    # Arrows
    ax.annotate('', xy=(0.4, 0.25), xytext=(0.2, 0.4), arrowprops=dict(facecolor='blue', shrink=0.05, width=2))
    ax.annotate('', xy=(0.8, 0.4), xytext=(0.6, 0.25), arrowprops=dict(facecolor='blue', shrink=0.05, width=2))
    
    # Text box
    ax.text(0.5, 0.8, 'Transfer Penalty Formulation:\n$E = M_{KV} \\times C_{network}$', ha='center', va='center', fontsize=12, fontweight='bold', color='red', bbox=dict(facecolor='white', edgecolor='red', boxstyle='round,pad=0.5'))
    ax.text(0.5, 0.5, 'Latency: ~200ms\nEnergy: ~15 J', ha='center', va='center', fontsize=10, style='italic')
    
    plt.title('Disaggregated Serving KV-Cache Transfer Topology', fontsize=14, fontweight='bold')
    plt.savefig('docs/diagrams/kv_cache_topology.png', bbox_inches='tight', dpi=300)
    plt.close()

if __name__ == "__main__":
    draw_telemetry_model()
    draw_kv_cache_topology()
    print("Diagrams generated successfully.")
