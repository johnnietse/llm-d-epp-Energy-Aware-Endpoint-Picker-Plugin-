import os
import matplotlib.pyplot as plt
import numpy as np

def generate_dvfs_plot():
    labels = ['Static Max Freq\n(Baseline)', 'Phase-Aware DVFS\n(EPP Integrated)']
    prefill = [1.0, 0.95]  # Minimal savings in prefill since it's compute bound
    decode = [1.0, 0.58]   # ~42% savings in decode since it's memory bound

    x = np.arange(len(labels))
    width = 0.35

    fig, ax = plt.subplots(figsize=(8, 6))
    rects1 = ax.bar(x - width/2, prefill, width, label='Prefill Energy (Normalized)', color='#ff9999', edgecolor='black')
    rects2 = ax.bar(x + width/2, decode, width, label='Decode Energy (Normalized)', color='#66b3ff', edgecolor='black')

    ax.set_ylabel('Normalized Energy Consumption', fontweight='bold')
    ax.set_title('Theoretical Impact of Phase-Aware DVFS on Inference Energy', fontsize=14, fontweight='bold')
    ax.set_xticks(x)
    ax.set_xticklabels(labels, fontweight='bold')
    ax.legend()
    
    # Add text labels
    ax.text(1 + width/2, 0.58 + 0.02, '-42% Savings', ha='center', va='bottom', color='red', fontweight='bold')

    plt.ylim(0, 1.2)
    plt.grid(axis='y', linestyle='--', alpha=0.7)

    os.makedirs('docs/diagrams', exist_ok=True)
    plt.savefig('docs/diagrams/dvfs_savings.png', bbox_inches='tight', dpi=300)
    plt.close()

if __name__ == "__main__":
    generate_dvfs_plot()
    print("DVFS plot generated successfully.")
