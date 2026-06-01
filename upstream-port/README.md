# Energy-Aware Scorer

The **Energy-Aware Scorer** is a scheduling plugin that scores inference endpoints
based on GPU power consumption, energy-per-token efficiency, and grid carbon
intensity. It exploits the asymmetric energy profiles of LLM inference phases:

- **Prefill** (compute-bound): favors high-TDP GPUs for minimum Time-To-First-Token
- **Decode** (memory-bound): favors low-power accelerators for minimum energy-per-token

## Configuration

The scorer is configured via the scheduling profile YAML:

```yaml
scorers:
  - type: energy-aware-scorer
    weight: 5
    parameters:
      prefillLatencyWeight: 0.7
      prefillEnergyWeight: 0.2
      prefillCarbonWeight: 0.1
      decodeLatencyWeight: 0.15
      decodeEnergyWeight: 0.65
      decodeCarbonWeight: 0.20
      fallbackCarbonIntensity: 390
```

## Required Pod Labels

Energy telemetry is read from pod labels. These should be set by a DCGM exporter
sidecar or an operator:

| Label | Description | Example |
|-------|-------------|---------|
| `llm-d.ai/gpu-tdp-watts` | GPU thermal design power (W) | `400` |
| `llm-d.ai/gpu-power-watts` | Current measured power draw (W) | `285` |
| `llm-d.ai/tokens-per-second` | Measured decode throughput | `450` |
| `llm-d.ai/energy-per-token-mj` | Measured energy per token (mJ) | `2.3` |
| `llm-d.ai/hardware-class` | Hardware tier | `gpu-high`, `gpu-med`, `asic-low`, `fpga-low` |

## Scoring Formula

```
score(endpoint) = w_latency × S_latency + w_energy × S_energy + w_carbon × S_carbon
```

Each sub-score is computed independently and min-max normalized to [0, 1] across
all candidate endpoints before applying the phase-specific weight vector.

## Category

`Distribution` — the scorer prefers spreading decode-heavy workloads to
energy-efficient endpoints rather than concentrating them on high-TDP hardware.
