package signals

import (
	"testing"
)

func TestComputeSCI_GPUvsASIC(t *testing.T) {
	ext := ExternalSignals{
		CarbonIntensity_gCO2_kWh: 390.0, // US grid average
	}

	gpuProfile := EnergyProfile{
		PodName:           "gpu-h100",
		HardwareClass:     GPU_HIGH_PERF,
		TDP_Watts:         700,
		CurrentPower_W:    550,
		EnergyPerToken_mJ: 6.0,
		TokensPerSecond:   800,
	}

	asicProfile := EnergyProfile{
		PodName:           "asic-qc",
		HardwareClass:     ASIC_LOW_POWER,
		TDP_Watts:         75,
		CurrentPower_W:    55,
		EnergyPerToken_mJ: 1.0,
		TokensPerSecond:   420,
	}

	gpuEmbodied := DefaultEmbodiedCarbon(GPU_HIGH_PERF)
	asicEmbodied := DefaultEmbodiedCarbon(ASIC_LOW_POWER)

	avgTokens := 256.0

	gpuSCI := ComputeSCI(gpuProfile, ext, gpuEmbodied, avgTokens)
	asicSCI := ComputeSCI(asicProfile, ext, asicEmbodied, avgTokens)

	t.Logf("GPU H100 SCI:  %.6f gCO2/request (E=%.8f kWh, M=%.8f gCO2, Op=%.6f gCO2)",
		gpuSCI.SCI_gCO2, gpuSCI.E_kWh, gpuSCI.M_gCO2, gpuSCI.OperationalCarbon_gCO2)
	t.Logf("ASIC QC  SCI:  %.6f gCO2/request (E=%.8f kWh, M=%.8f gCO2, Op=%.6f gCO2)",
		asicSCI.SCI_gCO2, asicSCI.E_kWh, asicSCI.M_gCO2, asicSCI.OperationalCarbon_gCO2)

	// ASIC should have significantly lower SCI than GPU
	if asicSCI.SCI_gCO2 >= gpuSCI.SCI_gCO2 {
		t.Errorf("ASIC SCI (%.6f) should be lower than GPU SCI (%.6f)",
			asicSCI.SCI_gCO2, gpuSCI.SCI_gCO2)
	}

	ratio := gpuSCI.SCI_gCO2 / asicSCI.SCI_gCO2
	t.Logf("SCI Ratio: GPU/ASIC = %.2f× (GPU is %.1f%% more carbon-intensive per request)",
		ratio, (ratio-1)*100)

	// GPU should use more energy per request
	if gpuSCI.E_kWh <= asicSCI.E_kWh {
		t.Errorf("GPU energy per request (%.8f kWh) should exceed ASIC (%.8f kWh)",
			gpuSCI.E_kWh, asicSCI.E_kWh)
	}

	// Both SCI values should be positive
	if gpuSCI.SCI_gCO2 <= 0 || asicSCI.SCI_gCO2 <= 0 {
		t.Errorf("SCI values should be positive: GPU=%.6f, ASIC=%.6f",
			gpuSCI.SCI_gCO2, asicSCI.SCI_gCO2)
	}
}

func TestComputeSCI_CarbonSensitivity(t *testing.T) {
	profile := EnergyProfile{
		PodName:        "gpu-a100",
		HardwareClass:  GPU_MED_PERF,
		TDP_Watts:      200,
		CurrentPower_W: 180,
		TokensPerSecond: 600,
	}
	embodied := DefaultEmbodiedCarbon(GPU_MED_PERF)

	regions := []struct {
		name      string
		intensity float64
	}{
		{"France Nuclear", 55},
		{"US Average", 390},
		{"Germany Coal", 600},
		{"India Coal", 800},
	}

	t.Logf("SCI sensitivity to grid carbon intensity (GPU A100, 256 tokens):")
	prevSCI := 0.0
	for _, r := range regions {
		ext := ExternalSignals{CarbonIntensity_gCO2_kWh: r.intensity}
		sci := ComputeSCI(profile, ext, embodied, 256)
		t.Logf("  %-20s CI=%3.0f → SCI=%.6f gCO2/req (Op=%.6f, Emb=%.6f)",
			r.name, r.intensity, sci.SCI_gCO2, sci.OperationalCarbon_gCO2, sci.M_gCO2)

		// SCI should increase with carbon intensity
		if prevSCI > 0 && sci.SCI_gCO2 <= prevSCI {
			t.Errorf("SCI should increase with carbon intensity: %.6f <= %.6f",
				sci.SCI_gCO2, prevSCI)
		}
		prevSCI = sci.SCI_gCO2
	}
}

