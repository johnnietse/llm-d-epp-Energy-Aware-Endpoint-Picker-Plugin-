# Upstream Interface Compatibility Notes

> **Status as of 2026-09-17: NOT compatible.** Copying `energy_aware.go` and
> `energy_aware_test.go` into `llm-d-router` at `e149f34f`
> (`pkg/epp/framework/plugins/scheduling/scorer/energyaware/`) fails to
> build: `scheduling.Metrics` is undefined (endpoint metrics moved to the
> data layer), and the tests call `Score` with the removed `CycleState`
> argument. This directory's `go.mod` also declares no dependencies, so it
> does not build standalone. The "Ready for Merge" section below is out of
> date. The replacement design is in `docs/plan/technical-plan-v2-2026-09.md`
> (out-of-tree plugin module against a pinned upstream commit).

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

**STATUS: FIXED ✅**

The one-line fix has been **applied** to `upstream-port/energy_aware.go` (as of June 2026). The `_ *scheduling.CycleState` parameter has been removed from the `Score` function, and the `Factory` signature was updated to use `*json.Decoder`.

**Current Implementation:**
```go
func (s *EnergyAware) Score(_ context.Context, request *scheduling.InferenceRequest, endpoints []scheduling.Endpoint) map[scheduling.Endpoint]float64 {
```

### Ready for Merge

Because these changes have been applied, the code in `upstream-port/` is now **100% API compatible** with the current main branch of `llm-d-router`. You are ready to open a Pull Request.

The standalone `pkg/` code and tests are NOT affected — they use our own internal test interfaces.

### File Reference

- Current upstream interface: `llm-d-ref/pkg/epp/framework/interface/scheduling/plugins.go` (line 68-72)
- Our file to update: `upstream-port/energy_aware.go` (line 185)
- Example of correct implementation: `llm-d-ref/pkg/epp/framework/plugins/scheduling/scorer/loadaware/load_aware.go` (line 84)
