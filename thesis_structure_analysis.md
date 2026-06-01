# Thesis Structure Analysis: What PhD-Level Papers Include

## Your Current State vs. Research Standards

Your `thesis.md` already has solid bones — 6 chapters, 507 lines, proper math. But compared to published papers in your exact niche, there are clear **gaps** that would weaken a PR or thesis defense. Here's the full breakdown.

---

## 1. Standard Structure (IMRaD + Systems Extensions)

| Section | Standard PhD/Conference | Your `thesis.md` | Status |
|---------|------------------------|-------------------|--------|
| Abstract | ✅ 200-250 words, quantitative claims | ✅ Present, well-written | ✅ Strong |
| Introduction | Problem → Gap → Contributions → Outline | ✅ Present | ✅ Strong |
| Background & Related Work | Deep lit review, 30+ refs | ⚠️ 6 papers in §2, 12 total refs | 🔴 **Major Gap** |
| System Design / Architecture | Diagrams, math, algorithms | ✅ Present, well-structured | ✅ Strong |
| Implementation | Code structure, engineering decisions | ✅ Present | ✅ Strong |
| Evaluation | Multi-experiment, baselines, figures | ⚠️ Only simulation, no baselines | 🔴 **Major Gap** |
| Discussion | Threats to validity, broader impact | ❌ Missing entirely | 🔴 **Major Gap** |
| Conclusion & Future Work | Summary + limitations | ✅ Present | ⚠️ Needs work |
| References | 30-60 citations for thesis, 20-30 for paper | ❌ Only 12 references | 🔴 **Major Gap** |

---

## 2. What's Missing: Section-by-Section

### 2.1 Related Work (Chapter 2) — Currently Thin

Your current related work covers 6 systems. Comparable papers cite **30-50 works**. You need:

#### A. LLM Inference Serving Systems (add ~8 refs)
| Paper | Venue | Why Cite |
|-------|-------|----------|
| vLLM (PagedAttention) | SOSP '23 | ✅ You have this |
| DistServe | OSDI '24 | ✅ You have this |
| Splitwise | ISCA '24 | ✅ You have this |
| **Sarathi-Serve** | OSDI '24 | Chunked-prefill scheduling — directly comparable |
| **Orca** | OSDI '22 | Iteration-level scheduling — foundational |
| **DeepSpeed-FastGen** | MLSys '24 | Dynamic SplitFuse — alternative disaggregation |
| **Mooncake** | arXiv '24 | KV-cache-centric disaggregation — you reference but don't cite |
| **SGLang** | arXiv '24 | RadixAttention for prefix caching |

#### B. Energy-Aware ML Systems (add ~6 refs)
| Paper | Venue | Why Cite |
|-------|-------|----------|
| **Watt Counts** | arXiv '26 | **DIRECTLY comparable** — heterogeneous GPU energy benchmarks for LLM inference |
| **Camel** | arXiv '25 | Energy-aware LLM inference on CPU-GPU heterogeneous systems |
| **HeShare** | 2024/25 | Energy-aware multi-task GPU sharing with DVFS |
| **EcoRL-Sched** | arXiv '24-26 | RL-based energy-aware scheduling across GPU-FPGA |
| **BiScale** | arXiv '26 | ✅ You have this — phase-aware DVFS |
| **throttLLeM** | arXiv '24 | ✅ You have this — SLO-driven GPU frequency control |
| **Zeus** | NSDI '23 | GPU energy optimization framework — seminal |
| **Perseus** | SOSP '24 | Energy-optimal large model training pipeline |

#### C. Kubernetes & Cloud Scheduling (add ~5 refs)
| Paper | Venue | Why Cite |
|-------|-------|----------|
| **WVA (Workload Variant Autoscaler)** | arXiv '26 | **Directly in your ecosystem** — llm-d control plane |
| **Accuracy Is Speed** | arXiv '26 | EPP policy for distributed LLM serving |
| **K8s Perf for GenAI** | arXiv '26 | EPP role in Kubernetes-native inference |
| **Kueue** | CNCF '24 | Kubernetes-native job scheduling |
| **Volcano** | CNCF '23 | Batch scheduling for ML on K8s |

