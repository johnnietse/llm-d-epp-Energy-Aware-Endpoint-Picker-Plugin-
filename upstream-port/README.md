# Energy-Aware Scorer Plugin

The **energy-aware scorer** adds energy efficiency as a routing dimension for the llm-d Router's Endpoint Picker. It enables operators to minimize energy consumption and carbon emissions across heterogeneous GPU clusters while respecting latency SLOs.

## Overview

In heterogeneous inference clusters, different accelerators have vastly different energy profiles:

| Hardware | TDP (W) | Energy/Token (mJ) | Best For |
|----------|---------|-------------------|----------|
| NVIDIA H100 | 700 | 6.0 | Prefill (compute-bound) |
| NVIDIA A100 | 250 | 3.5 | General purpose |
| NVIDIA L4 | 72 | 1.2 | Decode (memory-bound) |

The energy-aware scorer assigns higher scores to more energy-efficient endpoints, allowing the weighted scoring system to balance energy savings against other objectives like latency and cache locality.

## Scoring Function

The scorer computes a weighted multi-objective score for each endpoint:

```
Score = w_latency × S_latency + w_energy × S_energy + w_carbon × S_carbon
```

### Phase-Aware Weights

The weight vectors differ based on the inference phase:

| Phase | w_latency | w_energy | w_carbon | Rationale |
|-------|-----------|----------|----------|-----------|
| **Prefill** | 0.70 | 0.20 | 0.10 | TTFT is the critical metric |
| **Decode** | 0.15 | 0.65 | 0.20 | Sustained power draw dominates |

This asymmetry reflects the compute profile of each phase:
- **Prefill** is compute-bound → route to high-performance GPUs (H100)
- **Decode** is memory-bound → route to energy-efficient accelerators (L4)

## Configuration

Add the scorer to your `EndpointPickerConfig`:

```yaml
plugins:
  - type: energy-aware-scorer
    parameters:
      prefillLatencyWeight: 0.7
      prefillEnergyWeight: 0.2
      prefillCarbonWeight: 0.1
      decodeLatencyWeight: 0.15
      decodeEnergyWeight: 0.65
      decodeCarbonWeight: 0.20
      fallbackCarbonIntensity: 390    # gCO₂/kWh (used if no live data)
      latencySloMs: 500               # TTFT SLO in milliseconds

schedulingProfiles:
  - name: default
    plugins:
      - pluginRef: kv-cache-utilization-scorer
        weight: 3
      - pluginRef: energy-aware-scorer
        weight: 5
      - pluginRef: max-score-picker
```

### Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `prefillLatencyWeight` | float | 0.7 | Latency weight during prefill phase |
| `prefillEnergyWeight` | float | 0.2 | Energy weight during prefill phase |
| `prefillCarbonWeight` | float | 0.1 | Carbon weight during prefill phase |
| `decodeLatencyWeight` | float | 0.15 | Latency weight during decode phase |
| `decodeEnergyWeight` | float | 0.65 | Energy weight during decode phase |
| `decodeCarbonWeight` | float | 0.20 | Carbon weight during decode phase |
| `fallbackCarbonIntensity` | float | 390.0 | Default grid carbon intensity (gCO₂/kWh) |
| `latencySloMs` | float | 500.0 | TTFT SLO threshold in ms |

## Required Endpoint Annotations

The scorer reads the following pod labels/annotations, which should be populated by a DCGM exporter or telemetry operator:

| Label | Example | Source |
|-------|---------|--------|
| `llm-d.ai/hardware-class` | `GPU_HIGH_PERF` | Node label |
| `llm-d.ai/tdp-watts` | `700` | Hardware spec |
| `llm-d.ai/gpu-power-watts` | `550` | DCGM exporter |
| `llm-d.ai/energy-per-token-mj` | `6.0` | Computed |
| `llm-d.ai/tokens-per-second` | `800` | vLLM metrics |

## Scorer Category

Returns `fwksched.Distribution` — the scorer distributes requests across endpoints based on energy efficiency rather than concentrating on a single endpoint.

## Testing

```bash
go test -v -count=1 ./pkg/epp/framework/plugins/scheduling/scorer/energyaware/...
```

## References

- [Green Software Foundation SCI Specification](https://sci.greensoftware.foundation/)
- [NVIDIA DCGM Exporter](https://github.com/NVIDIA/dcgm-exporter)
- Research: "Energy-Aware Token-Level Routing for Heterogeneous LLM Inference in Kubernetes"
