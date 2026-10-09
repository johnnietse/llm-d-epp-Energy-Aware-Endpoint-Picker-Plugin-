# Interface Mapping: Your Code → Upstream llm-d-router

## The 3 Files You'll Submit

Your `upstream-port/` directory now contains production-ready files that map 1:1 to where they'll live in the upstream repo:

| Your File | Upstream Location |
|-----------|-------------------|
| `upstream-port/energy_aware.go` | `pkg/epp/framework/plugins/scheduling/scorer/energyaware/energy_aware.go` |
| `upstream-port/energy_aware_test.go` | `pkg/epp/framework/plugins/scheduling/scorer/energyaware/energy_aware_test.go` |
| `upstream-port/README.md` | `pkg/epp/framework/plugins/scheduling/scorer/energyaware/README.md` |

## Interface Comparison: Your Code vs. Upstream

### Scorer Interface

```diff
- // YOUR OLD CODE (pkg/plugins/scorer/energy_aware_scorer.go)
- func (s *EnergyAwareScorer) ScorePods(phase signals.InferencePhase, pods []PodInfo) map[string]float64

+ // YOUR NEW PORTED CODE (Matches Upstream scheduling.Scorer perfectly)
+ func (s *EnergyAware) Score(ctx context.Context,
+     request *scheduling.InferenceRequest, endpoints []scheduling.Endpoint) map[scheduling.Endpoint]float64
```

**What changed:**
1. `PodInfo` → `scheduling.Endpoint` (has `.GetMetadata().Labels` and `.GetMetrics()`)
2. `phase signals.InferencePhase` → inferred from `request.RequestSizeBytes`
3. Return key: `string` (pod name) → `scheduling.Endpoint` (the object itself)
4. Added `context.Context` (standard upstream args). Note: `*CycleState` was removed in recent upstream versions, and your code natively handles this!

### Plugin Identity

```diff
- // YOUR OLD CODE
- func (s *EnergyAwareScorer) Name() string { return s.name }

+ // UPSTREAM INTERFACE (plugin.Plugin)
+ func (s *EnergyAware) TypedName() plugin.TypedName
+ func (s *EnergyAware) Category() scheduling.ScorerCategory
```

**What changed:**
1. `Name()` → `TypedName()` (returns `plugin.TypedName{Type, Name}`)
2. Added `Category()` → returns `scheduling.Distribution`

### Plugin Construction

```diff
- // YOUR OLD CODE
- func NewEnergyAwareScorer(name string, store *signals.EnergyStore,
-     config EnergyAwareScorerConfig) *EnergyAwareScorer

+ // YOUR NEW PORTED CODE (Matches Upstream Factory perfectly)
+ func Factory(name string, rawParameters *json.Decoder,
+     handle plugin.Handle) (plugin.Plugin, error)
```

**What changed:**
1. `*signals.EnergyStore` dependency removed → energy data now comes from pod labels
2. Config struct → `*json.Decoder` (parsed directly inside Factory)
3. Returns `(plugin.Plugin, error)` instead of concrete type

### Data Access

```diff
- // YOUR CURRENT CODE
- profile := s.store.GetProfile(pod.Name)
- profile.TDP_Watts, profile.CurrentPower_W, profile.TokensPerSecond

+ // UPSTREAM PATTERN
+ labels := endpoint.GetMetadata().Labels
+ tdp := labelFloat(labels, "llm-d.ai/gpu-tdp-watts")
+ power := labelFloat(labels, "llm-d.ai/gpu-power-watts")
+ metrics := endpoint.GetMetrics()
+ queueSize := metrics.WaitingQueueSize
```

**What changed:**
1. `EnergyStore` (in-memory cache) → pod labels (set by DCGM exporter sidecar)
2. `QueueDepth` from `PodInfo` → `WaitingQueueSize` from `endpoint.GetMetrics()`

## What Stayed The Same (Your Core Innovation)

These are your research contributions. **The math is identical:**

| Function | Purpose | Changes |
|----------|---------|---------|
| `rawLatencyScore()` → `computeLatencyScore()` | TDP-based latency proxy | Only renamed, same formula |
| `rawEnergyScore()` → `computeEnergyScore()` | Energy-per-token scoring | Same `1/(1 + EPT/5)` formula |
| `rawCarbonScore()` → `computeCarbonScore()` | Carbon intensity scoring | Same gCO2e calculation |
| `minMaxNormalize()` | Min-max normalization | Identical |
| `hardwareClassEnergyHeuristic()` → `hardwareClassScore()` | Fallback heuristic | Same scores, simplified |
| Weight vectors | Phase-specific weights | Same prefill/decode asymmetry |

## Existing Upstream Scorers (Your Peers)

Your scorer sits alongside these 13 existing scorers:

| Scorer | Category | What it Scores |
|--------|----------|----------------|
| `loadaware` | Distribution | Queue depth / waiting requests |
| `prefix` | Affinity | Prefix cache hit ratio |
| `preciseprefixcache` | Affinity | Exact prefix match length |
| `kvcacheutilization` | Distribution | KV cache usage percentage |
| `queuedepth` | Distribution | Pending request count |
| `sessionaffinity` | Affinity | Session stickiness |
| `loraaffinity` | Affinity | LoRA adapter locality |
| `latency` | Distribution | Response latency estimates |
| `tokenload` | Distribution | Token-level load balancing |
| `nohitlru` | Distribution | LRU eviction avoidance |
| `activerequest` | Distribution | Active request count |
| `contextlengthaware` | Distribution | Context length impact |
| `runningrequests` | Distribution | Running request count |
| **`energyaware` (YOURS)** | **Distribution** | **Power, EPT, carbon** |

## Quick Test

After you fork and place the files, test with:

```bash
cd llm-d-router
cp -r /path/to/upstream-port/ pkg/epp/framework/plugins/scheduling/scorer/energyaware/
go test ./pkg/epp/framework/plugins/scheduling/scorer/energyaware/...
```