#### D. Carbon-Aware Computing (add ~4 refs)
| Paper | Venue | Why Cite |
|-------|-------|----------|
| Patterson et al. | arXiv '21 | ✅ You have this |
| Dodge et al. | FAccT '22 | ✅ You have this |
| **CarbonScaler** | ASPLOS '24 | Temporal + spatial carbon-aware scheduling |
| **Ecovisor** | ASPLOS '23 | Carbon-efficient cloud platform |
| **Let's Wait Awhile** | HPCA '22 | Delay-tolerant workload shifting for carbon |

---

### 2.2 Evaluation (Chapter 5) — Currently Weak

> [!WARNING]
> This is the **most critical gap**. Your evaluation is currently 3 pages of unit-test-level verification. Comparable papers have **10-15 pages** of multi-dimensional evaluation.

#### What Comparable Papers Include in Evaluation:

##### A. Experimental Setup Table (you need this)
```
Table X: Experimental Configuration
────────────────────────────────────────────────────────
Parameter              Value
────────────────────────────────────────────────────────
GPU Types              A100-40GB (400W), A100-40GB (250W cap),
                       H100-80GB (700W), L4-24GB (72W)
Model                  Meta-Llama-3-8B (simulated profiles)
Serving Framework      vLLM v0.6.x (calibrated throughput)
Request Rates          1, 2, 3, 5, 8, 10, 15, 20, 30, 50 RPS
Input/Output Lengths   256/100 tokens (default), 512/200 (prefill)
Metrics Collected      Power (W), TPS, Latency (p50/p95/p99),
                       Energy per Token (mJ), Failures
Measurement Interval   2 seconds (nvidia-smi equivalent)
Samples per GPU        1200 time-series + 10 load tests
────────────────────────────────────────────────────────
```

##### B. Experiments You Should Have (mapped to your figures)

| # | Experiment | Figure Type | Status |
|---|-----------|-------------|--------|
| E1 | Power vs Throughput across GPUs | Line chart | ✅ **fig1** (done) |
| E2 | Energy per Token vs Load | Line chart (log-x) | ✅ **fig2** (done) |
| E3 | Tokens/Watt efficiency comparison | Bar chart | ✅ **fig3** (done) |
| E4 | Latency-Throughput tradeoff | Line chart + SLO line | ✅ **fig4** (done) |
| E5 | Power time series with artifacts | Dual-panel time series | ✅ **fig5** (done) |
| E6 | Energy savings waterfall | Bar chart + % annotations | ✅ **fig6** (done) |
| E7 | **Scoring accuracy under different modes** | Table or heatmap | ❌ **Missing** |
| E8 | **Adaptive controller mode transitions** | State timeline chart | ❌ **Missing** |
| E9 | **CDF of latency distribution** | CDF plot | ❌ **Missing** |
| E10 | **Sensitivity analysis (weight tuning)** | Multi-line chart | ❌ **Missing** |
| E11 | **Prefill vs Decode phase comparison** | Grouped bar chart | ❌ **Missing** |
| E12 | **SCI (carbon footprint) comparison** | Bar chart with CO2 labels | ❌ **Missing** |
| E13 | **Baseline comparison table** | Summary table | ❌ **Missing** |
| E14 | **Failure rate vs load** | Line chart | ❌ **Missing** |
| E15 | **Overhead analysis (scoring latency)** | Micro-benchmark table | ❌ **Missing** |

##### C. Baselines You Must Compare Against

Every systems paper compares against baselines. You should have:

| Baseline | Description | Why |
|----------|-------------|-----|
| **Round-Robin** | Equal distribution across all GPUs | Standard default — proves energy-aware is better |
| **Latency-Only** | Always pick lowest-latency GPU (H100) | Proves energy cost of latency-optimal |
| **Power-Proportional** | Route proportional to TDP inverse | Naive energy heuristic — proves your model is smarter |
| **Random** | Uniform random selection | Lower bound |
| **Oracle** | Perfect knowledge, optimal selection | Upper bound for your savings |

