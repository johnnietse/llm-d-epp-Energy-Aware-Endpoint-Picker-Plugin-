// Package scorer implements the CarbonIntensityScorer, a standalone scorer
// that evaluates pods based on their estimated carbon footprint per token.
//
// This scorer can operate independently or alongside the EnergyAwareScorer.
// When used together, it provides a dedicated carbon dimension that can be
// weighted separately in the scheduling profile.
//
// The carbon score is computed as:
//
//	gCO2e/token = (power_kW × carbon_intensity_gCO2/kWh) / tokens_per_sec / 3600
//
// Pods with lower gCO2e/token get higher scores (inverse relationship).
package scorer

import (
	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// CarbonIntensityScorerConfig holds configuration for the carbon scorer.
type CarbonIntensityScorerConfig struct {
	// FallbackCarbonIntensity is used when the external API is unavailable.
	// Default: 390 gCO2/kWh (US grid average).
	FallbackCarbonIntensity float64 `yaml:"fallbackCarbonIntensity"`
}

// DefaultCarbonIntensityScorerConfig returns defaults.
func DefaultCarbonIntensityScorerConfig() CarbonIntensityScorerConfig {
	return CarbonIntensityScorerConfig{
		FallbackCarbonIntensity: 390.0,
	}
}

// CarbonIntensityScorer scores pods inversely proportional to their
// estimated gCO2e per output token. Lower carbon = higher score.
type CarbonIntensityScorer struct {
	name   string
	store  *signals.EnergyStore
	config CarbonIntensityScorerConfig
}

// NewCarbonIntensityScorer creates a new scorer instance.
func NewCarbonIntensityScorer(name string, store *signals.EnergyStore, config CarbonIntensityScorerConfig) *CarbonIntensityScorer {
	if name == "" {
		name = "carbon-intensity-scorer"
	}
	return &CarbonIntensityScorer{
		name:   name,
		store:  store,
		config: config,
	}
}

// Name returns the plugin name.
func (s *CarbonIntensityScorer) Name() string {
	return s.name
}

// ScorePods scores pods based on carbon footprint.
// Returns scores in range [0, 1] where higher = lower carbon.
func (s *CarbonIntensityScorer) ScorePods(pods []PodInfo) map[string]float64 {
	if len(pods) == 0 {
		return nil
	}

	ext := s.store.GetExternalSignals()
	carbonIntensity := ext.CarbonIntensity_gCO2_kWh
	if carbonIntensity <= 0 {
		carbonIntensity = s.config.FallbackCarbonIntensity
	}

	rawScores := make([]float64, len(pods))
	for i, pod := range pods {
		profile := s.store.GetProfile(pod.Name)
		rawScores[i] = s.rawCarbonScore(profile, carbonIntensity)
	}

	// Normalize to [0, 1]
	normalized := minMaxNormalize(rawScores)
	scores := make(map[string]float64, len(pods))
	for i, pod := range pods {
		scores[pod.Name] = normalized[i]
	}

	return scores
}

// rawCarbonScore computes the raw carbon footprint score for a pod.
// Higher is better (lower carbon footprint).
func (s *CarbonIntensityScorer) rawCarbonScore(profile *signals.EnergyProfile, carbonIntensity float64) float64 {
	if profile == nil {
		return 0.5
	}

	if profile.TokensPerSecond > 0 && profile.CurrentPower_W > 0 {
		// gCO2e per token = (power_kW × carbon_gCO2/kWh) / tps / 3600
		gCO2ePerToken := (profile.CurrentPower_W / 1000.0) * carbonIntensity / profile.TokensPerSecond / 3600.0

		// Inverse scoring: lower carbon = higher score
		// Reference scaling: 0.001 gCO2e/tok is excellent, 0.1 gCO2e/tok is poor
		score := 1.0 / (1.0 + gCO2ePerToken*1000.0)
		return score
	}

	// Fallback: use TDP ratio (lower TDP = less carbon)
	if profile.TDP_Watts > 0 {
		return 1.0 - (profile.TDP_Watts / 1000.0)
	}

	return 0.5
}

// ComputeTokenEconomicsForPod is a helper that returns a TokenEconomics struct
// for a given pod, useful for reporting and evaluation.
func (s *CarbonIntensityScorer) ComputeTokenEconomicsForPod(podName string) *signals.TokenEconomics {
	profile := s.store.GetProfile(podName)
	if profile == nil {
		return nil
	}
	ext := s.store.GetExternalSignals()
	econ := signals.ComputeTokenEconomics(*profile, ext)
	return &econ
}
