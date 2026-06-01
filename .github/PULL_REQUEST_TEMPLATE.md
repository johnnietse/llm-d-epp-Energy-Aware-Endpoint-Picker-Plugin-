# Energy-Aware Scorer Plugin

## What this PR adds

This PR introduces an **energy-aware scorer plugin** for the llm-d Router's Endpoint Picker (EPP). It adds a new dimension to routing decisions — **energy efficiency** — alongside the existing latency, KV-cache, and load-based scorers.

### Motivation

Current llm-d scoring plugins optimize for latency and throughput but are blind to the energy cost of routing decisions. In heterogeneous GPU clusters (e.g., H100 + A100 + L4), the energy-per-token can vary by **10×** between hardware classes. This plugin enables operators to factor in energy consumption and carbon intensity when selecting endpoints, achieving measurable energy savings without violating latency SLOs.

**Key result**: In a heterogeneous 3-node cluster, energy-aware routing reduces energy consumption by **17.4%** compared to round-robin while maintaining equivalent P99 latency.

### How it works

The energy-aware scorer implements the standard `scheduling.Scorer` interface and scores each endpoint using a weighted multi-objective function:

```
Score(endpoint) = w_latency × S_latency + w_energy × S_energy + w_carbon × S_carbon
```

Where:
- **S_latency**: Normalized inverse latency estimate (higher = faster)
- **S_energy**: Normalized inverse energy-per-token (higher = more efficient)
- **S_carbon**: Normalized inverse carbon intensity (higher = cleaner grid)

The weights are **phase-aware** — different weight vectors are applied for prefill vs. decode inference phases:
- **Prefill**: Latency-dominant (`w_L=0.7, w_E=0.2, w_C=0.1`) — TTFT matters most
- **Decode**: Energy-dominant (`w_L=0.15, w_E=0.65, w_C=0.20`) — sustained power draw matters

### What's included

| File | Description |
|------|-------------|
| `energy_aware.go` | Scorer implementation (383 lines) |
| `energy_aware_test.go` | Comprehensive unit tests |
| `README.md` | Plugin documentation |

### Interface conformance

The plugin implements the exact same interface as all existing scorers:

```go
var _ scheduling.Scorer = &EnergyAware{}  // compile-time assertion

func (e *EnergyAware) TypedName() plugin.TypedName { ... }
func (e *EnergyAware) Category() ScorerCategory { ... }
func (e *EnergyAware) Score(ctx, state, request, endpoints) map[Endpoint]float64 { ... }
```

Registration requires one line in `runner.go`:
```go
fwkplugin.Register(energyaware.EnergyAwareType, energyaware.Factory)
```

### Configuration

Users enable the scorer by adding it to their `EndpointPickerConfig`:

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

**The plugin is purely opt-in** — if not added to the config, zero impact on existing deployments.

### Data sources

The scorer reads from existing endpoint metrics + pod annotations:
- `llm-d.ai/gpu-power-watts` — Real-time GPU power draw (from DCGM exporter)
- `llm-d.ai/energy-per-token-mj` — Computed energy per token
- `llm-d.ai/hardware-class` — Hardware classification label
- Carbon intensity can be injected via a sidecar or API integration

### Testing

```bash
go test -v ./pkg/epp/framework/plugins/scheduling/scorer/energyaware/...
```

### Related work

- Research paper: "Energy-Aware Token-Level Routing for Heterogeneous LLM Inference in Kubernetes"
- Full standalone implementation: [johnnietse/llm-d-epp-Energy-Aware-Endpoint-Picker-Plugin-](https://github.com/johnnietse/llm-d-epp-Energy-Aware-Endpoint-Picker-Plugin-)
- Green Software Foundation SCI specification conformance

### Checklist

- [x] Implements `scheduling.Scorer` interface with compile-time assertion
- [x] Follows existing plugin structure (factory pattern, TypedName, etc.)
- [x] Purely additive — no changes to existing code paths
- [x] Unit tests included
- [x] Documentation included
- [x] No new external dependencies
- [x] Configurable via `EndpointPickerConfig` YAML

/kind feature
/sig router
