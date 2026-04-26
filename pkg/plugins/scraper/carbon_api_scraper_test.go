package scraper

import (
	"context"
	"errors"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// Sample successful response from CO2Signal
const cO2SignalSuccess = `{
  "status": "ok",
  "data": {
    "carbonIntensity": 240.5,
    "fossilFuelPercentage": 45.2
  },
  "units": {
    "carbonIntensity": "gCO2eq/kWh"
  }
}`

const cO2SignalError = `{
  "status": "error",
  "message": "Invalid auth token"
}`

type mockCarbonClient struct {
	mu        sync.Mutex
	body       string
	statusCode int
	err        error
	callCount  int
}

func (m *mockCarbonClient) Do(req *http.Request) (*http.Response, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.callCount++
	if m.err != nil {
		return nil, m.err
	}
	if m.statusCode == 0 {
		m.statusCode = 200
	}
	return &http.Response{
		StatusCode: m.statusCode,
		Body:       io.NopCloser(strings.NewReader(m.body)),
	}, nil
}

func TestCarbonScraper_FetchAndUpdate_Success(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultCarbonAPIScraperConfig()
	client := &mockCarbonClient{
		body: cO2SignalSuccess,
	}
	
	scraper := NewCarbonScraperWithClient(store, config, client)

	scraper.fetchAndUpdate(context.Background())

	ext := store.GetExternalSignals()
	if ext.CarbonIntensity_gCO2_kWh != 240.5 {
		t.Errorf("Expected 240.5 carbon intensity, got %f", ext.CarbonIntensity_gCO2_kWh)
	}
	if ext.GridRegion != "US-CAL-CISO" {
		t.Errorf("Expected US-CAL-CISO region, got %s", ext.GridRegion)
	}
}

func TestCarbonScraper_FetchAndUpdate_FallbackOnInitialError(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultCarbonAPIScraperConfig()
	config.FallbackIntensity = 500.0
	client := &mockCarbonClient{
		err: errors.New("network timeout"),
	}
	
	scraper := NewCarbonScraperWithClient(store, config, client)

	scraper.fetchAndUpdate(context.Background())

	// Store should use fallback since it had no prior data
	ext := store.GetExternalSignals()
	if ext.CarbonIntensity_gCO2_kWh != 500.0 {
		t.Errorf("Expected fallback 500.0, got %f", ext.CarbonIntensity_gCO2_kWh)
	}
}

func TestCarbonScraper_FetchAndUpdate_RetainOldDataOnError(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	
	// Establish old ok data
	store.UpdateExternalSignals(signals.ExternalSignals{
		CarbonIntensity_gCO2_kWh: 200.0,
		GridRegion: "FR",
	})
	
	config := DefaultCarbonAPIScraperConfig()
	client := &mockCarbonClient{
		statusCode: 500, // API Error
		body: "Internal Server Error",
	}
	
	scraper := NewCarbonScraperWithClient(store, config, client)

	scraper.fetchAndUpdate(context.Background())

	// Store should retain old data, not fallback
	ext := store.GetExternalSignals()
	if ext.CarbonIntensity_gCO2_kWh != 200.0 {
		t.Errorf("Expected retained old data 200.0, got %f", ext.CarbonIntensity_gCO2_kWh)
	}
	if ext.GridRegion != "FR" {
		t.Errorf("Expected retained region FR, got %s", ext.GridRegion)
	}
}

func TestCarbonScraper_StartStop(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultCarbonAPIScraperConfig()
	config.PollInterval = 50 * time.Millisecond // fast poll
	
	client := &mockCarbonClient{
		body: cO2SignalSuccess,
	}
	scraper := NewCarbonScraperWithClient(store, config, client)

	ctx := context.Background()
	scraper.Start(ctx)
	
	time.Sleep(200 * time.Millisecond) // enough for ~4 polls plus the initial 1
	scraper.Stop()

	// Should have at least 2 calls
	client.mu.Lock()
	calls := client.callCount
	client.mu.Unlock()
	if calls < 2 {
		t.Errorf("Expected at least 2 API calls, got %d", calls)
	}
}
