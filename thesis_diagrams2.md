# Thesis Diagrams (Professional Academic Styling)


## 1. System Architecture: Control and Data Planes

**Caption**: *Figure 1: High-level architecture of the energy-aware LLM inference serving system. The system integrates via the Kubernetes Gateway API Inference Extension. Request routing (control plane) intersects with telemetry ingestion (data plane) at the Endpoint Picker Plugin (EPP).*

![System Architecture](docs/diagrams/architecture.png)

---

## 2. EPP Scheduling Execution Pipeline

**Caption**: *Figure 2: Execution pipeline of the energy-aware Endpoint Picker Plugin. The scheduling process evaluates candidate pods through a sequence of hard constraints (filters) followed by soft, multi-objective normalisation (batch scorers).*

![Scheduling Pipeline](docs/diagrams/scheduling_pipeline.png)
<img width="871" height="638" alt="Screenshot (10258)" src="https://github.com/user-attachments/assets/26d23c20-4774-40e6-81f6-265a14478030" />


---

## 3. Phase-Aware Objective Weighting

**Caption**: *Figure 3: Phase-aware scheduling logic differentiating between compute-bound (prefill) and memory-bound (decode) phases. The weight matrix dynamically shifts to prioritise latency for prefix processing and energy savings during autoregressive decoding.*

![Phase-Aware Routing](docs/diagrams/phase_aware_routing.png)
<img width="871" height="638" alt="Screenshot (10258)" src="https://github.com/user-attachments/assets/4a1304c3-b072-4c97-b234-50b780590820" />

---

## 4. Adaptive Controller: Multi-State Automation

**Caption**: *Figure 4: Finite State Machine of the Adaptive Weight Controller. A 30-second control loop continuously evaluates grid carbon intensity ($\text{gCO}_2\text{eq/kWh}$) and cluster power consumption to dynamically transition between optimisation strategies.*

![Adaptive Controller FSM](docs/diagrams/adaptive_controller_fsm.png)

---

## 5. Thread-Safe Telemetry Concurrency Model

**Caption**: *Figure 5: Data ingestion sequence illustrating thread-safety mechanisms. The system entirely decouples high-frequency background data polling tasks (telemetry scrapers) from the latency-sensitive Request Scheduling loop utilizing `sync.RWMutex` locking mechanisms.*

![Concurrency Model](docs/diagrams/concurrency_model.png)

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
