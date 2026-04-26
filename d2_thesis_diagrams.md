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

![System Architecture](docs/diagrams/architecture.png)

---

### 2. EPP Scheduling Execution Pipeline

This diagram shows the strict hierarchical flow of filtering, scoring, and picking candidate pods.

![Scheduling Pipeline](docs/diagrams/scheduling_pipeline.png)

---

### 3. Adaptive Weight Controller FSM

This Finite State Machine uses D2's specific state diagram syntax for incredibly clean routing transitions.

![Adaptive Controller FSM](docs/diagrams/adaptive_controller_fsm.png)

---

### 4. Telemetry Concurrency Model

D2 renders sequence diagrams with beautiful, academic-grade typography and spacing by default.

![Concurrency Model](docs/diagrams/concurrency_model.png)