##### D. Sensitivity Analysis

Top papers always include "what happens when we change parameters":
- What if carbon intensity varies from 30 → 800 gCO2/kWh?
- What if the weight vectors are poorly tuned?
- What if the L4 fleet is 2x, 3x, 4x the size of the A100 fleet?
- What if SLO targets are tightened from 3000ms → 500ms p99?

---

### 2.3 Discussion Section — Currently Missing Entirely

> [!IMPORTANT]
> Every PhD thesis and top-tier paper has a Discussion section. Yours doesn't.

It should cover:

1. **Threats to Validity**
   - Internal: Synthetic data, not real GPU measurements
   - External: Single model size (8B), single sequence length distribution
   - Construct: Energy-per-token approximation vs. true per-request metering

2. **Broader Impact**
   - At scale (1000 GPUs, 10M requests/day), what are the projected savings?
   - How does this interact with carbon markets and corporate ESG reporting?
   - Could energy-aware routing create fairness issues (slower responses in high-carbon regions)?

3. **Comparison with Concurrent Work**
   - WVA paper (arXiv '26) — how does your EPP complement their autoscaler?
   - Watt Counts benchmark — how do your synthetic results compare to their real measurements?

---

## 3. Architecture Diagrams You Should Have

| Diagram | Purpose | Status |
|---------|---------|--------|
| System-level architecture (EPP in K8s) | Show where your plugin sits | Referenced but may not exist |
| Scheduling pipeline flowchart | Filter → Score → Pick | Referenced |
| Adaptive controller FSM | Mode transitions | Referenced |
| **Data flow diagram** | Telemetry → Store → Scorers | ❌ Missing |
| **Deployment topology** | Multi-node cluster layout | ❌ Missing |
| **Comparison with baseline architectures** | Side-by-side vs round-robin | ❌ Missing |

---

## 4. Your Thesis vs. Comparable Published Papers

| Aspect | Your Thesis | Watt Counts (arXiv '26) | WVA (arXiv '26) | Splitwise (ISCA '24) |
|--------|------------|------------------------|-----------------|---------------------|
| Pages | ~15 (507 lines md) | 12 | 10 | 14 |
| References | 12 | ~45 | ~35 | ~50 |
| GPU Types Tested | 4 (synth) | 6 (real) | 3+ (real) | 2 (real) |
| Evaluation Figures | 6 | 12 | 8 | 10 |
| Baselines | 1 (RR) | 4 | 3 | 3 |
| Real Hardware | ❌ | ✅ | ✅ | ✅ |
| Sensitivity Analysis | ❌ | ✅ | ✅ | ✅ |
| Discussion Section | ❌ | ✅ | ✅ | ✅ |

---

## 5. Priority Action Items

### Tier 1: Critical (must-do for PR credibility)

1. **Add 6 more figures** (E7-E12) using existing realistic data
2. **Add baseline comparison table** (Round-Robin vs Energy-Aware vs Latency-Only)
3. **Add a Discussion section** with threats to validity
4. **Expand references to 25+** (add the papers listed above)
5. **Update evaluation numbers** to use realistic data (32% savings, not 63%)

### Tier 2: Important (strengthens significantly)

6. Add sensitivity analysis (vary carbon intensity, SLO targets, fleet composition)
7. Add CDF latency plots showing tail latency improvement
8. Add scoring overhead micro-benchmark
9. Add experimental setup table with full configuration

### Tier 3: Nice-to-have (for thesis defense)

10. Add prefill vs decode phase-specific energy comparison figure
11. Add adaptive controller timeline visualization
12. Add scale-up projection (extrapolate to 100-GPU cluster)

---

> [!TIP]
> **Key insight**: Your thesis.md says "63% energy savings" (§5.4) but your realistic data shows **32.3%**. The 63% figure came from the idealized ASIC comparison (QC AI 100 @ 1.0 mJ/tok). You should update §5.4 to use the realistic heterogeneous GPU data, which is more defensible. You can still mention the ASIC scenario as an upper bound.
