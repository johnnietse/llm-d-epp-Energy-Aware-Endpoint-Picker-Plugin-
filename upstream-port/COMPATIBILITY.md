# Upstream Interface Compatibility Notes

## ⚠️ Interface Change Detected

As of the latest pull from `llm-d/llm-d-router` (synced 2026-06-01), the `scheduling.Scorer` interface has been updated. The `CycleState` parameter was **removed**.

### Old Interface (what `upstream-port/energy_aware.go` currently implements)

```go
type Scorer interface {
    plugin.Plugin
    Category() ScorerCategory
    Score(ctx context.Context, state *CycleState, request *InferenceRequest,
          endpoints []Endpoint) map[Endpoint]float64
}
```

### New Interface (current upstream `llm-d-router`)

```go
type Scorer interface {
    plugin.Plugin
    Category() ScorerCategory
    Score(ctx context.Context, request *InferenceRequest,
          pods []Endpoint) map[Endpoint]float64
}
```

### What Changed
- `*CycleState` parameter was **removed** from the `Score` method
- The `CycleState` type itself was deleted (`cycle_state.go` removed, replaced by `attributes.go`)
- Parameter name changed from `endpoints` to `pods` (cosmetic)

### Required Fix in `upstream-port/energy_aware.go`

**Before** (line 185):
```go
func (s *EnergyAware) Score(_ context.Context, _ *scheduling.CycleState, request *scheduling.InferenceRequest, endpoints []scheduling.Endpoint) map[scheduling.Endpoint]float64 {
```

**After**:
```go
func (s *EnergyAware) Score(_ context.Context, request *scheduling.InferenceRequest, endpoints []scheduling.Endpoint) map[scheduling.Endpoint]float64 {
```

This is a **one-line change** — simply remove the `_ *scheduling.CycleState` parameter.

### Factory Signature Change

The factory function signature also changed from `json.RawMessage` to `*json.Decoder`:

**Before**:
```go
func Factory(name string, _ json.RawMessage, _ plugin.Handle) (plugin.Plugin, error)
```

**After** (matching current upstream pattern):
```go
func Factory(name string, rawParameters *json.Decoder, handle plugin.Handle) (plugin.Plugin, error)
```

### When to Apply This Fix

Apply this fix when:
1. You are preparing the actual PR to `llm-d/llm-d-router`
2. Building against the latest `llm-d-router` dependencies

The standalone `pkg/` code and tests are NOT affected — they use our own interfaces.

### File Reference

- Current upstream interface: `llm-d-ref/pkg/epp/framework/interface/scheduling/plugins.go` (line 68-72)
- Our file to update: `upstream-port/energy_aware.go` (line 185)
- Example of correct implementation: `llm-d-ref/pkg/epp/framework/plugins/scheduling/scorer/loadaware/load_aware.go` (line 84)
