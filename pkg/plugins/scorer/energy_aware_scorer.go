// Package scorer implements the EnergyAwareScorer plugin for the llm-d
// Endpoint Picker (EPP). This is the core research contribution of the thesis:
// "Energy-Aware Token-Level Routing for Heterogeneous LLM Inference in Kubernetes."
//
// The scorer exploits the asymmetric energy profiles of Prefill vs. Decode phases:
//   - Prefill (compute-bound): Favors high-TDP GPUs for minimum TTFT
//   - Decode (memory-bound):   Favors low-power accelerators for minimum energy-per-token
//
// It integrates into the EPP scheduling pipeline at the "Score" hook, alongside
// existing scorers like LoadAwareScorer and PrefixCacheScorer. Scores are normalized
// to [0, 1] and combined via a weighted sum with configurable phase-specific weights.
//
// Architecture:
//
//	                ┌─────────────────────────────┐
//	                │    Scheduling Cycle          │
//	                │                             │
//	Filter Stage ──▶│  PrefixCacheScorer (w=0.3)  │
//	                │  LoadAwareScorer   (w=0.2)  │
//	                │  EnergyAwareScorer (w=0.5)  │◀── EnergyStore
//	                │                             │
//	                └──────────┬──────────────────┘
//	                           ▼
//	                    MaxScorePicker
package scorer

