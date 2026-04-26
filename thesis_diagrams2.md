# Thesis Diagrams (Professional Academic Styling)

These diagrams have been restyled with custom clean, modern, and academic themes. When exported, they will look highly professional and readable, suitable for a PhD-level document. 

To export these for your thesis:
1. Go to [Mermaid Live Editor](https://mermaid.live/).
2. Paste the code blocks below.
3. Export as **SVG** for perfect scaling in LaTeX, or **PNG** for Microsoft Word.

---

## 1. System Architecture: Control and Data Planes

**Caption**: *Figure 1: High-level architecture of the energy-aware LLM inference serving system. The system integrates via the Kubernetes Gateway API Inference Extension. Request routing (control plane) intersects with telemetry ingestion (data plane) at the Endpoint Picker Plugin (EPP).*

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'fontFamily': 'Inter, Arial, sans-serif', 'primaryColor': '#F8FAFC', 'primaryBorderColor': '#94A3B8', 'lineColor': '#475569', 'textColor': '#0F172A', 'fontSize': '14px'}}}%%
graph LR
    classDef client fill:#FFFFFF,stroke:#64748B,stroke-width:2px,rx:8;
    classDef gateway fill:#F0F9FF,stroke:#0284C7,stroke-width:2px,rx:8;
    classDef epp fill:#F0FDF4,stroke:#16A34A,stroke-width:2px,rx:8;
    classDef pod fill:#FFFBEB,stroke:#D97706,stroke-width:2px,rx:8;
    classDef external fill:#F8FAFC,stroke:#94A3B8,stroke-width:2px,stroke-dasharray: 5 5,rx:8;
    
    Client(("<b>Client</b>")):::client

    subgraph Cluster ["<b>Kubernetes Cluster</b>"]
        direction TB
        GW["<b>Envoy Gateway</b><br/>Inference Extension"]:::gateway
        
        EPP["<b>Energy-Aware EPP</b><br/>Sidecar Service"]:::epp
        
        GW -- "ext_proc (gRPC)" <br/> Routing Policy --> EPP
        
        subgraph Pools ["<b>Disaggregated Inference Pools</b>"]
            direction LR
            P1["<b>Node 1</b><br/>NVIDIA H100<br/>(Prefill)"]:::pod
            P2["<b>Node 2</b><br/>NVIDIA A100<br/>(Decode)"]:::pod
            P3["<b>Node 3</b><br/>QC AI 100<br/>(Decode)"]:::pod
        end

        GW ==> |"HTTP / gRPC Proxy"| P1
        GW ==> |"HTTP / gRPC Proxy"| P2
        GW ==> |"HTTP / gRPC Proxy"| P3
    end

    Client == "Inference Request" ==> GW

    subgraph Telemetry ["<b>Hardware Telemetry</b>"]
        direction TB
        DCGM["<b>DCGM Exporter</b><br/>(GPU Power)"]:::external
        RAPL["<b>RAPL Exporter</b><br/>(ASIC/CPU Power)"]:::external
    end
    
    Grid["<b>CO2Signal API</b><br/>Grid Carbon"]:::external

    DCGM -.-> |"Async Poll (5s)"| EPP
    RAPL -.-> |"Async Poll (5s)"| EPP
    Grid -.-> |"Async Poll (5m)"| EPP
