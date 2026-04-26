// Package config provides adapters that bridge our energy-aware plugins
// with the real Gateway API Inference Extension (GIE) scheduling framework.
//
// This file provides concrete implementations of the GIE scheduling.Filter
// and scheduling.Scorer interfaces, enabling our energy-aware plugins to be
// used directly in the llm-d inference scheduler without any modifications
// to the upstream codebase.
//
// Import paths:
//
//	scheduling "sigs.k8s.io/gateway-api-inference-extension/pkg/epp/framework/interface/scheduling"
//	plugin "sigs.k8s.io/gateway-api-inference-extension/pkg/epp/framework/interface/plugin"
//
// The GIE interfaces are:
//
//	Filter: Filter(ctx, cycleState, request, pods) []Endpoint
//	Scorer: Score(ctx, cycleState, request, pods) map[Endpoint]float64 + Category()
package config

import (
	"context"

	fwkplugin "sigs.k8s.io/gateway-api-inference-extension/pkg/epp/framework/interface/plugin"
	scheduling "sigs.k8s.io/gateway-api-inference-extension/pkg/epp/framework/interface/scheduling"

	"github.com/johnnie/energy-aware-epp/pkg/plugins/filter"
	"github.com/johnnie/energy-aware-epp/pkg/plugins/scorer"
	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// ─── Compile-time interface assertions ──────────────────────────────
// These validate that our adapters satisfy the real GIE interfaces.

var _ scheduling.Filter = &GIEFilterAdapter{}
var _ scheduling.Scorer = &GIEScorerAdapter{}
var _ scheduling.Scorer = &GIECarbonScorerAdapter{}

// ─── Constants ──────────────────────────────────────────────────────

const (
	// EnergyBudgetFilterType is the plugin type registered with the llm-d scheduler.
	EnergyBudgetFilterType = "energy-budget-filter"

	// EnergyAwareScorerType is the plugin type registered with the llm-d scheduler.
	EnergyAwareScorerType = "energy-aware-scorer"

	// CarbonIntensityScorerType is the plugin type registered with the llm-d scheduler.
	CarbonIntensityScorerType = "carbon-intensity-scorer"
)

// ─── GIE Filter Adapter ────────────────────────────────────────────

// GIEFilterAdapter wraps our EnergyBudgetFilter to implement the real
// GIE scheduling.Filter interface.
type GIEFilterAdapter struct {
	inner    *filter.EnergyBudgetFilter
	typeName fwkplugin.TypedName
}

// NewGIEFilterAdapter creates a new GIE-compatible filter adapter.
func NewGIEFilterAdapter(name string, f *filter.EnergyBudgetFilter) *GIEFilterAdapter {
	return &GIEFilterAdapter{
		inner: f,
		typeName: fwkplugin.TypedName{
			Type: EnergyBudgetFilterType,
			Name: name,
		},
	}
}

// TypedName returns the type and name tuple for this plugin instance.
// This satisfies the plugin.Plugin interface embedded in scheduling.Filter.
func (a *GIEFilterAdapter) TypedName() fwkplugin.TypedName {
	return a.typeName
}

// Filter implements scheduling.Filter.
// It converts GIE Endpoints to our internal PodCandidate type, runs the
// energy budget filter, and returns the filtered Endpoints.
func (a *GIEFilterAdapter) Filter(
	ctx context.Context,
	cycleState *scheduling.CycleState,
	request *scheduling.LLMRequest,
	pods []scheduling.Endpoint,
) []scheduling.Endpoint {
	// Convert GIE Endpoints → our PodCandidate type
	candidates := make([]filter.PodCandidate, len(pods))
	for i, ep := range pods {
		candidates[i] = endpointToPodCandidate(ep)
	}

	// Run our filter logic
	accepted := a.inner.FilterPods(candidates)

	// Build a set of accepted pod names
	acceptedSet := make(map[string]bool, len(accepted))
	for _, c := range accepted {
		acceptedSet[c.Name] = true
	}

	// Return only accepted Endpoints (preserving GIE type)
	result := make([]scheduling.Endpoint, 0, len(accepted))
	for _, ep := range pods {
		meta := ep.GetMetadata()
		if meta != nil && acceptedSet[meta.PodName] {
			result = append(result, ep)
		}
	}
	return result
}

// ─── GIE Scorer Adapter ────────────────────────────────────────────

// GIEScorerAdapter wraps our EnergyAwareScorer to implement the real
// GIE scheduling.Scorer interface.
//
// The GIE Scorer.Score receives the full list of pods and returns a
// map[Endpoint]float64 with scores in [0, 1]. This is a perfect match
// for our batch scorer which needs the full list for min-max normalization.
type GIEScorerAdapter struct {
	inner    *scorer.EnergyAwareScorer
	typeName fwkplugin.TypedName
}

// NewGIEScorerAdapter creates a new GIE-compatible scorer adapter.
func NewGIEScorerAdapter(name string, s *scorer.EnergyAwareScorer) *GIEScorerAdapter {
	return &GIEScorerAdapter{
		inner: s,
		typeName: fwkplugin.TypedName{
			Type: EnergyAwareScorerType,
			Name: name,
		},
	}
}

// TypedName satisfies the plugin.Plugin interface.
func (a *GIEScorerAdapter) TypedName() fwkplugin.TypedName {
	return a.typeName
}

// Category returns the scorer category.
// Our energy scorer distributes load to energy-efficient pods, which is
// a balance between affinity (reuse-optimized) and distribution (spread).
func (a *GIEScorerAdapter) Category() scheduling.ScorerCategory {
	return scheduling.Balance
}

// Score implements scheduling.Scorer.
// It converts GIE Endpoints to our PodInfo, determines the inference
// phase from the scheduling profile context, runs our multi-objective
// scorer, and returns normalized scores in [0, 1].
func (a *GIEScorerAdapter) Score(
	ctx context.Context,
	cycleState *scheduling.CycleState,
	request *scheduling.LLMRequest,
	pods []scheduling.Endpoint,
) map[scheduling.Endpoint]float64 {
	// Determine inference phase from cycle state
	phase := inferPhaseFromHeaders(request)

	// Convert Endpoints → PodInfo
	podInfos := make([]scorer.PodInfo, len(pods))
	for i, ep := range pods {
		podInfos[i] = endpointToPodInfo(ep)
	}

	// Run our scorer (returns map[podName]float64 in [0,1])
	floatScores := a.inner.ScorePods(phase, podInfos)

	// Map back to Endpoint keys
	result := make(map[scheduling.Endpoint]float64, len(pods))
	for _, ep := range pods {
		meta := ep.GetMetadata()
		if meta != nil {
			if score, ok := floatScores[meta.PodName]; ok {
				result[ep] = score
			} else {
				result[ep] = 0.5 // neutral fallback
			}
		}
	}
	return result
}

// ─── GIE Carbon Scorer Adapter ──────────────────────────────────────

// GIECarbonScorerAdapter wraps CarbonIntensityScorer for the GIE Scorer interface.
type GIECarbonScorerAdapter struct {
	inner    *scorer.CarbonIntensityScorer
	typeName fwkplugin.TypedName
}

// NewGIECarbonScorerAdapter creates a new GIE-compatible carbon scorer adapter.
func NewGIECarbonScorerAdapter(name string, s *scorer.CarbonIntensityScorer) *GIECarbonScorerAdapter {
	return &GIECarbonScorerAdapter{
		inner: s,
		typeName: fwkplugin.TypedName{
			Type: CarbonIntensityScorerType,
			Name: name,
		},
	}
}

// TypedName satisfies the plugin.Plugin interface.
func (a *GIECarbonScorerAdapter) TypedName() fwkplugin.TypedName {
	return a.typeName
}

// Category returns the scorer category.
// Carbon scoring is a distribution concern — routing to lower-carbon endpoints.
func (a *GIECarbonScorerAdapter) Category() scheduling.ScorerCategory {
	return scheduling.Distribution
}

// Score implements scheduling.Scorer for carbon intensity.
func (a *GIECarbonScorerAdapter) Score(
	ctx context.Context,
	cycleState *scheduling.CycleState,
	request *scheduling.LLMRequest,
	pods []scheduling.Endpoint,
) map[scheduling.Endpoint]float64 {
	// Convert Endpoints → PodInfo
	podInfos := make([]scorer.PodInfo, len(pods))
	for i, ep := range pods {
		podInfos[i] = endpointToPodInfo(ep)
	}

	// Run our carbon scorer
	floatScores := a.inner.ScorePods(podInfos)

	// Map back to Endpoint keys
	result := make(map[scheduling.Endpoint]float64, len(pods))
	for _, ep := range pods {
		meta := ep.GetMetadata()
		if meta != nil {
			if score, ok := floatScores[meta.PodName]; ok {
				result[ep] = score
			} else {
				result[ep] = 0.5
			}
		}
	}
	return result
}

// ─── Helper Functions ───────────────────────────────────────────────

// endpointToPodCandidate converts a GIE Endpoint to our filter.PodCandidate.
func endpointToPodCandidate(ep scheduling.Endpoint) filter.PodCandidate {
	meta := ep.GetMetadata()
	if meta == nil {
		return filter.PodCandidate{Name: "unknown"}
	}
	return filter.PodCandidate{
		Name:   meta.PodName,
		Labels: meta.Labels,
	}
}

// endpointToPodInfo converts a GIE Endpoint to our scorer.PodInfo.
func endpointToPodInfo(ep scheduling.Endpoint) scorer.PodInfo {
	meta := ep.GetMetadata()
	metrics := ep.GetMetrics()

	info := scorer.PodInfo{
		Name: "unknown",
	}

	if meta != nil {
		info.Name = meta.PodName
		info.Labels = meta.Labels
	}

	if metrics != nil {
		info.QueueDepth = metrics.RunningRequestsSize + metrics.WaitingQueueSize
	}

	return info
}

// inferPhaseFromHeaders determines the inference phase from the LLM request.
// The llm-d scheduler uses headers (set by the DisaggHeadersHandler plugin)
// to signal the inference phase (prefill vs decode).
func inferPhaseFromHeaders(request *scheduling.LLMRequest) signals.InferencePhase {
	if request == nil || request.Headers == nil {
		return signals.PhaseDecode // conservative default
	}

	// The llm-d scheduler sets the "x-scheduling-profile" header
	// via the DisaggHeadersHandler plugin.
	if profile, ok := request.Headers["x-scheduling-profile"]; ok {
		switch profile {
		case "prefill":
			return signals.PhasePrefill
		case "decode":
			return signals.PhaseDecode
		}
	}

	return signals.PhaseDecode
}