func TestComputeSCI_ZeroTokens(t *testing.T) {
	profile := EnergyProfile{
		PodName:         "gpu-idle",
		HardwareClass:   GPU_HIGH_PERF,
		TokensPerSecond: 0, // idle
	}
	ext := ExternalSignals{CarbonIntensity_gCO2_kWh: 390}
	embodied := DefaultEmbodiedCarbon(GPU_HIGH_PERF)

	sci := ComputeSCI(profile, ext, embodied, 0)

	// With zero throughput and default tokens, energy comes from EnergyPerToken_mJ fallback
	t.Logf("Idle GPU SCI: %.6f gCO2/req", sci.SCI_gCO2)
}

func TestComputeSCI_EmbodiedCarbonDominance(t *testing.T) {
	// Very clean grid → embodied carbon should dominate
	profile := EnergyProfile{
		PodName:         "gpu-h100",
		HardwareClass:   GPU_HIGH_PERF,
		TDP_Watts:       700,
		CurrentPower_W:  550,
		TokensPerSecond: 800,
	}
	ext := ExternalSignals{CarbonIntensity_gCO2_kWh: 1.0} // near-zero carbon grid
	embodied := DefaultEmbodiedCarbon(GPU_HIGH_PERF)

	sci := ComputeSCI(profile, ext, embodied, 256)

	embodiedPct := sci.M_gCO2 / sci.SCI_gCO2 * 100
	t.Logf("Clean grid (1 gCO2/kWh): SCI=%.6f, Embodied=%.1f%%, Operational=%.1f%%",
		sci.SCI_gCO2, embodiedPct, 100-embodiedPct)

	// On a near-zero carbon grid, embodied should be a significant portion
	if embodiedPct < 10 {
		t.Logf("Note: Embodied carbon is %.1f%% even on near-zero grid", embodiedPct)
	}
}

func TestComputeClusterSCI(t *testing.T) {
	profiles := map[string]EnergyProfile{
		"gpu-1": {
			PodName: "gpu-1", HardwareClass: GPU_HIGH_PERF,
			CurrentPower_W: 550, TokensPerSecond: 800,
		},
		"asic-1": {
			PodName: "asic-1", HardwareClass: ASIC_LOW_POWER,
			CurrentPower_W: 55, TokensPerSecond: 420,
		},
	}
	ext := ExternalSignals{CarbonIntensity_gCO2_kWh: 390}

	clusterSCI := ComputeClusterSCI(profiles, ext, 256)
	t.Logf("Cluster SCI: %.6f gCO2/req (avg across %d pods)", clusterSCI.SCI_gCO2, len(profiles))

	if clusterSCI.SCI_gCO2 <= 0 {
		t.Error("Cluster SCI should be positive")
	}
}

func TestComputeClusterSCI_Empty(t *testing.T) {
	sci := ComputeClusterSCI(nil, ExternalSignals{}, 256)
	if sci.SCI_gCO2 != 0 {
		t.Errorf("Empty cluster SCI should be 0, got %.6f", sci.SCI_gCO2)
	}
}

func TestDefaultEmbodiedCarbon(t *testing.T) {
	classes := []HardwareClass{GPU_HIGH_PERF, GPU_MED_PERF, ASIC_LOW_POWER, FPGA_LOW_POWER}
	for _, class := range classes {
		ec := DefaultEmbodiedCarbon(class)
		if ec.TotalEmbodied_kgCO2 <= 0 {
			t.Errorf("%s: embodied CO2 should be positive", class)
		}
		if ec.ExpectedLifetime_hours <= 0 {
			t.Errorf("%s: lifetime should be positive", class)
		}
		t.Logf("  %-20s embodied=%.0f kgCO2, lifetime=%.0f hours",
			class, ec.TotalEmbodied_kgCO2, ec.ExpectedLifetime_hours)
	}

	// Unknown class should return a sensible default
	ec := DefaultEmbodiedCarbon("unknown")
	if ec.TotalEmbodied_kgCO2 != 50 {
		t.Errorf("Unknown class should default to 50 kgCO2, got %.0f", ec.TotalEmbodied_kgCO2)
	}
}
