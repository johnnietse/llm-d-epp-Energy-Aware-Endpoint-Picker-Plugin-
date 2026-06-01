# Integration Plan: Energy-Aware Scorer → llm-d/llm-d-router

## Upstream Architecture (What You're Integrating Into)

The `llm-d-router` has a clean plugin pipeline:

```
pkg/epp/framework/plugins/
├── scheduling/
│   ├── filter/         ← Pre-routing checks (your EnergyBudgetFilter goes here)
│   ├── scorer/         ← Endpoint ranking  (your EnergyAwareScorer goes here)
│   ├── picker/         ← Final selection from scored candidates
│   ├── profilehandler/ ← Scheduling profile management
│   └── test/           ← Integration tests
├── datalayer/          ← Data access plugins
├── flowcontrol/        ← Rate limiting, queuing
└── requestcontrol/     ← Request modification
```

### The Scoring Pipeline

```
Incoming Request
      │
      ▼
  filter/         ← "Should this endpoint be considered?"
      │               Existing: low-latency filter, capacity filter
      │               YOUR ADD: EnergyBudgetFilter
      ▼
  scorer/         ← "How good is each remaining endpoint?"
      │               Existing: prefix-cache scorer, load-aware scorer
      │               YOUR ADD: EnergyAwareScorer
      ▼
  picker/         ← "Pick the best-scored endpoint"
      │               Existing: max-score picker
      ▼
  Route to endpoint
```

## Code Mapping: Your Files → Upstream Location

| Your File | Upstream Target | What Changes |
|-----------|----------------|-------------|
| `pkg/plugins/scorer/energy_aware_scorer.go` | `pkg/epp/framework/plugins/scheduling/scorer/energy_aware.go` | Adapt to upstream `Scorer` interface |
| `pkg/plugins/scorer/energy_aware_scorer_test.go` | `pkg/epp/framework/plugins/scheduling/scorer/energy_aware_test.go` | Use upstream test helpers |
| `pkg/plugins/filter/energy_budget_filter.go` | `pkg/epp/framework/plugins/scheduling/filter/energy_budget.go` | Adapt to upstream `Filter` interface |
| `pkg/plugins/filter/energy_budget_filter_test.go` | `pkg/epp/framework/plugins/scheduling/filter/energy_budget_test.go` | Use upstream test helpers |
| `pkg/plugins/scraper/dcgm_scraper.go` | `pkg/epp/framework/plugins/datalayer/dcgm_energy.go` | Adapt to upstream data layer interface |
| `pkg/signals/energy_store.go` | `pkg/epp/framework/plugins/scheduling/scorer/energy_store.go` | Internal to scorer, or shared via datalayer |

## Step-by-Step Integration

### Step 1: Fork and Clone (5 minutes)

```bash
# Fork on GitHub: https://github.com/llm-d/llm-d-router/fork

# Clone your fork
git clone https://github.com/YOUR_USERNAME/llm-d-router.git
cd llm-d-router

# Add upstream remote
git remote add upstream https://github.com/llm-d/llm-d-router.git

# Create feature branch
git checkout -b feat/energy-aware-scorer
```

### Step 2: Study the Existing Scorer Interface (30 minutes)

Read these files in the upstream repo to understand the interface:

```bash
# Scorer interface definition
cat pkg/epp/framework/plugins/scheduling/scorer/

# Existing scorer implementations (copy this pattern)
ls pkg/epp/framework/plugins/scheduling/scorer/

# Filter interface  
cat pkg/epp/framework/plugins/scheduling/filter/

# How plugins are registered
cat pkg/epp/framework/plugins/scheduling/profilehandler/
```

> [!IMPORTANT]
> The upstream uses `scheduling.Scorer` and `scheduling.Filter` interfaces. Your scorer must implement these exact interfaces, not your own `PodInfo` types.

### Step 3: Port the Energy Scorer (2-4 hours)

Create your scorer file following the upstream pattern:

```
pkg/epp/framework/plugins/scheduling/scorer/
├── energy_aware.go          ← NEW: Your scorer
├── energy_aware_test.go     ← NEW: Your tests
└── ... (existing scorers)
```

**Key adaptation needed:** Your current scorer uses custom `PodInfo` and `signals.EnergyProfile` types. The upstream expects you to work with their `types.Pod` and scheduling framework types. You'll need to:

1. Replace `PodInfo` → use upstream pod types
2. Replace `signals.EnergyStore` → read from pod labels or a new datalayer plugin
3. Keep your scoring math (`rawLatencyScore`, `rawEnergyScore`, `rawCarbonScore`) intact
4. Implement the upstream `Scorer` interface methods

### Step 4: Port the Energy Budget Filter (1-2 hours)

```
pkg/epp/framework/plugins/scheduling/filter/
├── energy_budget.go         ← NEW: Your filter
├── energy_budget_test.go    ← NEW: Your tests
└── ... (existing filters)
```

### Step 5: Add DCGM Data Source (2-3 hours)

Your DCGM scraper needs to become a datalayer plugin that feeds power telemetry to the scorer:

```
pkg/epp/framework/plugins/datalayer/
├── dcgm_energy.go           ← NEW: Power telemetry from DCGM
├── dcgm_energy_test.go      ← NEW: Tests
└── ... (existing data sources)
```

