package scraper

import (
	"testing"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

func TestRAPLScraper_Scrape(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultRAPLScraperConfig()
	mockReader := NewMockEnergyReader()
	scraper := NewRAPLScraperWithReader(store, config, mockReader)

	domain := "intel-rapl:0"

	// Mock reader initial values
	mockReader.SetMaxEnergy(domain, 100000000)
	mockReader.SetPowerLimit(domain, 75000000) // 75W TDP

	// ─── Scrape 1 (Baseline) ───
	mockReader.SetEnergy(domain, 1000000) // 1 J
	scraper.Scrape("cpu-pod-1", signals.ASIC_LOW_POWER)

	// First scrape establishes baseline but returns 0 power (needs delta)
	profile := store.GetProfile("cpu-pod-1")
	if profile == nil {
		t.Fatal("Expected profile after first scrape")
	}
	if profile.CurrentPower_W != 0 {
		t.Errorf("First scrape power = %f, want 0", profile.CurrentPower_W)
	}
	if profile.TDP_Watts != 75 {
		t.Errorf("TDP = %f, want 75", profile.TDP_Watts)
	}

	// ─── Scrape 2 ───
	time.Sleep(1 * time.Second) // Important: need non-zero dt
	mockReader.SetEnergy(domain, 15000000) // 15 J (Delta = 14 J)
	
	// Ensure the timestamp difference is exactly manageable for the calculation in tests
	// To make this stable regardless of how long sleep actually took, we can manually manipulate internal state
	// but for simplicity, we'll just check if it's broadly correct based on ~1s sleep.

	scraper.Scrape("cpu-pod-1", signals.ASIC_LOW_POWER)
	profile2 := store.GetProfile("cpu-pod-1")
	
	// Delta was 14,000,000 uJ approx 1 sec -> ~14W raw power.
	// EWMA with alpha 0.3: 0.3 * 14 + 0.7 * 0 = 4.2W
	if profile2.CurrentPower_W < 3 || profile2.CurrentPower_W > 6 {
		t.Errorf("Scrape 2 power = %f, expected around 4.2W", profile2.CurrentPower_W)
	}
}

func TestRAPLScraper_OverflowHandling(t *testing.T) {
	// Need to test computePower explicitly to inject specific timestamps
	config := DefaultRAPLScraperConfig()
	scraper := NewRAPLScraperWithReader(nil, config, nil)

	t1 := time.Now()
	t2 := t1.Add(1 * time.Second)

	// Normal case: 1M uJ over 1s = 1 Watt
	p1 := scraper.computePower(
		RAPLReading{Energy_uJ: 1000000, MaxEnergy_uJ: 10000000, Timestamp: t1},
		RAPLReading{Energy_uJ: 2000000, MaxEnergy_uJ: 10000000, Timestamp: t2},
	)
	if p1 != 1.0 {
		t.Errorf("Normal power = %f, want 1.0", p1)
	}

	// Overflow case: Counter wraps around
	// Prev: 9,000,000 (Max: 10,000,000) -> 1M til max
	// Curr: 2,000,000
	// Total delta: 1M + 2M = 3M uJ = 3 Watts
	p2 := scraper.computePower(
		RAPLReading{Energy_uJ: 9000000, MaxEnergy_uJ: 10000000, Timestamp: t1},
		RAPLReading{Energy_uJ: 2000000, MaxEnergy_uJ: 10000000, Timestamp: t2},
	)
	if p2 != 3.0 {
		t.Errorf("Overflow power = %f, want 3.0", p2)
	}
}

func TestRAPLScraper_ZeroDeltaTime(t *testing.T) {
	scraper := NewRAPLScraperWithReader(nil, DefaultRAPLScraperConfig(), nil)
	now := time.Now()
	power := scraper.computePower(
		RAPLReading{Energy_uJ: 1000000, Timestamp: now},
		RAPLReading{Energy_uJ: 2000000, Timestamp: now}, // Same timestamp
	)
	if power != 0 {
		t.Errorf("Power with dt=0 should be 0, got %f", power)
	}
}

func TestRAPLScraper_UnknownMaxEnergy(t *testing.T) {
	scraper := NewRAPLScraperWithReader(nil, DefaultRAPLScraperConfig(), nil)
	t1 := time.Now()
	t2 := t1.Add(1 * time.Second)

	// Mocking max uint64 for prev, so it thinks it overflows
	prev := ^uint64(0) - 1000000 // 1M less than max
	curr := uint64(2000000)      // Wrapped to 2M

	// Total delta = 1M + 2M = 3M uJ = 3W
	power := scraper.computePower(
		RAPLReading{Energy_uJ: prev, MaxEnergy_uJ: 0, Timestamp: t1},
		RAPLReading{Energy_uJ: curr, MaxEnergy_uJ: 0, Timestamp: t2},
	)
	
	if power != 3.0 {
		t.Errorf("Power with unknown max = %f, want 3.0", power)
	}
}

func TestRAPLScraper_MissingDomains(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultRAPLScraperConfig()
	mockReader := NewMockEnergyReader() // Empty, returns errors
	scraper := NewRAPLScraperWithReader(store, config, mockReader)

	scraper.Scrape("pod-1", signals.ASIC_LOW_POWER)
	
	// Profile should be created but power and TDP should be 0 because read failed
	profile := store.GetProfile("pod-1")
	if profile.CurrentPower_W != 0 {
		t.Error("Failed read should yield 0 power")
	}
	if profile.TDP_Watts != 0 {
		t.Error("Failed limit read should yield 0 TDP")
	}
}
