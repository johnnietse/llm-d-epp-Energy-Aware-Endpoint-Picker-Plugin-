// Package filter implements the EnergyBudgetFilter plugin for the llm-d
// Endpoint Picker (EPP). This filter excludes pods that would violate
// energy budget constraints, serving as a hard constraint in the
// scheduling pipeline before scoring occurs.
//
// The filter participates in the "Filter" stage of the scheduling cycle:
//
//	PreSchedule → [DecodeFilter/PrefillFilter] → [EnergyBudgetFilter] → Score → Selection
//
// Pods are excluded if:
//  1. Their current power draw exceeds their TDP × maxUtilizationFactor
//  2. Adding their estimated load would exceed the cluster-wide power budget
//  3. Their energy profile is stale (optionally, controlled by filterStale flag)
package filter

import (
	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// EnergyBudgetFilterConfig holds the configuration parameters for the filter.
type EnergyBudgetFilterConfig struct {
	// MaxClusterPower_W is the maximum total power draw (in Watts) allowed
	// across all pods in the InferencePool. Pods that would push the cluster
	// power above this limit are filtered out.
	MaxClusterPower_W float64 `yaml:"maxClusterPowerWatts"`

	// MaxPodUtilizationFactor is the maximum fraction of a pod's TDP at which
	// it should be accepting new requests. For example, 0.9 means pods drawing
	// more than 90% of their TDP are considered overloaded.
	MaxPodUtilizationFactor float64 `yaml:"maxPodUtilizationFactor"`

	// FilterStalePods controls whether pods with stale energy profiles
	// (i.e., last update older than the EnergyStore's staleDuration) are excluded.
	// Default: false (stale pods are kept with a warning, not filtered).
	FilterStalePods bool `yaml:"filterStalePods"`

	// EstimatedPowerIncrease_W is the estimated additional power draw (in Watts)
	// when a new request is routed to a pod. Used for cluster budget calculation.
	EstimatedPowerIncrease_W float64 `yaml:"estimatedPowerIncreaseWatts"`
}

// DefaultEnergyBudgetFilterConfig returns sensible defaults for the filter.
func DefaultEnergyBudgetFilterConfig() EnergyBudgetFilterConfig {
	return EnergyBudgetFilterConfig{
		MaxClusterPower_W:        2000.0,
		MaxPodUtilizationFactor:  0.9,
		FilterStalePods:          false,
		EstimatedPowerIncrease_W: 25.0,
	}
}

// PodCandidate represents a pod being evaluated by the filter.
// Abstracts over GIE types.Pod for testability.
type PodCandidate struct {
	// Name is the Kubernetes pod name.
	Name string

	// Labels are the pod's Kubernetes labels.
	Labels map[string]string
}

// EnergyBudgetFilter excludes pods that would violate energy constraints.
type EnergyBudgetFilter struct {
	name   string
	store  *signals.EnergyStore
	config EnergyBudgetFilterConfig
}

// FilterResult contains the filter outcome for diagnostics and logging.
type FilterResult struct {
	// Accepted pods that passed the filter.
	Accepted []PodCandidate

	// Rejected contains pod names and the reason for rejection.
	Rejected map[string]string

	// ClusterPowerBefore is the total cluster power before this scheduling decision.
	ClusterPowerBefore float64

	// ClusterPowerHeadroom is the remaining power budget.
	ClusterPowerHeadroom float64
}

// NewEnergyBudgetFilter creates a new filter instance.
func NewEnergyBudgetFilter(name string, store *signals.EnergyStore, config EnergyBudgetFilterConfig) *EnergyBudgetFilter {
	if name == "" {
		name = "energy-budget-filter"
	}
	return &EnergyBudgetFilter{
		name:   name,
		store:  store,
		config: config,
	}
}

// Name returns the plugin name.
func (f *EnergyBudgetFilter) Name() string {
	return f.name
}

// FilterPods filters out pods that violate energy constraints.
// Returns only the pods that pass all energy budget checks.
func (f *EnergyBudgetFilter) FilterPods(pods []PodCandidate) []PodCandidate {
	return f.FilterPodsDetailed(pods).Accepted
}

// FilterPodsDetailed runs the filter and returns detailed results including
// rejection reasons. Useful for logging and debugging.
func (f *EnergyBudgetFilter) FilterPodsDetailed(pods []PodCandidate) FilterResult {
	result := FilterResult{
		Accepted:           make([]PodCandidate, 0, len(pods)),
		Rejected:           make(map[string]string),
		ClusterPowerBefore: f.store.TotalClusterPower(),
	}
	result.ClusterPowerHeadroom = f.config.MaxClusterPower_W - result.ClusterPowerBefore

	for _, pod := range pods {
		if reason := f.shouldReject(pod); reason != "" {
			result.Rejected[pod.Name] = reason
			continue
		}
		result.Accepted = append(result.Accepted, pod)
	}

	return result
}

// shouldReject checks whether a pod should be filtered out.
// Returns empty string if the pod passes, or the rejection reason.
func (f *EnergyBudgetFilter) shouldReject(pod PodCandidate) string {
	profile := f.store.GetProfile(pod.Name)

	// Check 1: No profile — keep or filter based on config
	if profile == nil {
		if f.config.FilterStalePods {
			return "no energy profile available"
		}
		return "" // keep unknown pods
	}

	// Check 2: Stale profile
	if f.config.FilterStalePods && f.store.IsStale(pod.Name) {
		return "stale energy profile"
	}

	// Check 3: Pod power utilization exceeds threshold
	if profile.TDP_Watts > 0 {
		utilization := profile.CurrentPower_W / profile.TDP_Watts
		if utilization > f.config.MaxPodUtilizationFactor {
			return "pod power utilization exceeds threshold"
		}
	}

	// Check 4: Cluster power budget would be exceeded
	currentClusterPower := f.store.TotalClusterPower()
	projectedPower := currentClusterPower + f.config.EstimatedPowerIncrease_W
	if projectedPower > f.config.MaxClusterPower_W {
		return "cluster power budget would be exceeded"
	}

	return "" // pod passes all checks
}
