// Package config provides the integration point for registering the energy-aware
// plugins with the llm-d inference scheduler's SchedulingProfile system.
//
// When forking the llm-d-inference-scheduler, add the following to
// pkg/epp/scheduling/config.go (or similar registration file):
//
//	import energyepp "github.com/johnnie/energy-aware-epp/pkg/config"
//
//	func init() {
//	    RegisterFilter("energy-budget-filter", func(store interface{}) Filter {
//	        return energyepp.NewEnergyBudgetFilterAdapter(...)
//	    })
//	    RegisterScorer("energy-aware-scorer", func(store interface{}) Scorer {
//	        return energyepp.NewEnergyAwareScorerAdapter(...)
//	    })
//	}
//
// This file provides convenience constructors for creating the complete
// SchedulingProfile with energy-aware plugins preconfigured.

package config

import (
	"context"
	"log"

	"github.com/johnnie/energy-aware-epp/pkg/plugins/filter"
	"github.com/johnnie/energy-aware-epp/pkg/plugins/scorer"
	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// GIESchedulingProfile mimics the GIE SchedulingProfile concept.
// In production, this would be the real GIE SchedulingProfile type.
type GIESchedulingProfile struct {
	Name         string
	Filters      []FilterPlugin
	Scorers      []ScorerPlugin
	BatchScorers []BatchScorerPlugin
	Picker       PickerFunc
}

// FilterPlugin is the interface for GIE-compatible filter plugins.
type FilterPlugin interface {
	Name() string
	Filter(ctx context.Context, cs GIECycleState, req GIERequest, pods []GIEPod) []GIEPod
}

// ScorerPlugin is the interface for GIE-compatible scorer plugins (per-pod).
type ScorerPlugin interface {
	Name() string
	Score(ctx context.Context, cs GIECycleState, req GIERequest, pod GIEPod) (int64, error)
}

// BatchScorerPlugin is an extended scorer that scores all pods at once.
// This is preferred for scorers that need min-max normalization (like ours).
type BatchScorerPlugin interface {
	Name() string
	ScoreBatch(ctx context.Context, cs GIECycleState, req GIERequest, pods []GIEPod) map[string]int64
}

// PickerFunc selects the best pod from scored candidates.
type PickerFunc func(scored map[string]int64) string

// MaxScorePicker selects the pod with the highest score.
func MaxScorePicker(scored map[string]int64) string {
	best := ""
	bestScore := int64(-1)
	for name, score := range scored {
		if score > bestScore {
			bestScore = score
			best = name
		}
	}
	return best
}

// ─── Batch Scorer Adapters ──────────────────────────────────────────

// EnergyAwareBatchScorer wraps EnergyAwareScorer for batch scoring.
type EnergyAwareBatchScorer struct {
	inner *scorer.EnergyAwareScorer
}

func NewEnergyAwareBatchScorer(s *scorer.EnergyAwareScorer) *EnergyAwareBatchScorer {
	return &EnergyAwareBatchScorer{inner: s}
}

func (b *EnergyAwareBatchScorer) Name() string { return b.inner.Name() }

func (b *EnergyAwareBatchScorer) ScoreBatch(
	ctx context.Context, cs GIECycleState, req GIERequest, pods []GIEPod,
) map[string]int64 {
	phase := inferPhaseFromCycleState(cs)
	podInfos := make([]scorer.PodInfo, len(pods))
	for i, p := range pods {
		podInfos[i] = giePodToPodInfo(p)
	}
	floatScores := b.inner.ScorePods(phase, podInfos)
	result := make(map[string]int64, len(floatScores))
	for name, score := range floatScores {
		result[name] = int64(score * 1000)
	}
	return result
}

// CarbonIntensityBatchScorer wraps CarbonIntensityScorer for batch scoring.
type CarbonIntensityBatchScorer struct {
	inner *scorer.CarbonIntensityScorer
}

func NewCarbonIntensityBatchScorer(s *scorer.CarbonIntensityScorer) *CarbonIntensityBatchScorer {
	return &CarbonIntensityBatchScorer{inner: s}
}

func (b *CarbonIntensityBatchScorer) Name() string { return b.inner.Name() }

func (b *CarbonIntensityBatchScorer) ScoreBatch(
	ctx context.Context, cs GIECycleState, req GIERequest, pods []GIEPod,
) map[string]int64 {
	podInfos := make([]scorer.PodInfo, len(pods))
	for i, p := range pods {
		podInfos[i] = giePodToPodInfo(p)
	}
	floatScores := b.inner.ScorePods(podInfos)
	result := make(map[string]int64, len(floatScores))
	for name, score := range floatScores {
		result[name] = int64(score * 1000)
	}
	return result
}

// ─── Profile Constructor ────────────────────────────────────────────

// NewGIESchedulingProfile creates a complete GIE-compatible SchedulingProfile
// with the energy-aware filter, energy-aware scorer, and carbon scorer.
//
// Uses batch scorers for proper min-max normalization across the full pod set.
func NewGIESchedulingProfile(store *signals.EnergyStore) *GIESchedulingProfile {
	budgetFilter := filter.NewEnergyBudgetFilter(
		"energy-budget-filter", store,
		filter.DefaultEnergyBudgetFilterConfig(),
	)

	energyScorer := scorer.NewEnergyAwareScorer(
		"energy-aware-scorer", store,
		scorer.DefaultEnergyAwareScorerConfig(),
	)
	carbonScorer := scorer.NewCarbonIntensityScorer(
		"carbon-intensity-scorer", store,
		scorer.DefaultCarbonIntensityScorerConfig(),
	)

	return &GIESchedulingProfile{
		Name: "energy-aware",
		Filters: []FilterPlugin{
			NewEnergyBudgetFilterAdapter(budgetFilter),
		},
		BatchScorers: []BatchScorerPlugin{
			NewEnergyAwareBatchScorer(energyScorer),
			NewCarbonIntensityBatchScorer(carbonScorer),
		},
		Picker: MaxScorePicker,
	}
}

// Schedule runs the full scheduling pipeline: Filter → Score → Pick.
// This simulates the GIE scheduling lifecycle for one inference request.
func (sp *GIESchedulingProfile) Schedule(
	ctx context.Context,
	cycleState GIECycleState,
	request GIERequest,
	pods []GIEPod,
) (string, error) {
	// Phase 1: Filter
	candidates := pods
	for _, f := range sp.Filters {
		candidates = f.Filter(ctx, cycleState, request, candidates)
		if len(candidates) == 0 {
			log.Printf("[%s] All pods filtered out by %s", sp.Name, f.Name())
			return "", nil
		}
	}

	// Phase 2: Score
	aggregated := make(map[string]int64, len(candidates))
	for _, pod := range candidates {
		aggregated[pod.GetName()] = 0
	}

	// Batch scorers (preferred — proper normalization)
	for _, bs := range sp.BatchScorers {
		scores := bs.ScoreBatch(ctx, cycleState, request, candidates)
		for name, score := range scores {
			aggregated[name] += score
		}
	}

	// Per-pod scorers (fallback for simple scorers)
	for _, s := range sp.Scorers {
		for _, pod := range candidates {
			score, err := s.Score(ctx, cycleState, request, pod)
			if err != nil {
				log.Printf("[%s] Scorer %s error for %s: %v", sp.Name, s.Name(), pod.GetName(), err)
				continue
			}
			aggregated[pod.GetName()] += score
		}
	}

	// Phase 3: Pick
	if sp.Picker == nil {
		return MaxScorePicker(aggregated), nil
	}
	return sp.Picker(aggregated), nil
}
