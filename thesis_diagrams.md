# Thesis Diagrams (Mermaid Format)

These diagrams are generated using [Mermaid.js](https://mermaid.js.org/). You can copy the code blocks directly into markdown editors that support Mermaid (like GitHub, GitLab, Obsidian) or use the [Mermaid Live Editor](https://mermaid.live/) to export them as high-resolution SVG/PNG files for inclusion in your LaTeX or Word thesis document.

---

## 1. High-Level System Architecture (Gateway API & llm-d)

**Caption**: *Figure 1: High-level architecture of the energy-aware LLM inference serving system. The system integrates via the Kubernetes Gateway API Inference Extension, using Envoy's `ext_proc` filter to offload routing decisions to the energy-aware Endpoint Picker Plugin (EPP) sidecar. The EPP continuously gathers telemetry from DCGM, RAPL, and Carbon APIs to make phase-aware routing decisions across heterogeneous hardware pools.*

```mermaid
graph TD
    %% Styling
    classDef client fill:#f9f9f9,stroke:#333,stroke-width:2px;
    classDef gateway fill:#e1f5fe,stroke:#0288d1,stroke-width:2px;
    classDef epp fill:#e8f5e9,stroke:#388e3c,stroke-width:2px;
    classDef nodes fill:#fff3e0,stroke:#f57c00,stroke-width:2px;
    classDef external fill:#f3e5f5,stroke:#7b1fa2,stroke-width:2px;

    Client((Client App)):::client

    subgraph Kubernetes Cluster
        Gateway[Envoy Gateway<br/>Inference Extension]:::gateway
        
        subgraph EPP_Pod["EPP Sidecar Pod"]
            EPP[Energy-Aware EPP<br/>Endpoint Picker Plugin]:::epp
        end

        Gateway -- "gRPC stream (ext_proc)" --> EPP
        EPP -. "Routing Decision<br/>(Target Pod IP)" .-> Gateway

        subgraph Heterogeneous_Inference_Pool["InferencePool (Target Backends)"]
            PodA[vLLM Pod 1<br/>NVIDIA H100 GPU<br/>Role: Prefill]:::nodes
            PodB[vLLM Pod 2<br/>NVIDIA A100 GPU<br/>Role: Decode]:::nodes
            PodC[vLLM Pod 3<br/>Qualcomm AI 100<br/>Role: Decode]:::nodes
        end

        Gateway == "Reverse Proxy HTTP/gRPC" ==> PodA
        Gateway == "Reverse Proxy HTTP/gRPC" ==> PodB
        Gateway == "Reverse Proxy HTTP/gRPC" ==> PodC
        
        %% Telemetry Flow
        DCGMA[DCGM Exporter] -->|Scrape 5s| EPP
        DCGMB[DCGM Exporter] -->|Scrape 5s| EPP
        RAPLC[RAPL Exporter] -->|Scrape 5s| EPP
        
        PodA -.- DCGMA
        PodB -.- DCGMB
        PodC -.- RAPLC
    end

    Client -- "Inference Request<br/>(OpenAI API format)" --> Gateway

    GridCO2[Grid Carbon API<br/>CO2Signal/ElectricityMaps]:::external
    GridCO2 -.->|HTTP GET 5m| EPP

```

---

## 2. EPP Internal Pipeline (Filter → Score → Pick)

**Caption**: *Figure 2: Internal scheduling pipeline of the Endpoint Picker Plugin. The process follows a strict Filter → Score → Pick hierarchy. Pods are first filtered based on hard latency constraints (ε-constraint method) and power budgets. The remaining feasible pods are then ranked using an aggregated multi-objective scoring function over energy, carbon, and KV-cache transfer metrics.*

```mermaid
flowchart TD
    %% Styling
    classDef process fill:#bbdefb,stroke:#0d47a1,stroke-width:2px;
    classDef data fill:#c8e6c9,stroke:#1b5e20,stroke-width:2px;
    classDef decision fill:#ffe0b2,stroke:#e65100,stroke-width:2px;
    classDef startend fill:#f5f5f5,stroke:#424242,stroke-width:2px,rx:20,ry:20;

    Start([Incoming ext_proc Request]):::startend
    
    subgraph DataContext ["GIE Cycle State"]
        ReqInfo[Request Info<br/>phase, required tokens]:::data
        PodCands[(Candidate Pods)]:::data
        EngStore[(Energy Store<br/>Telemetry Cache)]:::data
    end
    
    Start --> FilterPhase
    
    subgraph FilterPhase ["Phase 1: Filtering (Hard Constraints)"]
        F1{SLO Constraint Filter<br/>ε-constraint}:::decision
        F2{Energy Budget Filter<br/>Headroom}:::decision
        
        F1 -- "TTFT/TPOT within bounds" --> F2
        F1 -. "Violates SLO" .-> Rejected((Rejected))
        F2 -- "Power < 90% TDP" --> FeasiblePods[(Feasible Pods)]:::data
        F2 -. "Exceeds Budget" .-> Rejected
    end
    
    FeasiblePods --> ScorePhase
    
    subgraph ScorePhase ["Phase 2: Batch Scoring (Soft Objectives)"]
        S1[Energy-Aware Scorer<br/>Phase-specific Weights]:::process
        S2[Carbon Intensity Scorer<br/>SCI + Grid CO2]:::process
        S3[KV-Cache Transfer Scorer<br/>Disaggregation Cost]:::process
        
        S1 --> Agg[Score Aggregation<br/>sum(scores * weights)]
        S2 --> Agg
        S3 --> Agg
    end
    
    Agg --> PickPhase
    
    subgraph PickPhase ["Phase 3: Picking"]
        Picker[MaxScorePicker<br/>Select highest score]:::process
    end
    
    Picker --> End([Return Selected Pod IP]):::startend
    
    %% Data dependencies
    ReqInfo -.-> F1
    ReqInfo -.-> S1
    EngStore -.-> F2
    EngStore -.-> S1
    EngStore -.-> S2
    EngStore -.-> S3

```

---

## 3. Phase-Aware Scheduling Flow

**Caption**: *Figure 3: Phase-aware scheduling logic differentiating between prefill (compute-bound) and decode (memory-bound) requests. The dynamic weight vector $\vec{W} = \langle W_{Latency}, W_{Energy}, W_{Carbon} \rangle$ shifts based on the requested phase, prioritising latency for prefill and energy efficiency for decode.*

```mermaid
graph TD
    classDef req fill:#eceff1,stroke:#607d8b,stroke-width:2px;
    classDef choice fill:#fff9c4,stroke:#fbc02d,stroke-width:2px;
    classDef logic fill:#e1bee7,stroke:#8e24aa,stroke-width:2px;
    classDef result fill:#cce5ff,stroke:#004085,stroke-width:2px;

    Req[New Inference Request]:::req
    Parse[Parse Phase from Request<br/>Headers or URI]:::logic
    
    Req --> Parse
    Parse --> IsPrefill{Phase == PREFILL?}:::choice
    
    IsPrefill -- Yes --> PrefillWeights[Apply Prefill Weights<br/>W = {L:0.60, E:0.20, C:0.20}]:::logic
    IsPrefill -- No --> DecodeWeights[Apply Decode Weights<br/>W = {L:0.20, E:0.50, C:0.30}]:::logic
    
    PrefillWeights --> ScoreCalc
    DecodeWeights --> ScoreCalc
    
    ScoreCalc[Calculate Multi-Objective Score<br/>Score = L*S_lat + E*S_eng + C*S_carb]:::logic
    
    ScoreCalc --> Rank{Select Highest Score Pod}:::choice
    
    Rank -- Prefill Usually Favors --> GPUH[High-Perf GPU<br/>NVIDIA H100]:::result
    Rank -- Decode Usually Favors --> ASIC[Low-Power Accelerator<br/>Qualcomm AI 100 / L4]:::result

```

---

## 4. Adaptive Weight Controller State Machine

**Caption**: *Figure 4: Finite State Machine (FSM) representation of the Adaptive Weight Controller. Driven by a 30-second control loop, the system transitions between operational modes based on real-time grid carbon intensity ($I_{Grid}$) and cluster-wide power headroom.*

```mermaid
stateDiagram-v2
    %% State definitions
    Normal : NORMAL MODE
    Normal : Optimise for latency & energy
    
    CarbonCritical : CARBON_CRITICAL MODE
    CarbonCritical : Penalise high TDP pods heavily
    
    Emergency : EMERGENCY MODE
    Emergency : Shed load, strict power caps

    [*] --> Normal : Initialise

    Normal --> CarbonCritical : I_Grid >= 500 gCO2/kWh
    CarbonCritical --> Normal : I_Grid < 500 gCO2/kWh

    Normal --> Emergency : Cluster Power > 95% Budget
    CarbonCritical --> Emergency : Cluster Power > 95% Budget
    
    Emergency --> Normal : Cluster Power < 85% Budget\nAND I_Grid < 500
    Emergency --> CarbonCritical : Cluster Power < 85% Budget\nAND I_Grid >= 500

    note right of Normal
        Prefill: L0.6/E0.2/C0.2
        Decode: L0.2/E0.5/C0.3
    end note
    
    note left of CarbonCritical
        Prefill: L0.3/E0.3/C0.4
        Decode: L0.1/E0.4/C0.5
    end note
    
    note right of Emergency
        All Phases: L0.1/E0.6/C0.3
    end note

```

---

## 5. Telemetry Collection and Concurrency Model

**Caption**: *Figure 5: Data flow and concurrency architecture for energy telemetry aggregation. Asynchronous scrapers pull data from respective endpoints (DCGM, RAPL, CO2Signal) and update a thread-safe `EnergyStore`. Mutex locks (`RWMutex`) ensure zero data races between high-frequency background scrapers and latency-sensitive scheduling requests.*

```mermaid
sequenceDiagram
    participant D as DCGM Exporter<br/>(GPU Nodes)
    participant R as RAPL Exporter<br/>(ASIC Nodes)
    participant C as CO2Signal API<br/>(External)
    
    box rgb(240, 248, 255) EPP Plugin
    participant S as Scraper Routines
    participant ES as EnergyStore<br/>(sync.RWMutex)
    participant P as Scheduling Pipeline
    end

    par Every 5 Seconds
        S->>D: HTTP GET /metrics
        S->>R: Read /sys/class/powercap
        D-->>S: GPU Power, Utilisation
        R-->>S: SOC Power, Memory Power
        S->>ES: Lock(Write)
        S->>ES: UpdateProfile(PodName, EnergyPerToken)
        S->>ES: Unlock()
    and Every 5 Minutes
        S->>C: HTTP GET /v1/latest?zone=CAL
        C-->>S: carbonIntensity: 220 gCO2/kWh
        S->>ES: Lock(Write)
        S->>ES: UpdateExternal(GridCO2)
        S->>ES: Unlock()
    end
    
    note over S,ES: Background updating is decoupled from routing logic

    loop For each Inference Request
        P->>ES: Lock(Read)
        ES-->>P: GetProfile(CandidatePod)
        P->>ES: Unlock()
        P->>P: Execute Filter & Score functions
    end
```

---

## 6. SLO $\epsilon$-Constraint Filter Logic

**Caption**: *Figure 6: Flowchart of the $\epsilon$-Constraint SLO Filter. The algorithm evaluates each candidate pod against configured Time-To-First-Token (TTFT) and Time-Per-Output-Token (TPOT) bounds, ensuring latency-sensitive requests are not routed to slow or overloaded energy-efficient nodes.*

```mermaid
graph TD
    Start([Evaluate Pod P against Phase SLO]) --> Calc[Estimate Queue Delay<br/>Delay = QueueDepth * AvgReqTime]
    Calc --> IsPrefill{Request Phase}
    
    IsPrefill -- PREFILL --> EstPrefill[Estimate Prefill Latency<br/>Lat = (Tokens / Throughput_P) + Delay]
    EstPrefill --> CheckTTFT{Lat <= TTFT_SLO?}
    
    CheckTTFT -- Yes --> Accept([Accept Pod into Feasible Set])
    CheckTTFT -- No --> Reject([Reject Pod<br/>Violates TTFT])
    
    IsPrefill -- DECODE --> EstDecode[Estimate Decode Latency<br/>Lat = 1000 / Throughput_D]
    EstDecode --> CheckTPOT{Lat <= TPOT_SLO?}
    
    CheckTPOT -- Yes --> CheckQueue{Queue Depth < Max}
    CheckQueue -- Yes --> Accept
    CheckQueue -- No --> RejectQueue([Reject Pod<br/>Overloaded])
    
    CheckTPOT -- No --> RejectTPOT([Reject Pod<br/>Violates TPOT])

    classDef acc fill:#c8e6c9,stroke:#2e7d32
    classDef rej fill:#ffcdd2,stroke:#c62828
    
    class Accept acc
    class Reject,RejectTPOT,RejectQueue rej
```

---

## 7. Disaggregated Serving KV-Cache Transfer Flow

**Caption**: *Figure 7: Sequence diagram demonstrating disaggregated serving with KV-cache transfer. A prompt is first routed to a high-power GPU for compute-intensive prefill, the resulting KV-cache is transferred to an energy-efficient ASIC, which assumes the decode workload. The `KVCacheTransferScorer` calculates the energy penalty ($E_{transfer}$) for this operation.*

```mermaid
sequenceDiagram
    autonumber
    
    participant Client
    participant Envoy as Gateway + EPP
    participant P_Node as NVIDIA H100<br/>(Prefill Node)
    participant D_Node as Qualcomm AI 100<br/>(Decode Node)

    Client->>Envoy: Inference Req (Phase: Prefill)
    
    Note over Envoy: EPP Context: Prefill weights.<br/>Selects fastest compute.
    Envoy->>P_Node: Route Request
    
    rect rgb(255, 235, 238)
        P_Node->>P_Node: Compute Prompt Attention<br/>(High Power: 700W)
    end
    
    P_Node-->>Envoy: Return First Token + KV-Cache Handle
    Envoy-->>Client: First Token (Stream)
    
    Client->>Envoy: Inference Req (Phase: Decode, Handle)
    
    Note over Envoy: EPP Context: Decode weights.<br/>Scorer applies transfer penalty to D_Node.
    Note over Envoy: Selected D_Node (Energy savings > Transfer cost)
    Envoy->>D_Node: Route Request (KV-Cache Handle)
    
    D_Node->>P_Node: Request KV-Cache (RDMA/TCP)
    P_Node-->>D_Node: Transfer Cache 640MB
    
    rect rgb(224, 247, 250)
        D_Node->>D_Node: Autoregressive Generation<br/>(Low Power: 75W)
    end
    
    D_Node-->>Envoy: Return Generated Tokens
    Envoy-->>Client: Generated Tokens
```

---

## Instructions for Use in Thesis
1. Open [Mermaid Live Editor](https://mermaid.live).
2. Paste the raw text within the ````mermaid ```` blocks.
3. Use the "Export" functionality to save as an SVG or PNG.
4. Insert into your Word or LaTeX document, using the provided Captions for proper academic formatting. 