```

---

## 2. EPP Scheduling Execution Pipeline

**Caption**: *Figure 2: Execution pipeline of the energy-aware Endpoint Picker Plugin. The scheduling process evaluates candidate pods through a sequence of hard constraints (filters) followed by soft, multi-objective normalisation (batch scorers).*

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'fontFamily': 'Inter, Arial, sans-serif', 'primaryColor': '#F8FAFC', 'primaryBorderColor': '#94A3B8', 'lineColor': '#475569', 'textColor': '#0F172A', 'fontSize': '14px'}}}%%
flowchart LR
    classDef input fill:#F1F5F9,stroke:#64748B,stroke-width:2px,rx:15;
    classDef filter fill:#FEF2F2,stroke:#DC2626,stroke-width:2px,shadow:true,rx:8;
    classDef scorer fill:#EFF6FF,stroke:#2563EB,stroke-width:2px,shadow:true,rx:8;
    classDef output fill:#F0FDF4,stroke:#16A34A,stroke-width:2px,rx:15;
    classDef db fill:#FAFAF9,stroke:#A8A29E,stroke-width:2px,rx:4;

    Inp([<b>Incoming Request</b><br/>+ Candidate Set]):::input
    Store[(<b>EnergyStore</b><br/>Real-time Telemetry)]:::db
    
    subgraph Filters ["<b>1. Hard Constraints (Filters)</b>"]
        direction TB
        F1{"<b>SLO Constraint</b><br/>TTFT / TPOT bounds"}:::filter
        F2{"<b>Power Budget</b><br/>TDP Headroom"}:::filter
        F1 --> F2
    end
    
    subgraph Scorers ["<b>2. Soft Objectives (Batch Scorers)</b>"]
        direction TB
        S1["<b>Energy Scorer</b><br/>Phase-aware Weights"]:::scorer
        S2["<b>Carbon Scorer</b><br/>Grid-aware SCI"]:::scorer
        S3["<b>Cache Scorer</b><br/>Penalty for Transfer"]:::scorer
    end
    
    Inp --> F1
    Store -.-> Filters
    Store -.-> Scorers
    
    F2 -- "Feasible<br/>Candidates" --> S1 & S2 & S3
    
    S1 & S2 & S3 --> Agg["<b>Score Aggregation</b><br/>Sum of weighted scores"]
    Agg --> Pick["<b>MaxScore Picker</b><br/>Argmax(Total Score)"]
    
    Pick --> Out([<b>Selected Routing<br/>Destination</b>]):::output
```

---

## 3. Phase-Aware Objective Weighting

**Caption**: *Figure 3: Phase-aware scheduling logic differentiating between compute-bound (prefill) and memory-bound (decode) phases. The weight matrix dynamically shifts to prioritise latency for prefix processing and energy savings during autoregressive decoding.*

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'fontFamily': 'Inter, Arial, sans-serif', 'primaryColor': '#FFFFFF', 'primaryBorderColor': '#000000', 'lineColor': '#000000', 'textColor': '#000000', 'fontSize': '15px'}}}%%
graph TD
    classDef start fill:#E2E8F0,stroke:#334155,stroke-width:2px;
    classDef decision fill:#FEF08A,stroke:#CA8A04,stroke-width:2px,rx:15;
    classDef matrix fill:#F1F5F9,stroke:#475569,stroke-width:2px;
    classDef result fill:#DBEAFE,stroke:#1D4ED8,stroke-width:2px;

    Req[<b>LLM Request</b><br/>Context & Instructions]:::start
    Phase{<b>Determine Workflow Phase</b>}:::decision
    
    Req --> Phase
    
    Phase -- "Phase == PREFILL" --> Prefill["<b>Prefill Weight Matrix</b><br/>Latency Focus<hr/>Latency: 0.60<br/>Energy: 0.20<br/>Carbon: 0.20"]:::matrix
    Phase -- "Phase == DECODE" --> Decode["<b>Decode Weight Matrix</b><br/>Energy Focus<hr/>Latency: 0.20<br/>Energy: 0.50<br/>Carbon: 0.30"]:::matrix
    
    Prefill --> Calc[<b>Multi-Objective Score Calculation</b>]
    Decode --> Calc
    
    Calc --> H100["<b>Selected:</b><br/>High-Perf GPU<br/>(e.g. NVIDIA H100)"]:::result
    Calc --> ASIC["<b>Selected:</b><br/>Low-Power Accelerator<br/>(e.g. QC AI 100)"]:::result
    
    style Calc fill:#F8FAFC,stroke:#64748B,stroke-width:2px,stroke-dasharray: 4 4
