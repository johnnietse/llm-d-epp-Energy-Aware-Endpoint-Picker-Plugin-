package filter

import (
	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// SLOFilterConfig holds SLO constraint parameters.
// Following the ε-constraint method from Pareto MOO literature:
// instead of mixing latency into the weighted sum, we treat SLOs as
// hard constraints and minimize energy within the feasible region.
//
// References:
//   - throttLLeM (arXiv 2024): SLO-driven GPU frequency control
//   - DistServe (OSDI '24): independent TTFT/TPOT optimization
type SLOFilterConfig struct {
	// MaxTTFT_ms is the maximum allowable Time-To-First-Token in milliseconds.
	// Pods whose estimated prefill latency exceeds this are rejected.
	// 0 = disabled.
	MaxTTFT_ms float64 `yaml:"maxTTFTMs"`

	// MaxTPOT_ms is the maximum allowable Time-Per-Output-Token in milliseconds.
	// Pods whose estimated decode latency exceeds this are rejected.
	// 0 = disabled.
	MaxTPOT_ms float64 `yaml:"maxTPOTMs"`

	// MaxQueueDepth is the maximum queue depth before a pod is considered overloaded.
	// 0 = disabled.
	MaxQueueDepth int `yaml:"maxQueueDepth"`
}

// DefaultSLOFilterConfig returns conservative defaults.
func DefaultSLOFilterConfig() SLOFilterConfig {
	return SLOFilterConfig{
		MaxTTFT_ms:    500.0,  // 500ms TTFT SLO
		MaxTPOT_ms:    100.0,  // 100ms/token TPOT SLO
		MaxQueueDepth: 50,     // max 50 pending requests
	}
}

// SLOFilter implements ε-constraint filtering for the scheduling pipeline.
// It enforces latency SLOs as hard constraints, allowing the downstream
// scorers to optimize purely for energy efficiency within the feasible set.
//
// This is a research improvement over pure weighted-sum scoring:
// "Treat SLOs as hard constraints, then minimize energy within feasibility."
type SLOFilter struct {
	name   string
	store  *signals.EnergyStore
	config SLOFilterConfig
}

// NewSLOFilter creates a new SLO constraint filter.
func NewSLOFilter(name string, store *signals.EnergyStore, config SLOFilterConfig) *SLOFilter {
	if name == "" {
		name = "slo-constraint-filter"
	}
	return &SLOFilter{name: name, store: store, config: config}
}

// Name returns the filter name.
func (f *SLOFilter) Name() string { return f.name }

// FilterPods rejects pods that cannot meet latency SLOs.
// It estimates TTFT from prefill throughput and TPOT from decode throughput.
func (f *SLOFilter) FilterPods(candidates []PodCandidate, phase signals.InferencePhase) []PodCandidate {
	if f.config.MaxTTFT_ms == 0 && f.config.MaxTPOT_ms == 0 && f.config.MaxQueueDepth == 0 {
		return candidates // no SLOs configured
	}

	accepted := make([]PodCandidate, 0, len(candidates))
	for _, c := range candidates {
		profile := f.store.GetProfile(c.Name)
		if profile == nil {
			// No telemetry → accept conservatively (new pod)
			accepted = append(accepted, c)
			continue
		}

		if f.meetsConstraints(*profile, phase) {
			accepted = append(accepted, c)
		}
	}
	return accepted
}

// meetsConstraints checks whether a pod can satisfy the configured SLOs.
func (f *SLOFilter) meetsConstraints(profile signals.EnergyProfile, phase signals.InferencePhase) bool {
	// Queue depth constraint
	if f.config.MaxQueueDepth > 0 && profile.ActiveRequests > f.config.MaxQueueDepth {
		return false
	}

	if profile.TokensPerSecond <= 0 {
		return true // no throughput data → accept
	}

	switch phase {
	case signals.PhasePrefill:
		// Estimate TTFT: assume 256 input tokens / tokens_per_second * 1000 → ms
		if f.config.MaxTTFT_ms > 0 {
			estimatedTTFT_ms := (256.0 / profile.TokensPerSecond) * 1000.0
			// Account for queue delay: each queued request adds ~ estimated_time
			queueDelay_ms := float64(profile.ActiveRequests) * estimatedTTFT_ms * 0.5
			totalEstimate := estimatedTTFT_ms + queueDelay_ms
			if totalEstimate > f.config.MaxTTFT_ms {
				return false
			}
		}

	case signals.PhaseDecode:
		// Estimate TPOT: 1000 / tokens_per_second → ms per token
		if f.config.MaxTPOT_ms > 0 {
			estimatedTPOT_ms := 1000.0 / profile.TokensPerSecond
			if estimatedTPOT_ms > f.config.MaxTPOT_ms {
				return false
			}
		}
	}

	return true
}