import (
	"math"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// EnergyAwareScorerConfig holds the configuration parameters for the scorer.
// These are parsed from the EndpointPickerConfig YAML.
type EnergyAwareScorerConfig struct {
	// PrefillWeights are the multi-objective weights for the Prefill scheduling profile.
	PrefillWeights signals.WeightVector `yaml:"prefillWeights"`

	// DecodeWeights are the multi-objective weights for the Decode scheduling profile.
	DecodeWeights signals.WeightVector `yaml:"decodeWeights"`

	// FallbackCarbonIntensity is the default carbon intensity (gCO2/kWh) if the
	// external API is unavailable. US grid average: 390.
	FallbackCarbonIntensity float64 `yaml:"fallbackCarbonIntensity"`

	// LatencySLO_ms is the target latency SLO used for latency sub-score normalization.
	// Pods estimated to exceed this SLO get penalized scores.
	LatencySLO_ms float64 `yaml:"latencySloMs"`
}

// DefaultEnergyAwareScorerConfig returns the default configuration.
func DefaultEnergyAwareScorerConfig() EnergyAwareScorerConfig {
	return EnergyAwareScorerConfig{
		PrefillWeights:          signals.DefaultPrefillWeights(),
		DecodeWeights:           signals.DefaultDecodeWeights(),
		FallbackCarbonIntensity: 390.0,
		LatencySLO_ms:           500.0,
	}
}

// PodInfo represents the minimal pod information needed for scoring.
// This abstracts over the GIE types.Pod interface to enable testing
// without importing the full Kubernetes dependency chain.
type PodInfo struct {
	// Name is the pod's Kubernetes name.
	Name string

	// Labels are the pod's Kubernetes labels.
	Labels map[string]string

	// QueueDepth is the number of pending requests in this pod's queue.
	QueueDepth int
}

// EnergyAwareScorer scores inference pods based on energy efficiency,
// latency characteristics, and carbon intensity. It applies phase-specific
// weight vectors to produce composite scores in the range [0, 1].
type EnergyAwareScorer struct {
	name   string
	store  *signals.EnergyStore
	config EnergyAwareScorerConfig
}

// NewEnergyAwareScorer creates a new scorer instance.
func NewEnergyAwareScorer(name string, store *signals.EnergyStore, config EnergyAwareScorerConfig) *EnergyAwareScorer {
	if name == "" {
		name = "energy-aware-scorer"
	}
	// Normalize weight vectors to ensure they sum to 1.0
	config.PrefillWeights = config.PrefillWeights.Normalize()
	config.DecodeWeights = config.DecodeWeights.Normalize()

	return &EnergyAwareScorer{
		name:   name,
		store:  store,
		config: config,
	}
}

// Name returns the plugin name.
func (s *EnergyAwareScorer) Name() string {
	return s.name
}

// ScorePods scores a list of candidate pods for a given inference phase.
// Returns a map from pod name to normalized score [0, 1].
//
// Higher scores indicate better candidates for the current scheduling profile.
// The scoring is multi-objective:
//
//	score(pod) = w_latency × S_latency + w_energy × S_energy + w_carbon × S_carbon
func (s *EnergyAwareScorer) ScorePods(phase signals.InferencePhase, pods []PodInfo) map[string]float64 {
	if len(pods) == 0 {
		return nil
	}

	scores := make(map[string]float64, len(pods))
	weights := s.weightsForPhase(phase)
	ext := s.store.GetExternalSignals()

	// Collect raw sub-scores for normalization
	rawLatency := make([]float64, len(pods))
	rawEnergy := make([]float64, len(pods))
	rawCarbon := make([]float64, len(pods))

	for i, pod := range pods {
		profile := s.store.GetProfile(pod.Name)
		rawLatency[i] = s.rawLatencyScore(pod, profile, phase)
		rawEnergy[i] = s.rawEnergyScore(profile, phase)
		rawCarbon[i] = s.rawCarbonScore(profile, ext)
	}

	// Min-max normalize each dimension to [0, 1]
	normLatency := minMaxNormalize(rawLatency)
	normEnergy := minMaxNormalize(rawEnergy)
	normCarbon := minMaxNormalize(rawCarbon)

	for i, pod := range pods {
		composite := weights.Latency*normLatency[i] +
			weights.Energy*normEnergy[i] +
			weights.Carbon*normCarbon[i]
		scores[pod.Name] = composite
	}

	return scores
}

// weightsForPhase returns the appropriate weight vector for the given inference phase.
func (s *EnergyAwareScorer) weightsForPhase(phase signals.InferencePhase) signals.WeightVector {
	switch phase {
	case signals.PhasePrefill:
		return s.config.PrefillWeights
	case signals.PhaseDecode:
		return s.config.DecodeWeights
	default:
		// Unknown phase — use decode weights as a conservative default
		// (energy-efficiency is never wrong to optimize).
		return s.config.DecodeWeights
	}
}

// rawLatencyScore computes the raw latency sub-score for a pod.
// Higher is better — pods with lower estimated latency get higher scores.
//
// For Prefill: Strongly favors high-TDP GPUs (more FLOPS = lower TTFT).
// For Decode:  Favors any pod with low queue depth (less queueing = lower TPOT).
func (s *EnergyAwareScorer) rawLatencyScore(pod PodInfo, profile *signals.EnergyProfile, phase signals.InferencePhase) float64 {
	if profile == nil {
		return 0.5 // neutral score for unknown pods
	}

	var score float64

	switch phase {
	case signals.PhasePrefill:
		// Prefill latency is dominated by compute throughput.
		// Use TDP as a proxy for compute capability (higher TDP ≈ more FLOPS).
		// Normalized by H100 TDP (700W) as reference.
		score = profile.TDP_Watts / 700.0
		if score > 1.0 {
			score = 1.0
		}

		// Penalize for queue depth (more queued requests = higher wait time)
		queuePenalty := 1.0 - (float64(pod.QueueDepth) * 0.1)
		if queuePenalty < 0.1 {
			queuePenalty = 0.1
		}
		score *= queuePenalty

	case signals.PhaseDecode:
		// Decode latency is dominated by memory bandwidth and queue depth.
		// Use tokens-per-second if available, otherwise use moderate estimate.
		if profile.TokensPerSecond > 0 {
			// Normalize by H100 decode throughput (800 tok/s) as reference.
			score = profile.TokensPerSecond / 800.0
			if score > 1.0 {
				score = 1.0
			}
		} else {
			score = 0.5
		}

		// Stronger queue depth penalty for decode (longer requests amplify wait)
		queuePenalty := 1.0 - (float64(pod.QueueDepth) * 0.15)
		if queuePenalty < 0.05 {
			queuePenalty = 0.05
		}
		score *= queuePenalty
	}

	return score
}

// rawEnergyScore computes the raw energy efficiency sub-score for a pod.
// Higher is better — pods with lower energy-per-token get higher scores.
//
// THIS IS THE KEY INNOVATION: For decode phase, low-power accelerators
// are strongly preferred because decode is memory-bandwidth-bound and
// energy-per-token scales with power draw, not with throughput.
func (s *EnergyAwareScorer) rawEnergyScore(profile *signals.EnergyProfile, phase signals.InferencePhase) float64 {
	if profile == nil {
		return 0.5
	}

	// Primary signal: energy-per-token (lower is better)
	if profile.EnergyPerToken_mJ > 0 {
		// Inverse scoring: lower energy = higher score
		// Reference: 1 mJ/token is excellent, 10 mJ/token is poor
		score := 1.0 / (1.0 + profile.EnergyPerToken_mJ/5.0)
		return score
	}

	// Fallback: use power-to-throughput ratio as proxy
	if profile.TokensPerSecond > 0 && profile.CurrentPower_W > 0 {
		// Watts per token — lower is better
		wattsPerToken := profile.CurrentPower_W / profile.TokensPerSecond
		// Reference: H100 decode ≈ 0.625 W/tok, ASIC ≈ 0.15 W/tok
		score := 1.0 / (1.0 + wattsPerToken)
		return score
	}

	// Last resort: use hardware class as a heuristic
	switch phase {
	case signals.PhasePrefill:
		// For prefill, energy is less important — give moderate scores to all
		return s.hardwareClassEnergyHeuristic(profile.HardwareClass, false)
	case signals.PhaseDecode:
		// For decode, strongly favor low-power hardware
		return s.hardwareClassEnergyHeuristic(profile.HardwareClass, true)
	default:
		return 0.5
	}
}

// hardwareClassEnergyHeuristic returns a heuristic energy score based on hardware class
// when real-time metrics are unavailable.
func (s *EnergyAwareScorer) hardwareClassEnergyHeuristic(class signals.HardwareClass, decodeOptimized bool) float64 {
	if decodeOptimized {
		// For decode: low power is strongly preferred
		switch class {
		case signals.ASIC_LOW_POWER:
			return 0.95
		case signals.FPGA_LOW_POWER:
			return 0.90
		case signals.GPU_MED_PERF:
			return 0.60
		case signals.GPU_HIGH_PERF:
			return 0.30
		default:
			return 0.50
		}
	}
	// For prefill: energy is secondary, all get moderate scores
	switch class {
	case signals.ASIC_LOW_POWER:
		return 0.60
	case signals.FPGA_LOW_POWER:
		return 0.55
	case signals.GPU_MED_PERF:
		return 0.65
	case signals.GPU_HIGH_PERF:
		return 0.70
	default:
		return 0.50
	}
}

// rawCarbonScore computes the raw carbon intensity sub-score for a pod.
// Higher is better — pods contributing less gCO2e per token get higher scores.
func (s *EnergyAwareScorer) rawCarbonScore(profile *signals.EnergyProfile, ext signals.ExternalSignals) float64 {
	if profile == nil {
		return 0.5
	}

	carbonIntensity := ext.CarbonIntensity_gCO2_kWh
	if carbonIntensity <= 0 {
		carbonIntensity = s.config.FallbackCarbonIntensity
	}

	if profile.TokensPerSecond > 0 && profile.CurrentPower_W > 0 {
		// gCO2e per token = (power_kW × carbon_intensity) / tokens_per_sec / 3600
		gCO2ePerToken := (profile.CurrentPower_W / 1000.0) * carbonIntensity / profile.TokensPerSecond / 3600.0
		// Inverse scoring: lower carbon = higher score
		score := 1.0 / (1.0 + gCO2ePerToken*1000.0)
		return score
	}

	// Fallback: use TDP as proxy (lower TDP = lower carbon)
	tdpRatio := profile.TDP_Watts / 700.0
	return 1.0 - (tdpRatio * 0.5) // range: 0.5 to 1.0
}

// minMaxNormalize normalizes a slice of values to [0, 1] using min-max scaling.
// If all values are identical, returns 0.5 for all (neutral scores).
func minMaxNormalize(values []float64) []float64 {
	if len(values) == 0 {
		return nil
	}

	minVal := math.Inf(1)
	maxVal := math.Inf(-1)
	for _, v := range values {
		if v < minVal {
			minVal = v
		}
		if v > maxVal {
			maxVal = v
		}
	}

	spread := maxVal - minVal
	result := make([]float64, len(values))

	if spread == 0 {
		// All values identical — return neutral scores
		for i := range result {
			result[i] = 0.5
		}
		return result
	}

	for i, v := range values {
		result[i] = (v - minVal) / spread
	}
	return result
}