```

---

## 4. Adaptive Controller: Multi-State Automation

**Caption**: *Figure 4: Finite State Machine of the Adaptive Weight Controller. A 30-second control loop continuously evaluates grid carbon intensity ($\text{gCO}_2\text{eq/kWh}$) and cluster power consumption to dynamically transition between optimisation strategies.*

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'fontFamily': 'Inter, Arial, sans-serif', 'primaryColor': '#FAFAFA', 'lineColor': '#333333', 'textColor': '#111111', 'fontSize': '14px'}}}%%
stateDiagram-v2
    classDef normal fill:#F0FDF4,stroke:#16A34A,stroke-width:2px
    classDef critical fill:#FEF9C3,stroke:#CA8A04,stroke-width:2px
    classDef emergency fill:#FEF2F2,stroke:#DC2626,stroke-width:2px

    [*] --> Normal : Initialise System

    state Normal {
        direction LR
        [*] --> Opt
        Opt: <b>Balanced Operations</b><br/>Prefill weights favour Latency.<br/>Decode weights favour Energy.
    }
    Normal:::normal

    state CarbonCritical {
        direction LR
        [*] --> HighCO2
        HighCO2: <b>Carbon Averse</b><br/>Global shift (+20%) toward<br/>Energy and Carbon weights.
    }
    CarbonCritical:::critical

    state Emergency {
        direction LR
        [*] --> PowerCap
        PowerCap: <b>Power Capping</b><br/>Latency ignored.<br/>Energy weight maxed.
    }
    Emergency:::emergency

    Normal --> CarbonCritical : <b>Grid CO₂ > 500 g/kWh</b>
    CarbonCritical --> Normal : <b>Grid CO₂ < 500 g/kWh</b>

    Normal --> Emergency : <b>Cluster Power > 95% Limit</b>
    CarbonCritical --> Emergency : <b>Cluster Power > 95% Limit</b>
    
    Emergency --> Normal : <b>Power < 85% Limit</b>
```

---

## 5. Thread-Safe Telemetry Concurrency Model

**Caption**: *Figure 5: Data ingestion sequence illustrating thread-safety mechanisms. The system entirely decouples high-frequency background data polling tasks (telemetry scrapers) from the latency-sensitive Request Scheduling loop utilizing `sync.RWMutex` locking mechanisms.*

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'fontFamily': 'Inter, Arial, sans-serif'}}}%%
sequenceDiagram
    participant D as HW Exporters<br/>(DCGM & RAPL)
    participant C as External API<br/>(Grid CO2)
    
    box rgb(248, 250, 252) Energy-Aware Plugin Context
    participant S as Scraper Daemon
    participant ES as Energy Store<br/>[RWMutex]
    participant P as Routing Engine
    end

    Note over S, ES: Async Data Plane (Polling Loops)

    loop Every 5s
        S->>D: Scrape Metrics
        D-->>S: Hardware Power Draw
        S->>ES: Lock(WriteLock)
        S->>ES: Update Pod Telemetry
        ES-->>S: Unlock()
    end
    
    loop Every 5m
        S->>C: Fetch Electricity Map
        C-->>S: Intensity (gCO2/kWh)
        S->>ES: Lock(WriteLock)
        S->>ES: Update External Signals
        ES-->>S: Unlock()
    end
    
    Note over P, ES: Synchronous Control Plane (Per Request)

    loop On Request Event
        P->>ES: Lock(ReadLock)
        ES-->>P: Retrieve Clean Profiles
        P->>P: Evaluate Filtering & Scoring
        P->>ES: Unlock()
    end
