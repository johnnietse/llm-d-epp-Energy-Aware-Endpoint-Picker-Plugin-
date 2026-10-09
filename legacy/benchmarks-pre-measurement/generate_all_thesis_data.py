import time
import pandas as pd
import pynvml
import torch
import matplotlib.pyplot as plt
import seaborn as sns
from transformers import AutoModelForCausalLM, AutoTokenizer

# ==========================================
# ELEC 498 / MASTER'S THESIS BENCHMARK SUITE
# ==========================================

def get_gpu_power():
    handle = pynvml.nvmlDeviceGetHandleByIndex(0)
    return pynvml.nvmlDeviceGetPowerUsage(handle) / 1000.0

def run_benchmarks():
    print("Initializing NVML and loading model...")
    pynvml.nvmlInit()
    
    # Using OPT-125m as it easily fits on a free Colab T4 GPU but exhibits standard LLM phase behaviors
    model_name = "facebook/opt-125m"
    tokenizer = AutoTokenizer.from_pretrained(model_name)
    tokenizer.pad_token = tokenizer.eos_token
    model = AutoModelForCausalLM.from_pretrained(model_name).to("cuda")
    
    print("\n" + "="*50)
    print("EXPERIMENT 1: PREFILL VS DECODE ENERGY PROFILING")
    print("="*50)
    
    prompts = [
        "The fundamental challenge in scaling large language models is",
        "Kubernetes provides container orchestration but lacks native support for",
        "Energy efficiency in data centers requires careful consideration of hardware accelerators like GPUs and TPUs because"
    ]
    
    phase_data = []
    
    for i, prompt in enumerate(prompts):
        print(f"\nRunning test {i+1}...")
        inputs = tokenizer(prompt, return_tensors="pt").to("cuda")
        input_length = inputs.input_ids.shape[1]
        
        # 1. PREFILL PHASE
        time.sleep(1) # Let GPU settle
        start_time = time.time()
        with torch.no_grad():
            outputs = model.generate(**inputs, max_new_tokens=1, return_dict_in_generate=True)
        prefill_time = time.time() - start_time
        prefill_power = get_gpu_power()
        
        phase_data.append({
            "Test": i+1,
            "Phase": "Prefill",
            "Tokens": input_length,
            "Power_W": prefill_power,
            "Time_s": prefill_time,
            "Energy_Joules": prefill_power * prefill_time
        })
        
        # 2. DECODE PHASE
        time.sleep(1)
        start_time = time.time()
        with torch.no_grad():
            final_outputs = model.generate(**inputs, max_new_tokens=100)
        decode_time = time.time() - start_time
        decode_power = get_gpu_power()
        
        phase_data.append({
            "Test": i+1,
            "Phase": "Decode",
            "Tokens": 100,
            "Power_W": decode_power,
            "Time_s": decode_time,
            "Energy_Joules": decode_power * decode_time
        })

    df_phase = pd.DataFrame(phase_data)
    df_phase.to_csv("experiment1_phase_energy.csv", index=False)
    print("\nExperiment 1 Complete. Saved to experiment1_phase_energy.csv")
    
    print("\n" + "="*50)
    print("EXPERIMENT 2: BATCH SIZE SCALING EFFICIENCY")
    print("="*50)
    
    batch_sizes = [1, 2, 4, 8, 16]
    batch_data = []
    
    for b in batch_sizes:
        print(f"Testing Batch Size: {b}")
        batch_prompts = ["Energy aware scheduling is critical."] * b
        inputs = tokenizer(batch_prompts, return_tensors="pt", padding=True).to("cuda")
        
        time.sleep(1)
        start_time = time.time()
        with torch.no_grad():
            outputs = model.generate(**inputs, max_new_tokens=50)
        total_time = time.time() - start_time
        avg_power = get_gpu_power()
        
        total_tokens_generated = b * 50
        energy_joules = avg_power * total_time
        tokens_per_joule = total_tokens_generated / energy_joules
        
        batch_data.append({
            "Batch_Size": b,
            "Power_W": avg_power,
            "Total_Time_s": total_time,
            "Total_Energy_Joules": energy_joules,
            "Total_Tokens": total_tokens_generated,
            "Tokens_Per_Joule": tokens_per_joule
        })
        
    df_batch = pd.DataFrame(batch_data)
    df_batch.to_csv("experiment2_batch_efficiency.csv", index=False)
    print("\nExperiment 2 Complete. Saved to experiment2_batch_efficiency.csv")
    
    # ==========================================
    # GENERATE THESIS PLOTS
    # ==========================================
    print("\nGenerating Academic Plots...")
    sns.set_theme(style="whitegrid")
    
    # Plot 1
    plt.figure(figsize=(8, 5))
    sns.barplot(data=df_phase, x="Phase", y="Power_W", capsize=.1)
    plt.title("Average GPU Power Draw: Prefill vs Decode Phase")
    plt.ylabel("Power (Watts)")
    plt.savefig("fig1_phase_power.png", dpi=300, bbox_inches='tight')
    
    # Plot 2
    plt.figure(figsize=(8, 5))
    sns.lineplot(data=df_batch, x="Batch_Size", y="Tokens_Per_Joule", marker="o", linewidth=2.5)
    plt.title("Energy Efficiency vs. Batch Size")
    plt.ylabel("Tokens Generated per Joule")
    plt.xlabel("Batch Size")
    plt.xticks(batch_sizes)
    plt.savefig("fig2_batch_efficiency.png", dpi=300, bbox_inches='tight')
    
    print("\nPlots saved as fig1_phase_power.png and fig2_batch_efficiency.png!")
    print("ALL DONE! Download the CSVs and PNGs from the Colab file browser.")

if __name__ == "__main__":
    run_benchmarks()
