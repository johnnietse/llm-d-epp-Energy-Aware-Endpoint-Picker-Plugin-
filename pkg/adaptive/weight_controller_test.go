package adaptive

import (
	"math"
	"testing"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

func TestAdaptiveController_NormalMode(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultAdaptiveConfig()

	var lastPrefill, lastDecode signals.WeightVector
	callback := func(p, d signals.WeightVector) {
		lastPrefill = p
		lastDecode = d
	}

	ctrl := NewAdaptiveController(store, config, callback)

	// No external signals, no pods → should be normal mode
	ctrl.evaluate()

	if ctrl.CurrentMode() != ModeNormal {
		t.Errorf("Expected normal mode, got %s", ctrl.CurrentMode())
	}

	// Normal mode weights should equal base weights
	if !weightsApproxEqual(lastPrefill, config.BaseWeightsPrefill) {
		t.Errorf("Prefill weights should be base weights in normal mode")
	}
	if !weightsApproxEqual(lastDecode, config.BaseWeightsDecode) {
		t.Errorf("Decode weights should be base weights in normal mode")
	}

	t.Logf("Normal mode: Prefill L=%.2f E=%.2f C=%.2f",
		lastPrefill.Latency, lastPrefill.Energy, lastPrefill.Carbon)
}

func TestAdaptiveController_CarbonHighMode(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultAdaptiveConfig()
	config.CarbonHighThreshold = 500 // trigger at 500 gCO2/kWh

	var lastPrefill, lastDecode signals.WeightVector
	callback := func(p, d signals.WeightVector) {
		lastPrefill = p
		lastDecode = d
	}

	ctrl := NewAdaptiveController(store, config, callback)

	// Simulate high carbon grid (e.g., coal-heavy region)
	store.UpdateExternalSignals(signals.ExternalSignals{
		CarbonIntensity_gCO2_kWh: 650, // Above 500 threshold
		GridRegion:               "DE-COAL",
	})

	ctrl.evaluate()

	if ctrl.CurrentMode() != ModeCarbonHigh {
		t.Errorf("Expected carbon_high mode, got %s", ctrl.CurrentMode())
	}

	// Carbon weight should be higher than normal
	normalCarbon := config.BaseWeightsDecode.Carbon
	if lastDecode.Carbon <= normalCarbon {
		t.Errorf("Decode carbon weight %.3f should exceed normal %.3f in carbon_high mode",
			lastDecode.Carbon, normalCarbon)
	}

	// Prefill latency should be reduced to push towards efficiency
	if lastPrefill.Latency >= config.BaseWeightsPrefill.Latency {
		t.Errorf("Prefill latency weight %.3f should be reduced in carbon_high mode", lastPrefill.Latency)
	}

	t.Logf("Carbon high mode: Decode L=%.2f E=%.2f C=%.2f (carbon increased)",
		lastDecode.Latency, lastDecode.Energy, lastDecode.Carbon)
}

func TestAdaptiveController_LoadShedMode(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultAdaptiveConfig()
	config.MaxClusterPower_W = 2000
	config.PowerBudgetThreshold = 0.85

	var lastPrefill, lastDecode signals.WeightVector
	callback := func(p, d signals.WeightVector) {
		lastPrefill = p
		lastDecode = d
	}

	ctrl := NewAdaptiveController(store, config, callback)

	// Simulate overloaded cluster (1800W = 90% of 2000W budget)
	store.UpdateProfile(signals.EnergyProfile{PodName: "gpu-1", CurrentPower_W: 600})
	store.UpdateProfile(signals.EnergyProfile{PodName: "gpu-2", CurrentPower_W: 600})
	store.UpdateProfile(signals.EnergyProfile{PodName: "gpu-3", CurrentPower_W: 600})

	ctrl.evaluate()

	if ctrl.CurrentMode() != ModeLoadShed {
		t.Errorf("Expected load_shed mode, got %s", ctrl.CurrentMode())
	}

	// Energy weight should be very high, latency weight very low
	if lastDecode.Energy < 0.5 {
		t.Errorf("Decode energy weight %.3f should be >0.5 in load_shed mode", lastDecode.Energy)
	}
	if lastPrefill.Latency > 0.3 {
		t.Errorf("Prefill latency weight %.3f should be <0.3 in load_shed mode", lastPrefill.Latency)
	}

	t.Logf("Load shed mode: Prefill L=%.2f E=%.2f C=%.2f",
		lastPrefill.Latency, lastPrefill.Energy, lastPrefill.Carbon)
}

func TestAdaptiveController_GreenMode(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultAdaptiveConfig()
	config.CarbonLowThreshold = 100

	var lastPrefill, lastDecode signals.WeightVector
	callback := func(p, d signals.WeightVector) {
		lastPrefill = p
		lastDecode = d
	}

	ctrl := NewAdaptiveController(store, config, callback)

	// Simulate clean grid (France nuclear at 55 gCO2/kWh)
	store.UpdateExternalSignals(signals.ExternalSignals{
		CarbonIntensity_gCO2_kWh: 55,
		GridRegion:               "FR",
	})

	ctrl.evaluate()

	if ctrl.CurrentMode() != ModeGreen {
		t.Errorf("Expected green mode, got %s", ctrl.CurrentMode())
	}

	// In green mode, latency weight should be higher than normal
	normalLatency := config.BaseWeightsDecode.Latency
	if lastDecode.Latency <= normalLatency {
		t.Errorf("Decode latency weight %.3f should exceed normal %.3f in green mode",
			lastDecode.Latency, normalLatency)
	}

	// Prefill latency should also be boosted
	if lastPrefill.Latency <= config.BaseWeightsPrefill.Latency {
		t.Errorf("Prefill latency weight %.3f should be boosted in green mode", lastPrefill.Latency)
	}

	t.Logf("Green mode: Decode L=%.2f E=%.2f C=%.2f (latency increased)",
		lastDecode.Latency, lastDecode.Energy, lastDecode.Carbon)
}

func TestAdaptiveController_ModeTransitions(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultAdaptiveConfig()
	config.CarbonHighThreshold = 500
	config.CarbonLowThreshold = 100

	ctrl := NewAdaptiveController(store, config, func(p, d signals.WeightVector) {})

	// Start in normal
	ctrl.evaluate()
	if ctrl.CurrentMode() != ModeNormal {
		t.Fatal("Should start in normal mode")
	}

	// Transition to carbon_high
	store.UpdateExternalSignals(signals.ExternalSignals{CarbonIntensity_gCO2_kWh: 700})
	ctrl.evaluate()
	if ctrl.CurrentMode() != ModeCarbonHigh {
		t.Fatal("Should be in carbon_high mode")
	}

	// Transition back to normal
	store.UpdateExternalSignals(signals.ExternalSignals{CarbonIntensity_gCO2_kWh: 300})
	ctrl.evaluate()
	if ctrl.CurrentMode() != ModeNormal {
		t.Fatal("Should be back in normal mode")
	}

	// Transition to green
	store.UpdateExternalSignals(signals.ExternalSignals{CarbonIntensity_gCO2_kWh: 50})
	ctrl.evaluate()
	if ctrl.CurrentMode() != ModeGreen {
		t.Fatal("Should be in green mode")
	}

	// Check history
	history := ctrl.History()
	if len(history) < 4 {
		t.Errorf("Expected at least 4 history entries, got %d", len(history))
	}

	t.Logf("Mode transitions: normal -> carbon_high -> normal -> green (%d history entries)",
		len(history))
}

func TestAdaptiveController_WeightsAlwaysNormalized(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultAdaptiveConfig()

	var lastPrefill, lastDecode signals.WeightVector
	callback := func(p, d signals.WeightVector) {
		lastPrefill = p
		lastDecode = d
	}

	ctrl := NewAdaptiveController(store, config, callback)

	// Test all modes
	modes := []struct {
		carbon float64
		power  float64
	}{
		{300, 0},    // normal
		{700, 0},    // carbon_high
		{300, 1900}, // load_shed (>85% of 2000W)
		{50, 0},     // green
	}

	for _, m := range modes {
		store.UpdateExternalSignals(signals.ExternalSignals{CarbonIntensity_gCO2_kWh: m.carbon})
		// Set power
		store.UpdateProfile(signals.EnergyProfile{PodName: "pod-1", CurrentPower_W: m.power})
		ctrl.evaluate()

		sumP := lastPrefill.Latency + lastPrefill.Energy + lastPrefill.Carbon
		sumD := lastDecode.Latency + lastDecode.Energy + lastDecode.Carbon

		if math.Abs(sumP-1.0) > 0.01 {
			t.Errorf("Prefill weights sum = %f, want 1.0 (mode=%s)", sumP, ctrl.CurrentMode())
		}
		if math.Abs(sumD-1.0) > 0.01 {
			t.Errorf("Decode weights sum = %f, want 1.0 (mode=%s)", sumD, ctrl.CurrentMode())
		}
	}
}

func weightsApproxEqual(a, b signals.WeightVector) bool {
	return math.Abs(a.Latency-b.Latency) < 0.01 &&
		math.Abs(a.Energy-b.Energy) < 0.01 &&
		math.Abs(a.Carbon-b.Carbon) < 0.01
}
