import time
import pandas as pd
import pynvml
from transformers import AutoModelForCausalLM, AutoTokenizer
import torch

# This script is designed to be run in a Google Colab notebook with a T4 GPU.
# It measures the actual hardware power draw (in Watts) during the Prefill and Decode phases.
# You can use the resulting CSV data to prove your energy modeling assumptions in your thesis!

def get_gpu_power():
    """Returns the current GPU power usage in Watts."""
    pynvml.nvmlInit()
    handle = pynvml.nvmlDeviceGetHandleByIndex(0)
    power_mw = pynvml.nvmlDeviceGetPowerUsage(handle)
    return power_mw / 1000.0

def benchmark_llm_power(model_name="gpt2", prompt="The future of Kubernetes is", max_new_tokens=50):
    print(f"Loading {model_name} onto GPU...")
    tokenizer = AutoTokenizer.from_pretrained(model_name)
    model = AutoModelForCausalLM.from_pretrained(model_name).to("cuda")
    
    inputs = tokenizer(prompt, return_tensors="pt").to("cuda")
    
    metrics = []
    
    # 1. Measure Idle Power
    time.sleep(2)
    idle_power = get_gpu_power()
    print(f"Idle Power: {idle_power:.2f} W")
    
    # 2. Measure Prefill Phase
    print("\nStarting Prefill Phase...")
    prefill_start_time = time.time()
    
    # Run prefill only (generate 1 token)
    with torch.no_grad():
        outputs = model.generate(**inputs, max_new_tokens=1, return_dict_in_generate=True)
    
    prefill_power = get_gpu_power()
    prefill_time = time.time() - prefill_start_time
    
    metrics.append({
        "Phase": "Prefill",
        "Power_W": prefill_power,
        "Duration_s": prefill_time,
        "Energy_Joules": prefill_power * prefill_time,
        "Tokens": inputs.input_ids.shape[1]
    })
    
    # 3. Measure Decode Phase
    print("\nStarting Decode Phase...")
    decode_start_time = time.time()
    
    # Generate remaining tokens
    with torch.no_grad():
        final_outputs = model.generate(**inputs, max_new_tokens=max_new_tokens)
        
    decode_power = get_gpu_power()
    decode_time = time.time() - decode_start_time
    
    metrics.append({
        "Phase": "Decode",
        "Power_W": decode_power,
        "Duration_s": decode_time,
        "Energy_Joules": decode_power * decode_time,
        "Tokens": max_new_tokens
    })
    
    # Save to CSV
    df = pd.DataFrame(metrics)
    csv_filename = "colab_gpu_power_telemetry.csv"
    df.to_csv(csv_filename, index=False)
    
    print("\n=== Benchmark Complete ===")
    print(df.to_string())
    print(f"\nSaved empirical telemetry to {csv_filename}")
    print("You can include this data in your report as real-world T4 NVML power measurements!")

if __name__ == "__main__":
    # Note: In Colab, you need to run `!pip install pynvml transformers torch pandas` first.
    benchmark_llm_power()
