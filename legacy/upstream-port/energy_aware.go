/*
Copyright 2025 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// Package energyaware implements an energy-aware scoring plugin for the llm-d
// Router Endpoint Picker. It scores endpoints based on GPU power consumption,
// energy-per-token efficiency, and carbon intensity.
//
// The scorer exploits the asymmetric energy profiles of Prefill vs. Decode:
//   - Prefill (compute-bound): Favors high-TDP GPUs for minimum TTFT
//   - Decode (memory-bound):   Favors low-power accelerators for minimum EPT
//
// Energy data is read from pod labels set by an external DCGM exporter sidecar:
//   - llm-d.ai/gpu-tdp-watts:      GPU thermal design power
//   - llm-d.ai/gpu-power-watts:     Current measured power draw
//   - llm-d.ai/tokens-per-second:   Measured decode throughput
//   - llm-d.ai/energy-per-token-mj: Measured energy per token (mJ)
//   - llm-d.ai/hardware-class:      Hardware tier (gpu-high, gpu-med, asic-low, fpga-low)
package energyaware

import (
	"context"
	"encoding/json"
	"fmt"
	"math"
	"strconv"

	"sigs.k8s.io/controller-runtime/pkg/log"

	logutil "github.com/llm-d/llm-d-router/pkg/common/observability/logging"
	"github.com/llm-d/llm-d-router/pkg/epp/framework/interface/plugin"
	"github.com/llm-d/llm-d-router/pkg/epp/framework/interface/scheduling"
)

const (
	// EnergyAwareType is the type identifier for this scorer plugin.
	EnergyAwareType = "energy-aware-scorer"

	// Label keys for energy telemetry (set by DCGM exporter sidecar or operator)
	LabelTDPWatts        = "llm-d.ai/gpu-tdp-watts"
	LabelCurrentPowerW   = "llm-d.ai/gpu-power-watts"
	LabelTokensPerSecond = "llm-d.ai/tokens-per-second"
	LabelEnergyPerToken  = "llm-d.ai/energy-per-token-mj"
	LabelHardwareClass   = "llm-d.ai/hardware-class"

	// Reference values for normalization
	refTDP_H100    = 700.0 // H100 SXM TDP in watts
	refTokPerSec   = 800.0 // H100 decode throughput reference
	refEPT_good_mJ = 1.0   // Excellent energy-per-token
	refEPT_poor_mJ = 10.0  // Poor energy-per-token

	// Default parameter values
	defaultCarbonIntensity = 390.0 // US grid average gCO2/kWh
	defaultLatencySLOms    = 500.0
	defaultPrefillWtLat    = 0.7
	defaultPrefillWtEnergy = 0.2
	defaultPrefillWtCarbon = 0.1
	defaultDecodeWtLat     = 0.15
	defaultDecodeWtEnergy  = 0.65
	defaultDecodeWtCarbon  = 0.20
)

// parameters holds the configurable weights and thresholds for the scorer.
type parameters struct {
	// PrefillLatencyWeight is the latency weight for the prefill phase.
	PrefillLatencyWeight float64 `json:"prefillLatencyWeight"`
	// PrefillEnergyWeight is the energy weight for the prefill phase.
	PrefillEnergyWeight float64 `json:"prefillEnergyWeight"`
	// PrefillCarbonWeight is the carbon weight for the prefill phase.
	PrefillCarbonWeight float64 `json:"prefillCarbonWeight"`
	// DecodeLatencyWeight is the latency weight for the decode phase.
	DecodeLatencyWeight float64 `json:"decodeLatencyWeight"`
	// DecodeEnergyWeight is the energy weight for the decode phase.
	DecodeEnergyWeight float64 `json:"decodeEnergyWeight"`
	// DecodeCarbonWeight is the carbon weight for the decode phase.
	DecodeCarbonWeight float64 `json:"decodeCarbonWeight"`
	// FallbackCarbonIntensity is the default carbon intensity (gCO2/kWh).
	FallbackCarbonIntensity float64 `json:"fallbackCarbonIntensity"`
}

// compile-time type assertion
var _ scheduling.Scorer = &EnergyAware{}

// Factory defines the factory function for the EnergyAware scorer.
// It is registered with the plugin registry under the EnergyAwareType key.
func Factory(name string, rawParameters *json.Decoder, handle plugin.Handle) (plugin.Plugin, error) {
	params := parameters{
		PrefillLatencyWeight:    defaultPrefillWtLat,
		PrefillEnergyWeight:     defaultPrefillWtEnergy,
		PrefillCarbonWeight:     defaultPrefillWtCarbon,
		DecodeLatencyWeight:     defaultDecodeWtLat,
		DecodeEnergyWeight:      defaultDecodeWtEnergy,
		DecodeCarbonWeight:      defaultDecodeWtCarbon,
		FallbackCarbonIntensity: defaultCarbonIntensity,
	}
	if rawParameters != nil {
		if err := rawParameters.Decode(&params); err != nil {
			return nil, fmt.Errorf("failed to parse the parameters of the '%s' scorer - %w", EnergyAwareType, err)
		}
	}

	return NewEnergyAware(handle.Context(), params).WithName(name), nil
}

// NewEnergyAware creates a new energy-aware scorer with the given parameters.
func NewEnergyAware(ctx context.Context, params parameters) *EnergyAware {
	// Normalize weight vectors
	prefillSum := params.PrefillLatencyWeight + params.PrefillEnergyWeight + params.PrefillCarbonWeight
	decodeSum := params.DecodeLatencyWeight + params.DecodeEnergyWeight + params.DecodeCarbonWeight

	if prefillSum > 0 {
		params.PrefillLatencyWeight /= prefillSum
		params.PrefillEnergyWeight /= prefillSum
		params.PrefillCarbonWeight /= prefillSum
	}
	if decodeSum > 0 {
		params.DecodeLatencyWeight /= decodeSum
		params.DecodeEnergyWeight /= decodeSum
		params.DecodeCarbonWeight /= decodeSum
	}

	log.FromContext(ctx).V(logutil.DEFAULT).Info(
		"Created energy-aware scorer",
		"prefillWeights", fmt.Sprintf("lat=%.2f energy=%.2f carbon=%.2f",
			params.PrefillLatencyWeight, params.PrefillEnergyWeight, params.PrefillCarbonWeight),
		"decodeWeights", fmt.Sprintf("lat=%.2f energy=%.2f carbon=%.2f",
			params.DecodeLatencyWeight, params.DecodeEnergyWeight, params.DecodeCarbonWeight),
	)

	return &EnergyAware{
		typedName: plugin.TypedName{Type: EnergyAwareType},
		params:    params,
	}
}

// EnergyAware scores inference endpoints based on energy efficiency,
// latency characteristics, and carbon intensity using phase-specific
// weight vectors.
type EnergyAware struct {
	typedName plugin.TypedName
	params    parameters
}

// TypedName returns the typed name of the plugin.
func (s *EnergyAware) TypedName() plugin.TypedName {
	return s.typedName
}

// WithName sets the instance name of the plugin.
func (s *EnergyAware) WithName(name string) *EnergyAware {
	s.typedName.Name = name
	return s
}

// Category returns Distribution because the scorer prefers to spread
// decode-heavy workloads to energy-efficient endpoints.
func (s *EnergyAware) Category() scheduling.ScorerCategory {
	return scheduling.Distribution
}

// Score scores the given endpoints with a value in [0, 1].
//
// The scoring is multi-objective:
//
//	score(ep) = w_latency × S_latency + w_energy × S_energy + w_carbon × S_carbon
//
// Weight vectors are phase-specific (prefill vs. decode). Since the upstream
// scheduling framework handles phase routing via SchedulerProfiles, this scorer
// uses the endpoint's WaitingQueueSize as a heuristic to infer the dominant
// phase. In a P/D disaggregated setup, prefill and decode endpoints run on
// separate pods, so the scorer's asymmetric weights naturally apply via
// the profile-handler's profile selection.
func (s *EnergyAware) Score(_ context.Context, request *scheduling.InferenceRequest, endpoints []scheduling.Endpoint) map[scheduling.Endpoint]float64 {
	if len(endpoints) == 0 {
		return nil
	}

	scored := make(map[scheduling.Endpoint]float64, len(endpoints))

	// Collect raw sub-scores for min-max normalization
	rawLat := make([]float64, len(endpoints))
	rawEnergy := make([]float64, len(endpoints))
	rawCarbon := make([]float64, len(endpoints))

	for i, ep := range endpoints {
		labels := ep.GetMetadata().Labels
		metrics := ep.GetMetrics()

		rawLat[i] = s.computeLatencyScore(labels, metrics)
		rawEnergy[i] = s.computeEnergyScore(labels)
		rawCarbon[i] = s.computeCarbonScore(labels)
	}

	// Normalize each dimension to [0, 1]
	normLat := minMaxNormalize(rawLat)
	normEnergy := minMaxNormalize(rawEnergy)
	normCarbon := minMaxNormalize(rawCarbon)

	// Determine phase weights. In a disaggregated setup, the SchedulerProfile
	// already separates prefill vs decode endpoints. We use a simple heuristic:
	// if the request body is large (lots of input tokens), use prefill weights;
	// otherwise use decode weights as the conservative default.
	wLat, wEnergy, wCarbon := s.getWeights(request)

	for i, ep := range endpoints {
		composite := wLat*normLat[i] + wEnergy*normEnergy[i] + wCarbon*normCarbon[i]
		scored[ep] = composite
	}

	return scored
}

// getWeights returns the appropriate weight vector based on request characteristics.
func (s *EnergyAware) getWeights(request *scheduling.InferenceRequest) (wLat, wEnergy, wCarbon float64) {
	// Heuristic: large request body → prefill-dominant, small → decode-dominant
	// In a fully disaggregated P/D setup, the profile handler routes to the
	// correct pool, so both weight sets produce correct behavior.
	if request != nil && request.RequestSizeBytes > 4096 {
		return s.params.PrefillLatencyWeight, s.params.PrefillEnergyWeight, s.params.PrefillCarbonWeight
	}
	return s.params.DecodeLatencyWeight, s.params.DecodeEnergyWeight, s.params.DecodeCarbonWeight
}

// computeLatencyScore computes a raw latency sub-score for an endpoint.
// Higher is better — endpoints with lower estimated latency get higher scores.
func (s *EnergyAware) computeLatencyScore(labels map[string]string, metrics *scheduling.Metrics) float64 {
	// Use TDP as a proxy for compute capability (higher TDP ≈ more FLOPS)
	tdp := labelFloat(labels, LabelTDPWatts)
	tokPerSec := labelFloat(labels, LabelTokensPerSecond)

	var score float64
	if tokPerSec > 0 {
		score = tokPerSec / refTokPerSec
	} else if tdp > 0 {
		score = tdp / refTDP_H100
	} else {
		score = 0.5 // neutral for unknown endpoints
	}

	if score > 1.0 {
		score = 1.0
	}

	// Penalize for queue depth
	if metrics != nil {
		queuePenalty := 1.0 - (float64(metrics.WaitingQueueSize) * 0.1)
		if queuePenalty < 0.1 {
			queuePenalty = 0.1
		}
		score *= queuePenalty
	}

	return score
}

// computeEnergyScore computes a raw energy efficiency sub-score.
// Higher is better — endpoints with lower energy-per-token get higher scores.
//
// THIS IS THE KEY INNOVATION: low-power accelerators score highest for decode
// because decode is memory-bandwidth-bound and energy-per-token scales with
// power draw, not compute throughput.
func (s *EnergyAware) computeEnergyScore(labels map[string]string) float64 {
	// Improvement A: KV-Cache Energy Discounting (Synergy with Prefix Caching)
	// If a pod has a high prefix cache match for this prompt, the GPU avoids
	// heavy matrix multiplications during the prefill phase, significantly
	// discounting the overall energy cost of the request.
	cacheHitRatio := labelFloat(labels, "llm-d.ai/kv-cache-hit-ratio")
	energyDiscount := 1.0
	if cacheHitRatio > 0 {
		// e.g., a 100% cache hit rate reduces the compute energy cost by up to 80%
		energyDiscount = 1.0 - (cacheHitRatio * 0.8)
	}

	// Primary signal: energy-per-token (lower is better)
	ept := labelFloat(labels, LabelEnergyPerToken)
	if ept > 0 {
		discountedEpt := ept * energyDiscount
		return 1.0 / (1.0 + discountedEpt/5.0)
	}

	// Fallback: use power / throughput ratio
	power := labelFloat(labels, LabelCurrentPowerW)
	tokPerSec := labelFloat(labels, LabelTokensPerSecond)
	if tokPerSec > 0 && power > 0 {
		wattsPerToken := power / tokPerSec
		discountedWattsPerToken := wattsPerToken * energyDiscount
		return 1.0 / (1.0 + discountedWattsPerToken)
	}

	// Last resort: hardware class heuristic
	hwClass := labels[LabelHardwareClass]
	return hardwareClassScore(hwClass)
}

// computeCarbonScore computes a raw carbon intensity sub-score.
// Higher is better — endpoints contributing less gCO2e per token get higher scores.
func (s *EnergyAware) computeCarbonScore(labels map[string]string) float64 {
	carbonIntensity := s.params.FallbackCarbonIntensity
	if carbonIntensity <= 0 {
		carbonIntensity = defaultCarbonIntensity
	}

	power := labelFloat(labels, LabelCurrentPowerW)
	tokPerSec := labelFloat(labels, LabelTokensPerSecond)

	if tokPerSec > 0 && power > 0 {
		gCO2ePerToken := (power / 1000.0) * carbonIntensity / tokPerSec / 3600.0
		return 1.0 / (1.0 + gCO2ePerToken*1000.0)
	}

	// Fallback: lower TDP = lower carbon
	tdp := labelFloat(labels, LabelTDPWatts)
	if tdp > 0 {
		tdpRatio := tdp / refTDP_H100
		return 1.0 - (tdpRatio * 0.5)
	}

	return 0.5
}

// hardwareClassScore returns a heuristic energy score based on hardware class
// when real-time metrics are unavailable.
func hardwareClassScore(class string) float64 {
	switch class {
	case "asic-low":
		return 0.95
	case "fpga-low":
		return 0.90
	case "gpu-med":
		return 0.60
	case "gpu-high":
		return 0.30
	default:
		return 0.50
	}
}

// labelFloat reads a float64 from a pod label, returning 0 if absent or invalid.
func labelFloat(labels map[string]string, key string) float64 {
	v, ok := labels[key]
	if !ok || v == "" {
		return 0
	}
	f, err := strconv.ParseFloat(v, 64)
	if err != nil {
		return 0
	}
	return f
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
