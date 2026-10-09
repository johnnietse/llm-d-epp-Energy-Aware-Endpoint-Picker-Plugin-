# Benchmark Plan: What to Test Before Submitting the PR

## The Question You Need to Answer

The llm-d maintainers will ask: **"Does this actually save energy without hurting latency?"**

You need 3 proofs:
1. **Real power data** — measured on actual GPUs, not synthetic
2. **Correct routing** — prefill goes to high-TDP, decode goes to low-power
3. **Quantified savings** — X% energy reduction with ≤Y% latency impact

## What You Have on Frontenac

| Resource | What It Is |
|----------|-----------|
| GPUs | NVIDIA A100-40GB SXM (400W TDP) |
| Partitions | `gpubase_6hrs` (1 GPU), `gpubase_bynode_24hrs` (multi-GPU) |
| Software | Apptainer (containers), CUDA 11.6, Python 3.11 |
| Power Monitoring | `nvidia-smi` (instant readings, 2s poll) |

## The 5 Experiments

### Experiment 1: GPU Power Profile (Idle → Full Load)
**What:** Measure A100 power draw from idle through increasing load  
**Why:** Proves power is non-linear (you can't just assume TDP = actual power)  
**How:**

```bash
sbatch benchmarks/scripts/frontenac/02-profile-gpu.sbatch
```

**Output Data:**
- `power_timeseries.csv` — power every 2 seconds for ~1 hour
- `gpu_profile_summary.json` — idle/load/max power
- `load_rps_{1,2,5,10,20}.json` — throughput at each request rate

**Figure to generate:** Power Timeline (Figure 1)

---

### Experiment 2: Power Sweep (Simulated Heterogeneity)
**What:** Run 2 GPUs simultaneously with different power caps to simulate heterogeneous hardware  
**Why:** Proves that energy-per-token varies between endpoints with different power profiles  
**How:**

```bash
sbatch benchmarks/scripts/frontenac/03-power-sweep.sbatch
```

This uses `nvidia-smi -pl` to set different power limits on 2 GPUs:
- GPU 0: 400W (full power, simulates "prefill-optimized H100")
- GPU 1: 200W (power-capped, simulates "decode-optimized A100-cap")

**Output Data:**
- `sweep_gpu0.csv` — GPU0 throughput and power at each RPS
- `sweep_gpu1.csv` — GPU1 throughput and power at each RPS

**Figure to generate:** EPT vs Load (Figure 2)

---

### Experiment 3: EPP Scoring with Real Data
**What:** Feed the measured power/throughput data into your EPP scorer  
**Why:** Proves the algorithm assigns correct scores given real hardware measurements  
**How:**

```bash
bash benchmarks/scripts/frontenac/04-run-epp-scoring.sh <RESULTS_DIR>
```

**Output Data:**
- `epp_output.txt` — scoring table showing prefill vs decode selections
- `measured_profiles.json` — the profiles used for scoring

**Figure to generate:** Scoring Comparison (Figure 3)

---

### Experiment 4: Prefill vs Decode Phase Comparison
**What:** Run identical requests but vary max_tokens (200 for prefill, 20 for decode) 
**Why:** Shows the different energy profiles of the two inference phases  
**How:** Already built into `02-profile-gpu.sbatch` (lines 210-217)

**Output Data:**
- `prefill_profile.json` — latency and throughput for prefill-heavy
- `decode_profile.json` — latency and throughput for decode-heavy

**Figure to generate:** Phase Energy Comparison (Figure 4)

---

### Experiment 5: Routing Simulation (1000 Cycles)
**What:** Run 1000 scoring cycles with the measured profiles, comparing energy-aware vs round-robin  
**Why:** Proves aggregate energy savings over a statistically significant sample  
**How:** Use your existing standalone mode:

```bash
./bin/energy-epp --mode standalone --cycles 1000 \
    --profiles benchmarks/results/frontenac/<RESULTS_DIR>/measured_profiles.json
```

**Output Data:**
- Per-cycle routing decisions
- Aggregate energy consumption comparison

**Figure to generate:** Cumulative Energy Savings (Figure 5)

---

## The 7 Figures You Need

| # | Figure | What It Proves | Type |
|---|--------|---------------|------|
| 1 | **Power Timeline** | GPU power is dynamic, not constant TDP | Line chart |
| 2 | **EPT vs Load** | Energy-per-token varies with load and power cap | Bar chart (side-by-side) |
| 3 | **Scoring Comparison** | Prefill→high-TDP, Decode→low-power routing is correct | Grouped bar chart |
| 4 | **Phase Energy Profile** | Prefill and decode have different energy characteristics | Dual bar chart |
| 5 | **Cumulative Energy Savings** | Energy-aware routing saves X% vs baseline over 1000 cycles | Line chart |
| 6 | **Token Economics** | kWh, gCO₂, $/1M tokens across endpoints | Triple bar chart |
| 7 | **Carbon Sensitivity** | Savings vary by grid region (Ontario vs US-AVG vs Germany) | Heatmap or table |

### Figure 1: Power Timeline
```
Y: GPU Power (W)    
X: Time (seconds)
Shows: idle → warmup → 1 RPS → 2 RPS → 5 RPS → 10 RPS → 20 RPS
Proves: Power is dynamic and non-linear with load
```

### Figure 2: Energy-per-Token vs Load (Key Figure)
```
Two side-by-side bar charts:
  Left:  GPU at 400W cap (prefill-optimized) — EPT at each RPS
  Right: GPU at 200W cap (decode-optimized)  — EPT at each RPS
Shows: Power-capped GPU has LOWER EPT for decode despite lower throughput
Proves: The fundamental premise — low-power hardware is more energy-efficient for decode
```

### Figure 3: Scorer Output Validation
```
Grouped bar chart:
  X-axis: Endpoints (gpu-400w, gpu-200w, etc.)
  Bars: Prefill score (blue) vs Decode score (orange)
Shows: High-TDP gets highest prefill score, low-power gets highest decode score
Proves: The scorer routes correctly
```

### Figure 4: Prefill vs Decode Phase Energy
```
Side-by-side comparison:
  Prefill: high power, high throughput, moderate EPT
  Decode:  lower power needed, throughput limited by memory bandwidth
Shows: The two phases have fundamentally different power/throughput profiles
Proves: Phase-aware routing is necessary (one-size-fits-all is wrong)
```

### Figure 5: Cumulative Energy Savings (Most Important for PR)
```
Line chart over 1000 routing cycles:
  Blue line:  Cumulative energy with energy-aware routing
  Red line:   Cumulative energy with round-robin routing
  Green line: Cumulative energy with load-aware-only routing
  Gap between lines = energy savings
Shows: Energy-aware routing consistently uses less total energy
Proves: The scorer provides measurable, sustained energy savings
```

### Figure 6: Token Economics Table
```
Triple bar chart:
  Three panels: kWh/1M tokens | gCO₂/1M tokens | $/1M tokens
  Each panel: bars for each endpoint type
Shows: Concrete economic impact of routing decisions
Proves: Energy savings translate to real cost and carbon savings
```

### Figure 7: Carbon Sensitivity
```
Table or heatmap:
  Rows: Grid regions (Ontario, California, US-AVG, Germany, France)
  Columns: Routing strategy (energy-aware vs baseline)
  Values: gCO₂ per 1M tokens
Shows: Savings amplified on dirty grids, still present on clean grids
Proves: The approach generalizes across deployment regions
```

## Exact Execution Sequence on Frontenac

```bash
# Step 0: Transfer project to Frontenac (from your Windows machine)
scp -r . sa6079052@login.cac.queensu.ca:~/energy-epp/

# Step 1: SSH in and set up
ssh sa6079052@login.cac.queensu.ca
cd ~/energy-epp
bash benchmarks/scripts/frontenac/01-setup-env.sh

# Step 2: Submit GPU profiling job (~2 hours)
sbatch benchmarks/scripts/frontenac/02-profile-gpu.sbatch
# Monitor with: squeue -u $USER
# Wait for completion

# Step 3: Submit power sweep job (~2 hours)
sbatch benchmarks/scripts/frontenac/03-power-sweep.sbatch
# Wait for completion

# Step 4: Run EPP scoring with real data (~5 minutes)
bash benchmarks/scripts/frontenac/04-run-epp-scoring.sh \
    ~/energy-epp/benchmarks/results/frontenac/<latest_profile_dir>

# Step 5: Generate figures (~2 minutes)
python3 benchmarks/scripts/frontenac/05-analyze-frontenac.py \
    ~/energy-epp/benchmarks/results/frontenac/

# Step 6: Download results to your Windows machine
# (From Windows):
scp -r sa6079052@login.cac.queensu.ca:~/energy-epp/benchmarks/results/frontenac/ \
    ./benchmarks/results/frontenac/
```

## What Goes in the PR

### Evidence Section (in PR description)

```markdown
## Validation Results

Tested on Queen's University Frontenac 2.0 HPC (NVIDIA A100-40GB SXM).

### Key Results
- **Energy savings:** XX% reduction in energy-per-token for decode phase
  when routing to power-capped endpoints vs full-power endpoints
- **Latency impact:** <Y% increase in p50 latency (within SLO)
- **Correct routing:** Prefill consistently routed to highest-TDP endpoint,
  decode consistently routed to lowest-EPT endpoint across 1000 cycles

### Figures
1. [Power Timeline] — proves dynamic power measurement works
2. [EPT vs Load]    — proves energy-per-token varies across hardware configs
3. [Scoring Output] — proves scorer assigns correct phase-aware scores
4. [Cumulative Savings] — proves sustained energy reduction over 1000 cycles

### Measurement Methodology
- Power: nvidia-smi polling at 2-second intervals
- Throughput: vLLM OpenAI-compatible API, measured tokens/second
- Model: facebook/opt-1.3b (representative compute profile)
- Heterogeneity: Simulated via nvidia-smi power limiting (400W vs 200W)
```

## Timeline

| Day | What | Time |
|-----|------|------|
| Day 1 | Transfer code to Frontenac, run `01-setup-env.sh` | 30 min |
| Day 1 | Submit `02-profile-gpu.sbatch`, wait for completion | 2-3 hrs |
| Day 2 | Submit `03-power-sweep.sbatch`, wait for completion | 2-3 hrs |
| Day 2 | Run `04-run-epp-scoring.sh` + `05-analyze-frontenac.py` | 15 min |
| Day 2 | Download results, review figures | 30 min |
| Day 3 | Open GitHub issue + submit PR with evidence | 1 hr |

**Total: ~2-3 days of wall time** (mostly waiting for SLURM queue).

## What "Good" Results Look Like

You want to see numbers like:

| Metric | Energy-Aware | Round-Robin | Savings |
|--------|-------------|-------------|---------|
| Energy/token (decode) | ~0.27 mJ | ~0.55 mJ | **~50%** |
| Energy/1M tokens | ~0.08 kWh | ~0.15 kWh | **~47%** |
| CO₂/1M tokens (Ontario) | ~2.4 g | ~4.5 g | **~47%** |
| p50 latency | +5-10% | baseline | acceptable |

> [!IMPORTANT]
> Even if the savings are smaller (e.g., 15-20%), that's still publishable and PR-worthy.
> The key claim is that **energy-aware routing produces measurable savings without 
> significantly degrading latency**, not that the savings are enormous.
