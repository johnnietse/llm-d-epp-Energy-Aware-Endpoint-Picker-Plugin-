package signals

import (
	"testing"
	"time"
)

func TestDefaultPrefillWeights(t *testing.T) {
	w := DefaultPrefillWeights()
	sum := w.Latency + w.Energy + w.Carbon
	if sum < 0.99 || sum > 1.01 {
		t.Errorf("DefaultPrefillWeights should sum to 1.0, got %f", sum)
	}
	if w.Latency <= w.Energy || w.Latency <= w.Carbon {
		t.Error("Prefill weights should prioritize latency")
	}
}

func TestDefaultDecodeWeights(t *testing.T) {
	w := DefaultDecodeWeights()
	sum := w.Latency + w.Energy + w.Carbon
	if sum < 0.99 || sum > 1.01 {
		t.Errorf("DefaultDecodeWeights should sum to 1.0, got %f", sum)
	}
	if w.Energy <= w.Latency || w.Energy <= w.Carbon {
		t.Error("Decode weights should prioritize energy efficiency")
	}
}

func TestWeightVector_Normalize(t *testing.T) {
	tests := []struct {
		name     string
		input    WeightVector
		wantSum  float64
	}{
		{
			name:    "already normalized",
			input:   WeightVector{Latency: 0.5, Energy: 0.3, Carbon: 0.2},
			wantSum: 1.0,
		},
		{
			name:    "unnormalized",
			input:   WeightVector{Latency: 2.0, Energy: 1.0, Carbon: 1.0},
			wantSum: 1.0,
		},
		{
			name:    "zero weights",
			input:   WeightVector{Latency: 0, Energy: 0, Carbon: 0},
			wantSum: 1.0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			norm := tt.input.Normalize()
			sum := norm.Latency + norm.Energy + norm.Carbon
			if sum < tt.wantSum-0.01 || sum > tt.wantSum+0.01 {
				t.Errorf("Normalize() sum = %f, want %f", sum, tt.wantSum)
			}
		})
	}
}

func TestComputeTokenEconomics(t *testing.T) {
	profile := EnergyProfile{
		PodName:         "gpu-pod-1",
		HardwareClass:   GPU_HIGH_PERF,
		TDP_Watts:       700,
		CurrentPower_W:  500,
		TokensPerSecond: 100,
		LastUpdated:     time.Now(),
	}

	ext := ExternalSignals{
		CarbonIntensity_gCO2_kWh: 390.0,  // US average
		ElectricityPrice_USD_kWh: 0.10,    // $0.10/kWh
		GridRegion:               "US-CAL-CISO",
		LastUpdated:              time.Now(),
	}

	econ := ComputeTokenEconomics(profile, ext)

	// Energy per token: 500W / 1000 / 100 tps / 3600 = 1.389e-6 kWh/token
	// Per 1M tokens: 1.389e-6 * 1e6 = 1.389 kWh
	if econ.EnergyPer1MTokens_kWh < 1.0 || econ.EnergyPer1MTokens_kWh > 2.0 {
		t.Errorf("EnergyPer1MTokens = %f kWh, want ~1.39", econ.EnergyPer1MTokens_kWh)
	}

	// Carbon: 1.389 * 390 = 541.7 gCO2e
	if econ.CarbonPer1MTokens_gCO2e < 400 || econ.CarbonPer1MTokens_gCO2e > 700 {
		t.Errorf("CarbonPer1MTokens = %f gCO2e, want ~542", econ.CarbonPer1MTokens_gCO2e)
	}

	// Cost: 1.389 * 0.10 = $0.139
	if econ.CostPer1MTokens_USD < 0.10 || econ.CostPer1MTokens_USD > 0.20 {
		t.Errorf("CostPer1MTokens = $%f, want ~$0.14", econ.CostPer1MTokens_USD)
	}
}

func TestComputeTokenEconomics_ZeroThroughput(t *testing.T) {
	profile := EnergyProfile{
		PodName:         "idle-pod",
		CurrentPower_W:  50,
		TokensPerSecond: 0, // idle
	}
	ext := ExternalSignals{CarbonIntensity_gCO2_kWh: 390}

	econ := ComputeTokenEconomics(profile, ext)
	if econ.EnergyPer1MTokens_kWh != 0 {
		t.Error("Zero throughput should produce zero energy metrics")
	}
}

func TestComputeTokenEconomics_LowPowerASIC(t *testing.T) {
	gpuProfile := EnergyProfile{
		PodName:         "gpu-decode",
		HardwareClass:   GPU_HIGH_PERF,
		CurrentPower_W:  500,
		TokensPerSecond: 800, // H100 decode speed
	}
	asicProfile := EnergyProfile{
		PodName:         "asic-decode",
		HardwareClass:   ASIC_LOW_POWER,
		CurrentPower_W:  60,
		TokensPerSecond: 400, // ASIC decode speed
	}
	ext := ExternalSignals{
		CarbonIntensity_gCO2_kWh: 390,
		ElectricityPrice_USD_kWh: 0.10,
	}

	gpuEcon := ComputeTokenEconomics(gpuProfile, ext)
	asicEcon := ComputeTokenEconomics(asicProfile, ext)

	// The ASIC should be MORE energy-efficient per token despite lower throughput
	// GPU: 500W / 800 tps = 0.625 W/token
	// ASIC: 60W / 400 tps = 0.15 W/token  (4.2x more efficient!)
	if asicEcon.EnergyPer1MTokens_kWh >= gpuEcon.EnergyPer1MTokens_kWh {
		t.Errorf("ASIC (%f kWh/1M) should be more energy-efficient than GPU (%f kWh/1M)",
			asicEcon.EnergyPer1MTokens_kWh, gpuEcon.EnergyPer1MTokens_kWh)
	}

	t.Logf("GPU energy:  %.4f kWh/1M tokens", gpuEcon.EnergyPer1MTokens_kWh)
	t.Logf("ASIC energy: %.4f kWh/1M tokens", asicEcon.EnergyPer1MTokens_kWh)
	t.Logf("ASIC is %.1fx more energy-efficient than GPU for decode",
		gpuEcon.EnergyPer1MTokens_kWh/asicEcon.EnergyPer1MTokens_kWh)
}
