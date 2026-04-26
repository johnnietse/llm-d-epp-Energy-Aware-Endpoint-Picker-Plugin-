# D2 Thesis Diagrams

Because you want high-quality, PhD-level figures, I have translated your most important architectural diagrams into **D2 (Declarative Diagramming)** code. 

D2's layout engine generates incredibly clean, professional vector graphics that are far superior to Mermaid. 

### How to use these:
1. Copy the code blocks below.
2. Go to the **[D2 Playground (play.d2lang.com)](https://play.d2lang.com/)**.
3. Paste the code into the editor. 
4. Select the **"Terminal"** or **"Neutral"** theme (top right) for a very academic look.
5. Apply the **ELK** layout engine (top right) for perfect orthogonal routing.
6. Export as **SVG** for perfect clarity in your thesis.

---

### 1. High-Level System Architecture

This diagram shows the control plane routing intersecting with the data plane telemetry. It uses orthogonal routing for a much cleaner look than Mermaid could provide.

```d2
direction: right

classes: {
  core: {
    style: {
      fill: "#f8fafc"
      stroke: "#334155"
      stroke-width: 2
      border-radius: 8
    }
  }
  pod: {
    style: {
      fill: "#fffbeb"
      stroke: "#d97706"
      stroke-width: 2
      shadow: true
    }
  }
  telemetry: {
    style: {
      fill: transparent
      stroke: "#94a3b8"
      stroke-dash: 5
    }
  }
}

Client: Client Application
Grid: Grid Carbon API\n(CO2Signal) { class: telemetry }

Kubernetes Cluster: {
  style: {
    fill: transparent
    stroke: "#cbd5e1"
    stroke-dash: 3
  }

  Gateway: Envoy Gateway\n(Inference Extension) { class: core }
  EPP: Energy-Aware EPP\n(Sidecar Service) { class: core }

  Disaggregated Inference Pools: {
    style: { fill: transparent; stroke: transparent }
    
    Node 1: NVIDIA H100\n(Prefill Pool) { class: pod }
    Node 2: NVIDIA A100\n(Decode Pool) { class: pod }
    Node 3: QC AI 100\n(Decode Pool) { class: pod }
  }

  Hardware Telemetry: {
    style: { fill: transparent; stroke: transparent }
    
    DCGM: DCGM Exporter\n(GPU Power) { class: telemetry }
    RAPL: RAPL Exporter\n(ASIC Power) { class: telemetry }
  }

  Gateway -> EPP: ext_proc (gRPC)\nRouting Policy
  
  Gateway -> Disaggregated Inference Pools.Node 1: HTTP Proxy
  Gateway -> Disaggregated Inference Pools.Node 2: HTTP Proxy
  Gateway -> Disaggregated Inference Pools.Node 3: HTTP Proxy

  Hardware Telemetry.DCGM -> EPP: Async Poll (5s)
  Hardware Telemetry.RAPL -> EPP: Async Poll (5s)
}

Client -> Kubernetes Cluster.Gateway: Inference Request\n(OpenAI API)
Grid -> Kubernetes Cluster.EPP: Async Poll (5m)

```

---

### 2. EPP Scheduling Execution Pipeline

This diagram shows the strict hierarchical flow of filtering, scoring, and picking candidate pods.

```d2
direction: right

classes: {
  input: { shape: rounded }
  filter: { style: { fill: "#fef2f2"; stroke: "#dc2626"; shadow: true } }
  scorer: { style: { fill: "#eff6ff"; stroke: "#2563eb"; shadow: true } }
  data: { shape: cylinder; style: { fill: "#fafaf9" } }
}

Input: Incoming Request\n+ Candidate Pods { class: input }
Store: EnergyStore\n(Telemetry Cache) { class: data }

1. Hard Constraints (Filters): {
  style: { fill: transparent; stroke: "#cbd5e1"; stroke-dash: 3 }
  SLO: SLO Constraint\nTTFT / TPOT bounds { class: filter }
  Budget: Power Budget\nTDP Headroom { class: filter }
  SLO -> Budget
}

2. Soft Objectives (Batch Scorers): {
  style: { fill: transparent; stroke: "#cbd5e1"; stroke-dash: 3 }
  Energy: Energy Scorer\nPhase-aware Weights { class: scorer }
  Carbon: Carbon Scorer\nGrid-aware SCI { class: scorer }
  Cache: Cache Scorer\nTransfer Penalty { class: scorer }
}

Aggregation: Score Aggregation\nSum of weighted scores { shape: hexagon }
Pick: MaxScore Picker\nArgmax(Total Score)
Output: Target Destination IP { class: input }

Input -> 1. Hard Constraints (Filters).SLO

Store -> 1. Hard Constraints (Filters).Budget: Reads
Store -> 2. Soft Objectives (Batch Scorers): Reads

1. Hard Constraints (Filters).Budget -> 2. Soft Objectives (Batch Scorers).Energy: Feasible Candidates
1. Hard Constraints (Filters).Budget -> 2. Soft Objectives (Batch Scorers).Carbon
1. Hard Constraints (Filters).Budget -> 2. Soft Objectives (Batch Scorers).Cache

2. Soft Objectives (Batch Scorers).Energy -> Aggregation
2. Soft Objectives (Batch Scorers).Carbon -> Aggregation
2. Soft Objectives (Batch Scorers).Cache -> Aggregation

Aggregation -> Pick
Pick -> Output
```

---

### 3. Adaptive Weight Controller FSM

This Finite State Machine uses D2's specific state diagram syntax for incredibly clean routing transitions.

```d2
direction: right

classes: {
  state: { style: { border-radius: 8; stroke-width: 2 } }
  normal: { class: state; style: { fill: "#f0fdf4"; stroke: "#16a34a" } }
  critical: { class: state; style: { fill: "#fef9c3"; stroke: "#ca8a04" } }
  emergency: { class: state; style: { fill: "#fef2f2"; stroke: "#dc2626" } }
}

Normal Mode: {
  class: normal
  tooltip: "Prefill favors Latency\nDecode favors Energy"
}

Carbon Critical Mode: {
  class: critical
  tooltip: "Global +20% shift toward Energy/Carbon"
}

Emergency Mode: {
  class: emergency
  tooltip: "Power cap enforced. Latency ignored."
}

Normal Mode -> Carbon Critical Mode: Grid CO2 > 500 g/kWh
Carbon Critical Mode -> Normal Mode: Grid CO2 < 500 g/kWh

Normal Mode -> Emergency Mode: Cluster Power > 95%
Carbon Critical Mode -> Emergency Mode: Cluster Power > 95%

Emergency Mode -> Normal Mode: Power < 85%
```

---

### 4. Telemetry Concurrency Model

D2 renders sequence diagrams with beautiful, academic-grade typography and spacing by default.

```d2
shape: sequence_diagram

DCGM & RAPL: Hardware Exporters
CO2 API: External Grid Signal

box: EPP Sidecar Context {
  Scraper: Async Pollers
  Store: Shared EnergyStore\n[RWMutex]
  Router: Routing Engine
}

# High-frequency hardware loop
Scraper -> DCGM & RAPL: Scrape Metrics (Every 5s)
DCGM & RAPL -> Scraper: Hardware Power Draw
Scraper -> Store: Lock(Write)
Scraper -> Store: Update Pod Telemetry
Store -> Scraper: Unlock()

# Low-frequency carbon loop
Scraper -> CO2 API: Fetch Electricity Map (Every 5m)
CO2 API -> Scraper: Intensity (gCO2/kWh)
Scraper -> Store: Lock(Write)
Scraper -> Store: Update External Signals
Store -> Scraper: Unlock()

# Synchronous routing loop
Router -> Store: On Request: Lock(Read)
Store -> Router: Retrieve Profiles
Router -> Router: Evaluate Filters & Scorers
Router -> Store: Unlock()
```
