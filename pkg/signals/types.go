// Package signals defines shared types for energy telemetry and external market signals
// used by the energy-aware Endpoint Picker Plugin (EPP) for llm-d.
//
// These types flow through the scheduling pipeline:
//
//	Scrapers → EnergyStore → Scorers/Filters
//
// The EnergyProfile is per-pod, while ExternalSignals are cluster/region-wide.
package signals

import "time"

// HardwareClass categorizes accelerator energy profiles for routing decisions.
// The scheduler uses this to apply phase-aware scoring:
//   - Prefill (compute-bound) → favors GPU_HIGH_PERF
//   - Decode (memory-bound)   → favors ASIC_LOW_POWER or GPU_MED_PERF
type HardwareClass string

const (
	// GPU_HIGH_PERF represents datacenter GPUs at full TDP (e.g., H100 @ 700W, A100 @ 400W).
	// Optimal for prefill due to high FLOPS and memory bandwidth.
	GPU_HIGH_PERF HardwareClass = "GPU_HIGH_PERF"

	// GPU_MED_PERF represents power-capped GPUs or mid-range accelerators (e.g., A100 @ 200W, L4 @ 72W).
	// Balanced trade-off between performance and energy efficiency.
	GPU_MED_PERF HardwareClass = "GPU_MED_PERF"

	// ASIC_LOW_POWER represents purpose-built AI accelerators with low TDP
	// (e.g., Qualcomm Cloud AI 100 @ 75W, Intel Gaudi2).
	// Optimal for decode phase where energy-per-token dominates TCO.
	ASIC_LOW_POWER HardwareClass = "ASIC_LOW_POWER"

	// FPGA_LOW_POWER represents FPGA-based accelerators with very low power draw.
	// Experimental — for future extensibility.
	FPGA_LOW_POWER HardwareClass = "FPGA_LOW_POWER"
)

// InferencePhase represents the current phase of LLM inference.
// The llm-d scheduler runs separate scheduling cycles for each phase,
// enabling phase-specific weight vectors in the EnergyAwareScorer.
type InferencePhase string

const (
	// PhasePrefill is the compute-bound prompt processing phase.
	// Characterized by high GPU utilization, high power draw, short duration.
	PhasePrefill InferencePhase = "prefill"

	// PhaseDecode is the memory-bandwidth-bound token generation phase.
	// Characterized by lower utilization per token, sustained power draw, long duration.
	PhaseDecode InferencePhase = "decode"
)

// EnergyProfile holds real-time energy telemetry for a single inference pod.
// Updated periodically by the energy scraper and consumed by the EnergyAwareScorer.
type EnergyProfile struct {
	// PodName is the Kubernetes pod name, used as the key in the EnergyStore.
	PodName string `json:"podName"`

	// HardwareClass categorizes the accelerator type for this pod.
	// Sourced from the pod label: llm-d.ai/hardware-class
	HardwareClass HardwareClass `json:"hardwareClass"`

	// TDP_Watts is the Thermal Design Power (maximum power draw) of the accelerator.
	// Sourced from the pod label: llm-d.ai/tdp-watts
	TDP_Watts float64 `json:"tdpWatts"`

	// CurrentPower_W is the real-time power draw in Watts.
	// Sourced from DCGM (GPU) or RAPL (CPU/ASIC) metrics scraping.
	CurrentPower_W float64 `json:"currentPowerW"`

	// EnergyPerToken_mJ is the exponentially weighted moving average (EWMA)
	// of energy consumed per output token, in millijoules.
	// Computed as: (power_watts × duration_per_token_s) × 1000
	EnergyPerToken_mJ float64 `json:"energyPerTokenMJ"`

	// Utilization is the GPU/accelerator utilization ratio (0.0 to 1.0).
	// Used by the EnergyBudgetFilter to exclude overloaded pods.
	Utilization float64 `json:"utilization"`

	// TokensPerSecond is the current output token throughput.
	// Used to compute energy-per-token and for latency estimation.
	TokensPerSecond float64 `json:"tokensPerSecond"`

	// ActiveRequests is the number of concurrent requests being served.
	ActiveRequests int `json:"activeRequests"`

	// LastUpdated is the timestamp of the last metrics scrape for this pod.
	LastUpdated time.Time `json:"lastUpdated"`
}