### Step 6: Run Upstream Tests (30 minutes)

```bash
# Run all tests
make test-unit

# Run only your scorer tests
make test-filter PATTERN=TestEnergyAware

# Lint
make lint
```

### Step 7: Test in Kind Dev Cluster (1-2 hours)

```bash
# Build and deploy to local Kind cluster
make env-dev-kind

# Verify your scorer is loaded
kubectl logs -l app=endpoint-picker | grep energy

# Send test requests
curl http://localhost:30080/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"TinyLlama/TinyLlama-1.1B-Chat-v1.0","prompt":"hi","max_tokens":10}'
```

### Step 8: Submit PR (30 minutes)

```bash
# Stage changes
git add pkg/epp/framework/plugins/scheduling/scorer/energy_aware*.go
git add pkg/epp/framework/plugins/scheduling/filter/energy_budget*.go
git add pkg/epp/framework/plugins/datalayer/dcgm_energy*.go

# Commit with DCO sign-off (REQUIRED by llm-d)
git commit -s -m "feat(scorer): add energy-aware scoring plugin for heterogeneous hardware

Adds a new scoring plugin that considers GPU power consumption
(via DCGM) alongside latency and queue depth when making routing
decisions. Uses asymmetric weight vectors for prefill vs decode
phases to optimize energy-per-token.

Key features:
- Phase-aware scoring: latency-dominant for prefill, energy-dominant for decode
- DCGM power telemetry integration
- Energy budget filter for cluster-wide power cap enforcement
- Carbon-aware scoring using grid carbon intensity

Signed-off-by: Johnnie Tse <your@email.com>"

# Push
git push origin feat/energy-aware-scorer
```

Then open a PR on GitHub.

## Before You Do Anything: Open an Issue First

Per their contributing guide: *"For large changes please create an issue first describing the change so the maintainers can do an assessment."*

### Issue Template

Go to: https://github.com/llm-d/llm-d-router/issues/new

**Title:** `[Feature] Energy-aware scoring plugin for power-efficient LLM routing`

**Body:**

```markdown
## Summary

I'd like to contribute an energy-aware scoring plugin that considers GPU power
consumption when making endpoint routing decisions. This extends the existing
scoring framework alongside PrefixCacheScorer and LoadAwareScorer.

## Motivation

Current scoring optimizes for KV-cache locality and load, but not energy
efficiency. With heterogeneous hardware (H100 + A100 + inference ASICs),
energy-per-token varies 6-10x across endpoints. For decode-phase tokens
(which are memory-bandwidth-bound, not compute-bound), routing to
lower-power accelerators saves energy without sacrificing latency.

This aligns with llm-d's disaggregation architecture: prefill and decode
have fundamentally different resource profiles.

## Design

### Scorer: `EnergyAwareScorer`
- Implements the `scheduling.Scorer` interface
- Three sub-scores: latency, energy-per-token, carbon intensity
- Asymmetric weight vectors: prefill → latency-dominant, decode → energy-dominant
- Data source: DCGM metrics via Prometheus (DCGM_FI_DEV_POWER_USAGE)

### Filter: `EnergyBudgetFilter`
- Implements the `scheduling.Filter` interface
- Rejects endpoints exceeding a configurable power budget (cluster-wide cap)

### Data Layer: DCGM Energy Scraper
- Polls DCGM/nvidia-smi for real-time GPU power draw
- Computes energy-per-token from power and throughput metrics

## Evidence

I have a working prototype with:
- 93 unit tests, all passing
- 1,000-cycle E2E simulation showing correct routing
- Real A100 power profiles from Queen's University HPC

Prototype: https://github.com/YOUR_USERNAME/energy-aware-epp

## Questions for Maintainers

1. Should this be a built-in scorer or a separate optional plugin?
2. Where should DCGM power data be ingested — datalayer plugin or pod labels?
3. Is there an existing plan for power/energy awareness in the router?
4. Preferred SIG channel: #sig-router or #sig-observability?
```

## Communication Channels

| Channel | URL | When to Use |
|---------|-----|-------------|
| Slack `#sig-router` | [llm-d.slack.com](https://llm-d.slack.com/messages/sig-router) | Day-to-day discussion, quick feedback |
| Community Meeting | Wed 10AM PDT [Google Meet](https://meet.google.com/zij-zekm-jvt) | Present your proposal |
| GitHub Issue | [llm-d-router/issues](https://github.com/llm-d/llm-d-router/issues) | Formal proposal, get maintainer sign-off |
| Google Group | [llm-d-contributors](https://groups.google.com/g/llm-d-contributors) | Architecture discussions |

## Your Immediate Next Steps (In Order)

```
Today:    1. Join llm-d Slack → https://llm-d.ai/slack
          2. Introduce yourself in #sig-router
          
This week: 3. Open the GitHub issue (template above)
           4. Fork llm-d/llm-d-router
           5. Read docs/architecture.md and docs/create_new_filter.md

Next week: 6. Clone your fork and study existing scorer code
           7. Port EnergyAwareScorer to upstream interface
           8. Run `make test-unit` to verify
           9. Test in Kind cluster with `make env-dev-kind`

When ready: 10. Submit PR with DCO sign-off
```
