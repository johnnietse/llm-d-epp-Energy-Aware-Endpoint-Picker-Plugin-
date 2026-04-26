package scorer

import (
	"testing"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

func TestCarbonIntensityScorer_ScorePods(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultCarbonIntensityScorerConfig()
	scorer := NewCarbonIntensityScorer("test-carbon-scorer", store, config)

	// Set grid carbon intensity
	store.UpdateExternalSignals(signals.ExternalSignals{
		CarbonIntensity_gCO2_kWh: 390.0,
	})

	// Add pods to store
	// H100 GPU (high power, high throughput)
	store.UpdateProfile(signals.EnergyProfile{
		PodName:         "gpu-1",
		CurrentPower_W:  500,
		TokensPerSecond: 800,
		TDP_Watts:       700,
	})
	// ASIC (low power, moderate throughput)
	store.UpdateProfile(signals.EnergyProfile{
		PodName:         "asic-1",
		CurrentPower_W:  60,
		TokensPerSecond: 400,
		TDP_Watts:       75,
	})
	
	pods := []PodInfo{
		{Name: "gpu-1"},
		{Name: "asic-1"},
	}

	scores := scorer.ScorePods(pods)

	// ASIC should have lower carbon footprint per token, so it should score HIGHER
	// GPU carbon/tok = (500/1000) * 390 / 800 / 3600 = 0.000067 gCO2/tok
	// ASIC carbon/tok = (60/1000) * 390 / 400 / 3600 = 0.000016 gCO2/tok
	// Lower carbon = higher score
	
	if scores["asic-1"] <= scores["gpu-1"] {
		t.Errorf("Expected ASIC (%f) to score higher than GPU (%f)", scores["asic-1"], scores["gpu-1"])
	}
}

func TestCarbonIntensityScorer_UnknownPodsFallbackTDP(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultCarbonIntensityScorerConfig()
	scorer := NewCarbonIntensityScorer("test", store, config)

	// Add pods, but lacking metrics, only TDP known
	store.UpdateProfile(signals.EnergyProfile{
		PodName:   "gpu-1",
		TDP_Watts: 700,
	})
	store.UpdateProfile(signals.EnergyProfile{
		PodName:   "asic-1",
		TDP_Watts: 75,
	})

	pods := []PodInfo{
		{Name: "gpu-1"},
		{Name: "asic-1"},
	}

	scores := scorer.ScorePods(pods)

	// Since we fallback to TDP ratio, lower TDP = better score
	if scores["asic-1"] <= scores["gpu-1"] {
		t.Errorf("Expected ASIC to score higher based on TDP, got ASIC: %f, GPU: %f", scores["asic-1"], scores["gpu-1"])
	}
}

func TestCarbonIntensityScorer_ComputeTokenEconomicsForPod(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	scorer := NewCarbonIntensityScorer("test", store, DefaultCarbonIntensityScorerConfig())

	store.UpdateExternalSignals(signals.ExternalSignals{
		CarbonIntensity_gCO2_kWh: 390.0,
		ElectricityPrice_USD_kWh: 0.10,
	})

	store.UpdateProfile(signals.EnergyProfile{
		PodName:         "asic-1",
		CurrentPower_W:  60,
		TokensPerSecond: 400,
	})

	econ := scorer.ComputeTokenEconomicsForPod("asic-1")
	if econ == nil {
		t.Fatal("Expected token economics, got nil")
	}

	// Double check calculations: 60W / 400 tps = 0.15 W/tok = 150mJ/tok
	// 0.15W/tok = 0.00015 kW/tok = 150 kW/1M tok. Wait:
	// kW/tok = (60/1000) / 400 / 3600 = 4.16e-8 kWh/tok 
	// per 1M tok = 0.0416 kWh
	
	if econ.EnergyPer1MTokens_kWh < 0.04 || econ.EnergyPer1MTokens_kWh > 0.05 {
		t.Errorf("Expected ~0.041 kWh/1M, got %f", econ.EnergyPer1MTokens_kWh)
	}
}
