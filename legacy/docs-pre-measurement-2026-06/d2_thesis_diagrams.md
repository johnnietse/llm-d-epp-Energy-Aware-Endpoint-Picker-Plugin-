# D2 Thesis Diagrams

---

### 1. High-Level System Architecture

This diagram shows the control plane routing intersecting with the data plane telemetry. It uses orthogonal routing for a much cleaner look than Mermaid could provide.

![System Architecture](docs/diagrams/architecture.png)

---

### 2. EPP Scheduling Execution Pipeline

This diagram shows the strict hierarchical flow of filtering, scoring, and picking candidate pods.

![Scheduling Pipeline](docs/diagrams/scheduling_pipeline.png)
<img width="871" height="638" alt="Screenshot (10258)" src="https://github.com/user-attachments/assets/4f89ea3f-2239-4de5-8eb7-d7a7371b18bc" />


---

### 3. Adaptive Weight Controller FSM

This Finite State Machine uses D2's specific state diagram syntax for incredibly clean routing transitions.

![Adaptive Controller FSM](docs/diagrams/adaptive_controller_fsm.png)

---

### 4. Telemetry Concurrency Model

D2 renders sequence diagrams with beautiful, academic-grade typography and spacing by default.

![Concurrency Model](docs/diagrams/concurrency_model.png)
