package signals

import (
	"sync"
	"testing"
	"time"
)

func newTestStore() *EnergyStore {
	return NewEnergyStore(10 * time.Second)
}

func TestEnergyStore_UpdateAndGet(t *testing.T) {
	store := newTestStore()

	profile := EnergyProfile{
		PodName:       "gpu-pod-1",
		HardwareClass: GPU_HIGH_PERF,
		TDP_Watts:     700,
		CurrentPower_W: 500,
	}
	store.UpdateProfile(profile)

	got := store.GetProfile("gpu-pod-1")
	if got == nil {
		t.Fatal("Expected profile for gpu-pod-1, got nil")
	}
	if got.HardwareClass != GPU_HIGH_PERF {
		t.Errorf("HardwareClass = %s, want %s", got.HardwareClass, GPU_HIGH_PERF)
	}
	if got.CurrentPower_W != 500 {
		t.Errorf("CurrentPower = %f, want 500", got.CurrentPower_W)
	}
}

func TestEnergyStore_GetNonExistent(t *testing.T) {
	store := newTestStore()
	if got := store.GetProfile("nonexistent"); got != nil {
		t.Error("Expected nil for nonexistent pod")
	}
}

func TestEnergyStore_RemoveProfile(t *testing.T) {
	store := newTestStore()
	store.UpdateProfile(EnergyProfile{PodName: "gpu-pod-1"})
	store.RemoveProfile("gpu-pod-1")
	if store.GetProfile("gpu-pod-1") != nil {
		t.Error("Profile should be nil after removal")
	}
}

func TestEnergyStore_TotalClusterPower(t *testing.T) {
	store := newTestStore()
	store.UpdateProfile(EnergyProfile{PodName: "pod-1", CurrentPower_W: 500})
	store.UpdateProfile(EnergyProfile{PodName: "pod-2", CurrentPower_W: 300})
	store.UpdateProfile(EnergyProfile{PodName: "pod-3", CurrentPower_W: 75})

	total := store.TotalClusterPower()
	if total != 875 {
		t.Errorf("TotalClusterPower = %f, want 875", total)
	}
}

func TestEnergyStore_PodCount(t *testing.T) {
	store := newTestStore()
	store.UpdateProfile(EnergyProfile{PodName: "pod-1"})
	store.UpdateProfile(EnergyProfile{PodName: "pod-2"})
	if store.PodCount() != 2 {
		t.Errorf("PodCount = %d, want 2", store.PodCount())
	}
}

func TestEnergyStore_IsStale(t *testing.T) {
	store := NewEnergyStore(1 * time.Second)
	store.UpdateProfile(EnergyProfile{PodName: "pod-1"})

	if store.IsStale("pod-1") {
		t.Error("Profile should not be stale immediately after update")
	}

	// Wait for staleness
	time.Sleep(1100 * time.Millisecond)
	if !store.IsStale("pod-1") {
		t.Error("Profile should be stale after staleDuration")
	}

	if !store.IsStale("nonexistent") {
		t.Error("Nonexistent pod should report as stale")
	}
}

func TestEnergyStore_AverageEnergyPerToken(t *testing.T) {
	store := newTestStore()
	store.UpdateProfile(EnergyProfile{
		PodName:           "gpu-1",
		HardwareClass:     GPU_HIGH_PERF,
		EnergyPerToken_mJ: 5.0,
	})
	store.UpdateProfile(EnergyProfile{
		PodName:           "gpu-2",
		HardwareClass:     GPU_HIGH_PERF,
		EnergyPerToken_mJ: 7.0,
	})
	store.UpdateProfile(EnergyProfile{
		PodName:           "asic-1",
		HardwareClass:     ASIC_LOW_POWER,
		EnergyPerToken_mJ: 1.2,
	})

	gpuAvg := store.AverageEnergyPerToken(GPU_HIGH_PERF)
	if gpuAvg != 6.0 {
		t.Errorf("GPU avg energy = %f, want 6.0", gpuAvg)
	}

	asicAvg := store.AverageEnergyPerToken(ASIC_LOW_POWER)
	if asicAvg != 1.2 {
		t.Errorf("ASIC avg energy = %f, want 1.2", asicAvg)
	}

	noAvg := store.AverageEnergyPerToken(FPGA_LOW_POWER)
	if noAvg != 0 {
		t.Errorf("No FPGA pods should return 0, got %f", noAvg)
	}
}