// ExternalSignals holds cluster/region-level external signals that affect
// energy cost and carbon footprint computations. Updated by the carbon and
// electricity price scrapers.
type ExternalSignals struct {
	// CarbonIntensity_gCO2_kWh is the grid carbon intensity in grams CO2 per kWh.
	// Sourced from CO2signal, ElectricityMaps, or WattTime APIs.
	// US average: ~390 gCO2/kWh. France (nuclear): ~55 gCO2/kWh.
	CarbonIntensity_gCO2_kWh float64 `json:"carbonIntensityGCO2kWh"`

	// ElectricityPrice_USD_kWh is the real-time electricity price in USD per kWh.
	// Used for TCO computation in the TokenEconomics struct.
	ElectricityPrice_USD_kWh float64 `json:"electricityPriceUSDkWh"`

	// GridRegion is the identifier for the electrical grid region (e.g., "US-CAL-CISO").
	GridRegion string `json:"gridRegion"`

	// LastUpdated is the timestamp of the last API poll.
	LastUpdated time.Time `json:"lastUpdated"`
}

// TokenEconomics computes per-1M-token cost metrics for a given pod's profile
// combined with external signals. This is the primary KPI structure for evaluation.
type TokenEconomics struct {
	// EnergyPer1MTokens_kWh is energy consumed to generate 1 million output tokens.
	EnergyPer1MTokens_kWh float64 `json:"energyPer1MTokensKWh"`

	// CarbonPer1MTokens_gCO2e is grams of CO2 equivalent per 1 million output tokens.
	// Computed as: EnergyPer1MTokens_kWh × CarbonIntensity_gCO2_kWh
	CarbonPer1MTokens_gCO2e float64 `json:"carbonPer1MTokensGCO2e"`

	// CostPer1MTokens_USD is the electricity cost to generate 1 million output tokens.
	// Computed as: EnergyPer1MTokens_kWh × ElectricityPrice_USD_kWh
	CostPer1MTokens_USD float64 `json:"costPer1MTokensUSD"`
}

// WeightVector holds the multi-objective optimization weights for the EnergyAwareScorer.
// Different weight vectors are used for Prefill vs. Decode scheduling profiles.
type WeightVector struct {
	// Latency weight — higher for prefill (time-to-first-token matters).
	Latency float64 `json:"latency" yaml:"latency"`

	// Energy weight — higher for decode (sustained energy draw dominates TCO).
	Energy float64 `json:"energy" yaml:"energy"`

	// Carbon weight — scales with decode duration (long decode = more carbon impact).
	Carbon float64 `json:"carbon" yaml:"carbon"`
}

// DefaultPrefillWeights returns the default weight vector for the Prefill scheduling profile.
// Latency-dominant: TTFT is an SLO metric, so we prioritize raw compute speed.
func DefaultPrefillWeights() WeightVector {
	return WeightVector{
		Latency: 0.6,
		Energy:  0.2,
		Carbon:  0.2,
	}
}

// DefaultDecodeWeights returns the default weight vector for the Decode scheduling profile.
// Energy-dominant: Decode is sustained and memory-bound; energy-per-token drives TCO.
func DefaultDecodeWeights() WeightVector {
	return WeightVector{
		Latency: 0.2,
		Energy:  0.5,
		Carbon:  0.3,
	}
}

// Normalize ensures the weight vector sums to 1.0.
// If the sum is zero, returns equal weights.
func (w WeightVector) Normalize() WeightVector {
	sum := w.Latency + w.Energy + w.Carbon
	if sum == 0 {
		return WeightVector{Latency: 1.0 / 3, Energy: 1.0 / 3, Carbon: 1.0 / 3}
	}
	return WeightVector{
		Latency: w.Latency / sum,
		Energy:  w.Energy / sum,
		Carbon:  w.Carbon / sum,
	}
}

// ComputeTokenEconomics derives per-1M-token metrics from an EnergyProfile and ExternalSignals.
func ComputeTokenEconomics(profile EnergyProfile, ext ExternalSignals) TokenEconomics {
	if profile.TokensPerSecond <= 0 {
		return TokenEconomics{}
	}

	// Energy per token in kWh: (power_W / 1000) / tokens_per_sec / 3600
	energyPerToken_kWh := (profile.CurrentPower_W / 1000.0) / profile.TokensPerSecond / 3600.0

	// Scale to 1M tokens
	energyPer1M := energyPerToken_kWh * 1_000_000

	return TokenEconomics{
		EnergyPer1MTokens_kWh:  energyPer1M,
		CarbonPer1MTokens_gCO2e: energyPer1M * ext.CarbonIntensity_gCO2_kWh,
		CostPer1MTokens_USD:    energyPer1M * ext.ElectricityPrice_USD_kWh,
	}
}
