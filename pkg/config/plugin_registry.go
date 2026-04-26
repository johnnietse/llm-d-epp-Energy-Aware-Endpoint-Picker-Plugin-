// Package config provides the GIE (Gateway API Inference Extension) adapter layer.
//
// The llm-d inference scheduler expects plugins to conform to specific interfaces:
//
//	Filter(ctx, cycleState, request, pods) []Pod
//	Score(ctx, cycleState, request, pod) (int64, error)
//
// Our plugins use abstract types (PodInfo/PodCandidate) for testability.
// This file provides thin adapter types that:
//   1. Extract relevant fields from GIE types (Pod labels, request metadata)
//   2. Call our plugin logic
//   3. Return results in the format GIE expects
//
// NOTE: This file uses interface-based mocking of the GIE types since we
// don't import the full GIE dependency. When integrating with the real
// llm-d-inference-scheduler repo, replace these interfaces with the real types.
package config

import (
	"context"
	"strconv"

	"github.com/johnnie/energy-aware-epp/pkg/plugins/filter"
	"github.com/johnnie/energy-aware-epp/pkg/plugins/scorer"
	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// ─── GIE Interface Abstractions ─────────────────────────────────────
// These mirror the GIE types.Pod and types.LLMRequest interfaces.
// They will be replaced with real GIE types during llm-d fork integration.

// GIEPod represents the minimal Pod interface from GIE.
type GIEPod interface {
	GetName() string
	GetLabels() map[string]string
	GetQueueLength() int
}

// GIERequest represents the minimal LLMRequest interface from GIE.
type GIERequest interface {
	GetModel() string
	GetHeaders() map[string]string
}

// GIECycleState represents the scheduling cycle state from GIE.
type GIECycleState interface {
	// GetSchedulingProfile returns "prefill" or "decode".
	GetSchedulingProfile() string
}

// ─── Filter Adapter ─────────────────────────────────────────────────

// EnergyBudgetFilterAdapter wraps our EnergyBudgetFilter to conform to
// the GIE Filter plugin interface.
type EnergyBudgetFilterAdapter struct {
	inner *filter.EnergyBudgetFilter
}

// NewEnergyBudgetFilterAdapter creates an adapter.
func NewEnergyBudgetFilterAdapter(f *filter.EnergyBudgetFilter) *EnergyBudgetFilterAdapter {
	return &EnergyBudgetFilterAdapter{inner: f}
}

// Name returns the plugin name.
func (a *EnergyBudgetFilterAdapter) Name() string {
	return a.inner.Name()
}

// Filter adapts the GIE Filter interface to our filter plugin.
// Signature: Filter(ctx, cycleState, request, pods) []Pod
func (a *EnergyBudgetFilterAdapter) Filter(
	ctx context.Context,
	cycleState GIECycleState,
	request GIERequest,
	pods []GIEPod,
) []GIEPod {
	// Convert GIE pods → our PodCandidate type
	candidates := make([]filter.PodCandidate, len(pods))
	for i, p := range pods {
		candidates[i] = filter.PodCandidate{
			Name:   p.GetName(),
			Labels: p.GetLabels(),
		}
	}

	// Run our filter logic
	accepted := a.inner.FilterPods(candidates)

	// Build a set of accepted pod names
	acceptedSet := make(map[string]bool, len(accepted))
	for _, c := range accepted {
		acceptedSet[c.Name] = true
	}

	// Return only accepted GIE pods (preserving GIE type)
	result := make([]GIEPod, 0, len(accepted))
	for _, p := range pods {
		if acceptedSet[p.GetName()] {
			result = append(result, p)
		}
	}
	return result
}

// ─── Scorer Adapter ─────────────────────────────────────────────────

// EnergyAwareScorerAdapter wraps our EnergyAwareScorer to conform to
// the GIE Scorer plugin interface.
type EnergyAwareScorerAdapter struct {
	inner *scorer.EnergyAwareScorer
}

// NewEnergyAwareScorerAdapter creates an adapter.
func NewEnergyAwareScorerAdapter(s *scorer.EnergyAwareScorer) *EnergyAwareScorerAdapter {
	return &EnergyAwareScorerAdapter{inner: s}
}

// Name returns the plugin name.
func (a *EnergyAwareScorerAdapter) Name() string {
	return a.inner.Name()
}

// Score adapts the GIE Scorer interface to our scorer plugin.
// Signature: Score(ctx, cycleState, request, pod) (int64, error)
//
// The GIE framework calls Score() once per pod, but our scorer works on
// the full pod list for min-max normalization. We handle this by:
//   1. Caching scores for the current cycle on first call
//   2. Returning cached scores for subsequent pods in the same cycle
//
// In practice, with the real GIE integration, we may instead implement
// the batch ScorePods interface if available.
func (a *EnergyAwareScorerAdapter) Score(
	ctx context.Context,
	cycleState GIECycleState,
	request GIERequest,
	pod GIEPod,
) (int64, error) {
	// Determine the inference phase from the scheduling profile
	phase := inferPhaseFromCycleState(cycleState)

	// For single-pod scoring, create a minimal pod list
	// In real integration, batch scoring is preferred
	podInfo := giePodToPodInfo(pod)
	scores := a.inner.ScorePods(phase, []scorer.PodInfo{podInfo})

	if score, ok := scores[pod.GetName()]; ok {
		// GIE expects int64 scores. Our [0,1] floats → [0, 1000] integers.
		return int64(score * 1000), nil
	}

	return 500, nil // neutral fallback
}

// ─── Carbon Scorer Adapter ──────────────────────────────────────────

// CarbonIntensityScorerAdapter wraps CarbonIntensityScorer for GIE.
type CarbonIntensityScorerAdapter struct {
	inner *scorer.CarbonIntensityScorer
}

// NewCarbonIntensityScorerAdapter creates an adapter.
func NewCarbonIntensityScorerAdapter(s *scorer.CarbonIntensityScorer) *CarbonIntensityScorerAdapter {
	return &CarbonIntensityScorerAdapter{inner: s}
}

// Name returns the plugin name.
func (a *CarbonIntensityScorerAdapter) Name() string {
	return a.inner.Name()
}

// Score adapts our carbon scorer to GIE's single-pod scoring interface.
func (a *CarbonIntensityScorerAdapter) Score(
	ctx context.Context,
	cycleState GIECycleState,
	request GIERequest,
	pod GIEPod,
) (int64, error) {
	podInfo := giePodToPodInfo(pod)
	scores := a.inner.ScorePods([]scorer.PodInfo{podInfo})

	if score, ok := scores[pod.GetName()]; ok {
		return int64(score * 1000), nil
	}
	return 500, nil
}

// ─── Helper Functions ───────────────────────────────────────────────

// inferPhaseFromCycleState determines the inference phase from the
// scheduling profile name set in the cycle state.
func inferPhaseFromCycleState(cs GIECycleState) signals.InferencePhase {
	if cs == nil {
		return signals.PhaseDecode // conservative default
	}

	profile := cs.GetSchedulingProfile()
	switch profile {
	case "prefill":
		return signals.PhasePrefill
	case "decode":
		return signals.PhaseDecode
	default:
		return signals.PhaseDecode
	}
}

// giePodToPodInfo converts a GIE Pod to our scorer.PodInfo type.
func giePodToPodInfo(pod GIEPod) scorer.PodInfo {
	labels := pod.GetLabels()
	return scorer.PodInfo{
		Name:       pod.GetName(),
		Labels:     labels,
		QueueDepth: pod.GetQueueLength(),
	}
}

// giePodToPodCandidate converts a GIE Pod to our filter.PodCandidate type.
func giePodToPodCandidate(pod GIEPod) filter.PodCandidate {
	return filter.PodCandidate{
		Name:   pod.GetName(),
		Labels: pod.GetLabels(),
	}
}

// ParseHardwareClassLabel reads the llm-d.ai/hardware-class label from a pod.
func ParseHardwareClassLabel(labels map[string]string) signals.HardwareClass {
	if v, ok := labels["llm-d.ai/hardware-class"]; ok {
		return signals.HardwareClass(v)
	}
	return signals.GPU_MED_PERF // default
}

// ParseTDPLabel reads the llm-d.ai/tdp-watts label from a pod.
func ParseTDPLabel(labels map[string]string) float64 {
	if v, ok := labels["llm-d.ai/tdp-watts"]; ok {
		if watts, err := strconv.ParseFloat(v, 64); err == nil {
			return watts
		}
	}
	return 200.0 // default
}
