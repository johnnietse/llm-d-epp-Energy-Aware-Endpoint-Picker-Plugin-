# Design Proposal: Energy-Aware Scorer Plugin for llm-d Router

**Author**: Johnnie Tse ([@johnnietse](https://github.com/johnnietse))
**Status**: Proposal
**Created**: 2026-06-01
**Related Issue**: TBD (create issue before PR)

## Summary

Add an **energy-aware scorer plugin** to the llm-d Router that enables operators to factor energy consumption and carbon intensity into endpoint selection for heterogeneous GPU inference clusters.

## Motivation

### Problem

The llm-d Router currently provides 13 scorer plugins optimizing for latency, cache locality, queue depth, and load distribution. None consider the **energy cost** of routing decisions.

In heterogeneous clusters mixing high-power (H100, 700W TDP) and low-power (L4, 72W TDP) accelerators, energy-per-token can vary by 10×. Round-robin or load-based scheduling treats all hardware identically, missing significant energy optimization opportunities during the memory-bound decode phase where low-power accelerators perform comparably at a fraction of the energy cost.

### Why This Matters Now

- **Data center energy costs**: Global data center electricity consumption is projected to reach 945 TWh by 2030 (IEA, 2024). LLM inference is a growing fraction.
- **Regulatory pressure**: The EU Energy Efficiency Directive (2023/1791) and California SB 253 create reporting obligations for Scope 2 emissions.
- **Cost savings**: At $0.10/kWh, a 17% energy reduction across a 100-GPU cluster saves ~$50K/year.
- **Heterogeneous clusters are standard**: Most production clusters mix GPU generations. Energy-aware routing is a zero-cost optimization over existing hardware.

### Goals

1. Provide a scorer that factors energy-per-token and carbon intensity into endpoint selection
2. Support phase-aware scoring (different weights for prefill vs. decode)
3. Integrate with existing DCGM telemetry infrastructure
4. Zero impact on existing deployments (purely opt-in via config)
5. Follow all existing plugin conventions (factory pattern, typed name, `scheduling.Scorer` interface)

### Non-Goals

- This proposal does NOT modify the core scheduling pipeline
- This proposal does NOT add new CRDs or API types
- This proposal does NOT require changes to vLLM or model server configurations
- This proposal does NOT implement power capping or DVFS control

## Design

### Interface Implementation

The scorer implements the standard `scheduling.Scorer` interface:

```go
type EnergyAware struct {
    typedName plugin.TypedName
    config    EnergyAwareConfig
}

var _ scheduling.Scorer = &EnergyAware{}

func (e *EnergyAware) Score(ctx context.Context, request *scheduling.InferenceRequest,
    endpoints []scheduling.Endpoint) map[scheduling.Endpoint]float64 {
    // Multi-objective scoring
}

func (e *EnergyAware) Category() scheduling.ScorerCategory {
    return scheduling.Distribution
}
```

### Scoring Algorithm

For each candidate endpoint, the scorer computes:

```
Score(endpoint) = w_L × S_latency + w_E × S_energy + w_C × S_carbon
```

Where:
- `S_latency = 1 - (estimated_latency / max_latency)` — normalized inverse latency
- `S_energy = 1 - (energy_per_token / max_energy_per_token)` — normalized inverse energy
- `S_carbon = 1 - (carbon_intensity / max_carbon_intensity)` — normalized inverse carbon

All scores are clamped to [0, 1] per the `Scorer` interface contract.

### Phase-Aware Weight Vectors

The weight vectors change based on the inference phase detected from the request:

| Phase | w_latency | w_energy | w_carbon | Rationale |
|-------|-----------|----------|----------|-----------|
| Prefill | 0.70 | 0.20 | 0.10 | TTFT critical; route to fast GPUs |
| Decode | 0.15 | 0.65 | 0.20 | Memory-bound; route to efficient hardware |

Phase detection uses the `InferenceRequest` metadata or pod role labels (`llm-d.ai/role: prefill|decode`).

### Data Sources

The scorer reads endpoint metrics from existing mechanisms:

| Data | Source | How |
|------|--------|-----|
| Hardware TDP | Pod label `llm-d.ai/tdp-watts` | Already used by `bylabel` filter |
| Current power draw | DCGM exporter → Pod annotation | Standard GPU monitoring |
| Tokens per second | vLLM `/metrics` endpoint | Already scraped by data layer |
| Carbon intensity | Configurable parameter or API | Falls back to `fallbackCarbonIntensity` |

No new data sources are required. The scorer degrades gracefully: if energy metrics are missing, it falls back to TDP-based estimates. If carbon data is unavailable, it uses the configured fallback value.

### Configuration

```yaml
plugins:
  - type: energy-aware-scorer
    name: energy-scorer
    config:
      prefillLatencyWeight: 0.7
      prefillEnergyWeight: 0.2
      prefillCarbonWeight: 0.1
      decodeLatencyWeight: 0.15
      decodeEnergyWeight: 0.65
      decodeCarbonWeight: 0.20
      fallbackCarbonIntensity: 390

schedulingProfiles:
  - name: default
    plugins:
      - pluginRef: energy-scorer
        weight: 5
```

### Factory Pattern

```go
func Factory(name string, rawParameters *json.Decoder, handle plugin.Handle) (plugin.Plugin, error) {
    params := defaultConfig()
    if rawParameters != nil {
        if err := rawParameters.Decode(&params); err != nil {
            return nil, fmt.Errorf("failed to parse '%s' parameters: %w", EnergyAwareType, err)
        }
    }
    return NewEnergyAware(params).WithName(name), nil
}
```

## Alternatives Considered

### 1. External sidecar scorer
**Rejected**: Adds latency (extra gRPC hop) and operational complexity. The plugin framework is designed for exactly this use case.

### 2. Modifying existing load-aware scorer
**Rejected**: Energy awareness is orthogonal to load awareness. Users should be able to combine them independently with different weights.

### 3. ε-constraint filter instead of scorer
**Rejected**: A filter can only accept/reject endpoints, not express preferences. The weighted scoring system is the correct mechanism for soft preferences.

## Test Plan

- **Unit tests**: Table-driven tests covering heterogeneous endpoints, missing metrics, single endpoint, and edge cases (zero power, equal scores)
- **Integration**: Works with existing scheduler profiles alongside other scorers
- **Conformance**: Passes all existing scheduler conformance tests unchanged

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| Energy metrics not available | Graceful fallback to TDP-based estimates |
| Carbon API unavailable | Uses `fallbackCarbonIntensity` config value |
| Scoring overhead | <100µs per endpoint — negligible vs. inference latency |
| Weight tuning complexity | Sensible defaults provided; weights are optional |

## References

- Green Software Foundation SCI Specification: https://sci.greensoftware.foundation/
- NVIDIA DCGM Exporter: https://github.com/NVIDIA/dcgm-exporter
- IEA Electricity 2024 Report: https://www.iea.org/reports/electricity-2024
- Full research paper: "Energy-Aware Token-Level Routing for Heterogeneous LLM Inference in Kubernetes"
- Implementation: https://github.com/johnnietse/llm-d-epp-Energy-Aware-Endpoint-Picker-Plugin-