```

---

## 6. Mathematical SLO $\epsilon$-Constraint Flow

**Caption**: *Figure 6: Flowchart detailing the implementation of the $\epsilon$-constraint filter, enforcing Service Level Objectives (SLOs). Prefill routing is gated by maximum Time-To-First-Token (TTFT), whilst decoding is gated by maximum Time-Per-Output-Token (TPOT).*

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'fontFamily': 'Inter, Arial, sans-serif', 'fontSize': '14px'}}}%%
graph TD
    classDef calc fill:#F8FAFC,stroke:#94A3B8,stroke-width:2px,rx:4;
    classDef condition fill:#FFFBEB,stroke:#F59E0B,stroke-width:2px,shadow:true;
    classDef accept fill:#F0FDF4,stroke:#22C55E,stroke-width:2px;
    classDef reject fill:#FEF2F2,stroke:#EF4444,stroke-width:2px;

    Start([<b>Begin Latency Evaluation</b>]) --> QDelay
    
    QDelay["<b>Step 1: Calculate Delay</b><br/>Q_Delay = Q_Depth × Avg_Latency"]:::calc
    
    QDelay --> PhaseCheck{"<b>Request Phase?</b>"}:::condition
    
    PhaseCheck -- "PREFILL" --> CalcPrefill["<b>Step 2a: TTFT Estimate</b><br/>TTFT = (Tokens / Pre_TPS) + Q_Delay"]:::calc
    CalcPrefill --> CheckTTFT{"<b>TTFT ≤ SLO Limit?</b>"}:::condition
    
    CheckTTFT -- "True" --> Accept([<b>Accept Candidate</b>]):::accept
    CheckTTFT -- "False" --> Reject1([<b>Reject: Violates TTFT bounds</b>]):::reject
    
    PhaseCheck -- "DECODE" --> CalcDecode["<b>Step 2b: TPOT Estimate</b><br/>TPOT = 1000 / Dec_TPS"]:::calc
    CalcDecode --> CheckTPOT{"<b>TPOT ≤ SLO Limit?</b>"}:::condition
    
    CheckTPOT -- "False" --> Reject2([<b>Reject: Violates TPOT bounds</b>]):::reject
    CheckTPOT -- "True" --> CheckQueue{"<b>Queue Depth ≤ Max?</b>"}:::condition
    
    CheckQueue -- "True" --> Accept
    CheckQueue -- "False" --> Reject3([<b>Reject: Overloaded Queue</b>]):::reject
```

---

## 7. KV-Cache Cross-Node Transfer Operations

**Caption**: *Figure 7: Disaggregated sequence illustrating phase transition from prefill node to decode node. The `KVCacheTransferScorer` calculates an energy penalty associated with the transfer across the network fabric, balancing transfer cost against targeted decode efficiency.*

```mermaid
%%{init: {'theme': 'base', 'themeVariables': { 'fontFamily': 'Inter, Arial, sans-serif'}}}%%
sequenceDiagram
    autonumber
    
    participant Client as Client Application
    participant EPP as Inference Gateway & EPP
    participant P as NVIDIA H100 Node<br/>(Prefill Compute)
    participant D as QC AI 100 Node<br/>(Decode Compute)

    Client->>EPP: Request (Generate Response)
    
    Note right of EPP: Phase 1: Prefill Focus
    EPP->>P: Route to Compute Node
    
    rect rgb(241, 245, 249)
        P->>P: Process Attention Matrices<br/>(High Power: ~700W)
    end
    
    P-->>EPP: Stream First Token + (KV-Cache Reference)
    EPP-->>Client: Stream First Token
    
    Client->>EPP: Continue Generation Request
    
    Note right of EPP: Phase 2: Decode Focus<br/>Calculate Transfer Penalty
    EPP->>D: Route to LP Node
    
    D->>P: Fetch Cache via RDMA / TCP
    P-->>D: Transfer Cache Payload (e.g. 640MB)
    
    rect rgb(240, 253, 244)
        D->>D: Autoregressive Loop<br/>(Low Power: ~75W)
    end
    
    D-->>EPP: Final Token Transmission
    EPP-->>Client: Finish Request Context
```
