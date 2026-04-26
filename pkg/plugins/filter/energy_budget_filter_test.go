package filter

import (
	"testing"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

func newTestFilter(t *testing.T) (*EnergyBudgetFilter, *signals.EnergyStore) {
	t.Helper()
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultEnergyBudgetFilterConfig()
	filter := NewEnergyBudgetFilter("test-energy-filter", store, config)
	return filter, store
}

func TestEnergyBudgetFilter_AllowsNormalPods(t *testing.T) {
	f, store := newTestFilter(t)

	store.UpdateProfile(signals.EnergyProfile{
		PodName:        "gpu-1",
		TDP_Watts:      700,
		CurrentPower_W: 400, // 57% utilization — well below 90% threshold
	})
	store.UpdateProfile(signals.EnergyProfile{
		PodName:        "asic-1",
		TDP_Watts:      75,
		CurrentPower_W: 50, // 67% utilization — below threshold
	})

	pods := []PodCandidate{
		{Name: "gpu-1"},
		{Name: "asic-1"},
	}
	result := f.FilterPodsDetailed(pods)

	if len(result.Accepted) != 2 {
		t.Errorf("Expected 2 accepted pods, got %d", len(result.Accepted))
	}
	if len(result.Rejected) != 0 {
		t.Errorf("Expected 0 rejected pods, got %d: %v", len(result.Rejected), result.Rejected)
	}
}

func TestEnergyBudgetFilter_RejectsOverloadedPod(t *testing.T) {
	f, store := newTestFilter(t)

	store.UpdateProfile(signals.EnergyProfile{
		PodName:        "gpu-overloaded",
		TDP_Watts:      700,
		CurrentPower_W: 680, // 97% utilization — exceeds 90% threshold
	})
	store.UpdateProfile(signals.EnergyProfile{
		PodName:        "gpu-ok",
		TDP_Watts:      700,
		CurrentPower_W: 400,
	})

	pods := []PodCandidate{
		{Name: "gpu-overloaded"},
		{Name: "gpu-ok"},
	}
	result := f.FilterPodsDetailed(pods)

	if len(result.Accepted) != 1 {
		t.Errorf("Expected 1 accepted pod, got %d", len(result.Accepted))
	}
	if result.Accepted[0].Name != "gpu-ok" {
		t.Errorf("Expected gpu-ok to pass, got %s", result.Accepted[0].Name)
	}
	if _, rejected := result.Rejected["gpu-overloaded"]; !rejected {
		t.Error("Expected gpu-overloaded to be rejected")
	}
	t.Logf("Rejection reason: %s", result.Rejected["gpu-overloaded"])
}

func TestEnergyBudgetFilter_RejectsClusterBudgetExceeded(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := EnergyBudgetFilterConfig{
		MaxClusterPower_W:        800, // tight budget
		MaxPodUtilizationFactor:  0.95,
		EstimatedPowerIncrease_W: 50,
	}
	f := NewEnergyBudgetFilter("test", store, config)

	// Current cluster power: 400 + 400 = 800W (at budget limit)
	store.UpdateProfile(signals.EnergyProfile{
		PodName:        "gpu-1",
		TDP_Watts:      700,
		CurrentPower_W: 400,
	})
	store.UpdateProfile(signals.EnergyProfile{
		PodName:        "gpu-2",
		TDP_Watts:      700,
		CurrentPower_W: 400,
	})

	pods := []PodCandidate{
		{Name: "gpu-1"},
		{Name: "gpu-2"},
	}
	result := f.FilterPodsDetailed(pods)

	// Both pods should be rejected because adding 50W would push above 800W
	if len(result.Accepted) != 0 {
		t.Errorf("Expected 0 accepted pods (cluster at budget), got %d", len(result.Accepted))
	}
	t.Logf("Cluster power: %.0fW, budget: %.0fW, headroom: %.0fW",
		result.ClusterPowerBefore, config.MaxClusterPower_W, result.ClusterPowerHeadroom)
}

func TestEnergyBudgetFilter_KeepsUnknownPods(t *testing.T) {
	f, _ := newTestFilter(t)

	pods := []PodCandidate{
		{Name: "unknown-pod"},
	}
	result := f.FilterPods(pods)

	// By default, unknown pods (no profile) are kept
	if len(result) != 1 {
		t.Error("Unknown pods should be kept by default")
	}
}

func TestEnergyBudgetFilter_FiltersUnknownPodsWhenConfigured(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultEnergyBudgetFilterConfig()
	config.FilterStalePods = true
	f := NewEnergyBudgetFilter("test", store, config)

	pods := []PodCandidate{
		{Name: "unknown-pod"},
	}
	result := f.FilterPodsDetailed(pods)

	if len(result.Accepted) != 0 {
		t.Error("Unknown pods should be filtered when FilterStalePods is true")
	}
	if _, rejected := result.Rejected["unknown-pod"]; !rejected {
		t.Error("unknown-pod should appear in rejected map")
	}
}

func TestEnergyBudgetFilter_Name(t *testing.T) {
	f, _ := newTestFilter(t)
	if f.Name() != "test-energy-filter" {
		t.Errorf("Name() = %s, want test-energy-filter", f.Name())
	}
}

func TestEnergyBudgetFilter_MixedHeterogeneous(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := EnergyBudgetFilterConfig{
		MaxClusterPower_W:        1500,
		MaxPodUtilizationFactor:  0.85,
		EstimatedPowerIncrease_W: 30,
	}
	f := NewEnergyBudgetFilter("test", store, config)

	// Mixed cluster: some overloaded, some fine
	store.UpdateProfile(signals.EnergyProfile{
		PodName: "gpu-hot", TDP_Watts: 700, CurrentPower_W: 650, // 93% — over 85%
	})
	store.UpdateProfile(signals.EnergyProfile{
		PodName: "gpu-warm", TDP_Watts: 700, CurrentPower_W: 500, // 71% — ok
	})
	store.UpdateProfile(signals.EnergyProfile{
		PodName: "asic-cool", TDP_Watts: 75, CurrentPower_W: 45, // 60% — ok
	})
	store.UpdateProfile(signals.EnergyProfile{
		PodName: "asic-idle", TDP_Watts: 75, CurrentPower_W: 20, // 27% — ok
	})

	pods := []PodCandidate{
		{Name: "gpu-hot"},
		{Name: "gpu-warm"},
		{Name: "asic-cool"},
		{Name: "asic-idle"},
	}
	result := f.FilterPodsDetailed(pods)

	if len(result.Accepted) != 3 {
		t.Errorf("Expected 3 accepted pods, got %d", len(result.Accepted))
	}
	if _, rejected := result.Rejected["gpu-hot"]; !rejected {
		t.Error("gpu-hot should be rejected (93% > 85% threshold)")
	}

	t.Logf("Filter result: %d accepted, %d rejected", len(result.Accepted), len(result.Rejected))
	for name, reason := range result.Rejected {
		t.Logf("  Rejected %s: %s", name, reason)
	}
}
