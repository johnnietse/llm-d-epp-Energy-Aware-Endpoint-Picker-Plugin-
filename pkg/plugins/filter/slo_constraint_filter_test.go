package filter

import (
	"testing"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

func TestSLOFilter_TTFT_RejectsSlowPrefill(t *testing.T) {
	store := signals.NewEnergyStore(30 * time.Second)

	// Slow GPU — only 100 tok/s → TTFT = 256/100 * 1000 = 2560ms >> 500ms SLO
	store.UpdateProfile(signals.EnergyProfile{
		PodName: "slow-gpu", TokensPerSecond: 100, LastUpdated: time.Now(),
	})
	// Fast GPU — 800 tok/s → TTFT = 256/800 * 1000 = 320ms < 500ms SLO
	store.UpdateProfile(signals.EnergyProfile{
		PodName: "fast-gpu", TokensPerSecond: 800, LastUpdated: time.Now(),
	})

	f := NewSLOFilter("slo", store, DefaultSLOFilterConfig())
	candidates := []PodCandidate{{Name: "slow-gpu"}, {Name: "fast-gpu"}}

	accepted := f.FilterPods(candidates, signals.PhasePrefill)

	if len(accepted) != 1 {
		t.Fatalf("Expected 1 accepted pod, got %d", len(accepted))
	}
	if accepted[0].Name != "fast-gpu" {
		t.Errorf("Expected fast-gpu to pass SLO, got %s", accepted[0].Name)
	}
	t.Log("Correctly rejected slow-gpu (TTFT 2560ms > 500ms SLO)")
}

func TestSLOFilter_TPOT_RejectsSlowDecode(t *testing.T) {
	store := signals.NewEnergyStore(30 * time.Second)

	// Slow ASIC — 5 tok/s → TPOT = 200ms > 100ms SLO
	store.UpdateProfile(signals.EnergyProfile{
		PodName: "slow-asic", TokensPerSecond: 5, LastUpdated: time.Now(),
	})
	// Fast ASIC — 420 tok/s → TPOT = 2.4ms < 100ms SLO
	store.UpdateProfile(signals.EnergyProfile{
		PodName: "fast-asic", TokensPerSecond: 420, LastUpdated: time.Now(),
	})

	f := NewSLOFilter("slo", store, DefaultSLOFilterConfig())
	candidates := []PodCandidate{{Name: "slow-asic"}, {Name: "fast-asic"}}

	accepted := f.FilterPods(candidates, signals.PhaseDecode)

	if len(accepted) != 1 {
		t.Fatalf("Expected 1 accepted, got %d", len(accepted))
	}
	if accepted[0].Name != "fast-asic" {
		t.Errorf("Expected fast-asic, got %s", accepted[0].Name)
	}
	t.Log("Correctly rejected slow-asic (TPOT 200ms > 100ms SLO)")
}

func TestSLOFilter_QueueDepth_RejectsOverloaded(t *testing.T) {
	store := signals.NewEnergyStore(30 * time.Second)

	store.UpdateProfile(signals.EnergyProfile{
		PodName: "busy-pod", ActiveRequests: 60, TokensPerSecond: 800, LastUpdated: time.Now(),
	})
	store.UpdateProfile(signals.EnergyProfile{
		PodName: "idle-pod", ActiveRequests: 5, TokensPerSecond: 800, LastUpdated: time.Now(),
	})

	f := NewSLOFilter("slo", store, DefaultSLOFilterConfig())
	candidates := []PodCandidate{{Name: "busy-pod"}, {Name: "idle-pod"}}

	accepted := f.FilterPods(candidates, signals.PhaseDecode)

	if len(accepted) != 1 || accepted[0].Name != "idle-pod" {
		t.Errorf("Expected only idle-pod, got %v", accepted)
	}
	t.Log("Correctly rejected overloaded pod (60 > 50 max queue depth)")
}

func TestSLOFilter_NoTelemetry_Accepts(t *testing.T) {
	store := signals.NewEnergyStore(30 * time.Second)

	f := NewSLOFilter("slo", store, DefaultSLOFilterConfig())
	candidates := []PodCandidate{{Name: "new-pod"}}

	accepted := f.FilterPods(candidates, signals.PhasePrefill)
	if len(accepted) != 1 {
		t.Error("New pod without telemetry should be accepted")
	}
}

func TestSLOFilter_Disabled(t *testing.T) {
	store := signals.NewEnergyStore(30 * time.Second)

	f := NewSLOFilter("slo", store, SLOFilterConfig{})
	candidates := []PodCandidate{{Name: "a"}, {Name: "b"}}

	accepted := f.FilterPods(candidates, signals.PhaseDecode)
	if len(accepted) != 2 {
		t.Error("Disabled SLO filter should pass all pods")
	}
}

func TestSLOFilter_QueueDelay_PrefillPenalty(t *testing.T) {
	store := signals.NewEnergyStore(30 * time.Second)

	// Fast GPU with heavy queue → TTFT = 320ms, queue delay = 20 * 320 * 0.5 = 3200ms → total 3520ms > 500ms
	store.UpdateProfile(signals.EnergyProfile{
		PodName: "queued-gpu", TokensPerSecond: 800, ActiveRequests: 20, LastUpdated: time.Now(),
	})
	// Same GPU, light queue → TTFT = 320ms, queue delay = 1 * 320 * 0.5 = 160ms → total 480ms < 500ms
	store.UpdateProfile(signals.EnergyProfile{
		PodName: "light-gpu", TokensPerSecond: 800, ActiveRequests: 1, LastUpdated: time.Now(),
	})

	f := NewSLOFilter("slo", store, DefaultSLOFilterConfig())
	candidates := []PodCandidate{{Name: "queued-gpu"}, {Name: "light-gpu"}}

	accepted := f.FilterPods(candidates, signals.PhasePrefill)
	if len(accepted) != 1 || accepted[0].Name != "light-gpu" {
		t.Errorf("Expected light-gpu only, got %v", accepted)
	}
	t.Log("Queue delay correctly compounds with base TTFT estimate")
}