func TestEnergyStore_ExternalSignals(t *testing.T) {
	store := newTestStore()
	ext := ExternalSignals{
		CarbonIntensity_gCO2_kWh: 390.0,
		ElectricityPrice_USD_kWh: 0.10,
		GridRegion:               "US-CAL-CISO",
	}
	store.UpdateExternalSignals(ext)

	got := store.GetExternalSignals()
	if got.CarbonIntensity_gCO2_kWh != 390.0 {
		t.Errorf("Carbon intensity = %f, want 390.0", got.CarbonIntensity_gCO2_kWh)
	}
	if got.GridRegion != "US-CAL-CISO" {
		t.Errorf("GridRegion = %s, want US-CAL-CISO", got.GridRegion)
	}
}

func TestEnergyStore_GetAllProfiles(t *testing.T) {
	store := newTestStore()
	store.UpdateProfile(EnergyProfile{PodName: "pod-1", CurrentPower_W: 100})
	store.UpdateProfile(EnergyProfile{PodName: "pod-2", CurrentPower_W: 200})

	all := store.GetAllProfiles()
	if len(all) != 2 {
		t.Errorf("GetAllProfiles returned %d profiles, want 2", len(all))
	}
	if all["pod-1"].CurrentPower_W != 100 {
		t.Error("pod-1 power mismatch")
	}
}

func TestEnergyStore_ConcurrencyStress(t *testing.T) {
	store := newTestStore()
	var wg sync.WaitGroup

	// Concurrent writers
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				store.UpdateProfile(EnergyProfile{
					PodName:        "pod-concurrent",
					CurrentPower_W: float64(id*100 + j),
				})
			}
		}(i)
	}

	// Concurrent readers
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				_ = store.GetProfile("pod-concurrent")
				_ = store.TotalClusterPower()
				_ = store.GetAllProfiles()
			}
		}()
	}

	wg.Wait()
	// If we get here without a data race, the test passes.
	// Run with: go test -race ./pkg/signals/
}

func TestEnergyStore_EvictStaleProfiles(t *testing.T) {
	store := NewEnergyStore(200 * time.Millisecond)

	// Add some fresh profiles
	store.UpdateProfile(EnergyProfile{PodName: "fresh-1", CurrentPower_W: 100})
	store.UpdateProfile(EnergyProfile{PodName: "fresh-2", CurrentPower_W: 200})

	// Wait for them to go stale
	time.Sleep(300 * time.Millisecond)

	// Add one fresh profile
	store.UpdateProfile(EnergyProfile{PodName: "fresh-3", CurrentPower_W: 300})

	// Stale count should be 2
	if store.StaleCount() != 2 {
		t.Errorf("StaleCount = %d, want 2", store.StaleCount())
	}

	// Evict stale profiles
	evicted := store.EvictStaleProfiles()
	if len(evicted) != 2 {
		t.Errorf("Expected 2 evicted, got %d: %v", len(evicted), evicted)
	}

	// Only fresh-3 should remain
	if store.PodCount() != 1 {
		t.Errorf("PodCount after eviction = %d, want 1", store.PodCount())
	}
	if store.GetProfile("fresh-3") == nil {
		t.Error("fresh-3 should still exist after eviction")
	}
	if store.GetProfile("fresh-1") != nil {
		t.Error("fresh-1 should be evicted")
	}

	t.Logf("Evicted %d stale pods, %d remaining", len(evicted), store.PodCount())
}

func TestEnergyStore_StaleCount_Empty(t *testing.T) {
	store := NewEnergyStore(10 * time.Second)
	if store.StaleCount() != 0 {
		t.Errorf("Empty store should have 0 stale, got %d", store.StaleCount())
	}
}
