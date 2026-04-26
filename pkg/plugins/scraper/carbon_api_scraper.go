// Package scraper implements external API scrapers for the energy-aware EPP.
//
// This file implements the Carbon Intensity API Scraper. It periodically fetches
// grid carbon intensity (gCO2eq/kWh) for the cluster's physical region.
//
// Supported Providers:
//   - ElectricityMaps (/v3/carbon-intensity/latest)
//   - CO2Signal (wrapper around ElectricityMaps)
//
// The fetched data is injected into the EnergyStore and used by the
// CarbonIntensityScorer to dynamically compute gCO2eq per inference token.
package scraper

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// CarbonAPIScraperConfig holds configuration for the carbon scraper.
type CarbonAPIScraperConfig struct {
	// APIUrl is the endpoint for the carbon intensity data.
	// Default: "https://api.co2signal.com/v1/latest"
	APIUrl string `yaml:"apiUrl"`

	// APIKey is the authentication token for the service.
	APIKey string `yaml:"apiKey"`

	// Region is the geographic location zone identifier (e.g., "US-CAL-CISO", "FR").
	Region string `yaml:"region"`

	// PollInterval is how often to query the API.
	// Carbon data typically updates every 5-15 minutes, so 5m is a good default.
	PollInterval time.Duration `yaml:"pollInterval"`

	// FallbackIntensity is used if the API is unreachable.
	FallbackIntensity float64 `yaml:"fallbackIntensity"`

	// RequestTimeout is the HTTP timeout.
	RequestTimeout time.Duration `yaml:"requestTimeout"`
}

// DefaultCarbonAPIScraperConfig returns defaults.
func DefaultCarbonAPIScraperConfig() CarbonAPIScraperConfig {
	return CarbonAPIScraperConfig{
		APIUrl:            "https://api.co2signal.com/v1/latest",
		Region:            "US-CAL-CISO", // California default
		PollInterval:      5 * time.Minute,
		FallbackIntensity: 390.0, // US Average
		RequestTimeout:    10 * time.Second,
	}
}

// CO2SignalResponse represents the JSON payload from the CO2Signal API.
type CO2SignalResponse struct {
	Status string `json:"status"`
	Data   struct {
		CarbonIntensity float64 `json:"carbonIntensity"` // gCO2eq/kWh
		FossilFuelPct   float64 `json:"fossilFuelPercentage"`
	} `json:"data"`
	Units struct {
		CarbonIntensity string `json:"carbonIntensity"`
	} `json:"units"`
}

// CarbonScraper periodically fetches grid carbon intensity.
type CarbonScraper struct {
	config CarbonAPIScraperConfig
	store  *signals.EnergyStore
	client HTTPClient
	cancel context.CancelFunc
}

// NewCarbonScraper creates a new carbon API scraper.
func NewCarbonScraper(store *signals.EnergyStore, config CarbonAPIScraperConfig) *CarbonScraper {
	return &CarbonScraper{
		config: config,
		store:  store,
		client: &http.Client{
			Timeout: config.RequestTimeout,
		},
	}
}

// NewCarbonScraperWithClient creates a scraper with a custom client for testing.
func NewCarbonScraperWithClient(store *signals.EnergyStore, config CarbonAPIScraperConfig, client HTTPClient) *CarbonScraper {
	return &CarbonScraper{
		config: config,
		store:  store,
		client: client,
	}
}

// Start begins the background polling loop.
func (s *CarbonScraper) Start(ctx context.Context) {
	ctx, s.cancel = context.WithCancel(ctx)

	// Fetch immediately on startup
	s.fetchAndUpdate(ctx)

	go func() {
		ticker := time.NewTicker(s.config.PollInterval)
		defer ticker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				s.fetchAndUpdate(ctx)
			}
		}
	}()
}

// Stop stops the background polling loop.
func (s *CarbonScraper) Stop() {
	if s.cancel != nil {
		s.cancel()
	}
}

// fetchAndUpdate hits the external API and updates the EnergyStore.
func (s *CarbonScraper) fetchAndUpdate(ctx context.Context) {
	intensity, err := s.fetchCarbonIntensity(ctx)
	if err != nil {
		log.Printf("[CarbonScraper] Failed to fetch carbon data: %v. Using old/fallback value.", err)
		// If fetch fails but we have no data at all, apply fallback
		ext := s.store.GetExternalSignals()
		if ext.CarbonIntensity_gCO2_kWh == 0 {
			s.updateStore(s.config.FallbackIntensity)
		}
		return
	}

	s.updateStore(intensity)
}

// updateStore updates the external signals in the EnergyStore while preserving other fields.
func (s *CarbonScraper) updateStore(intensity float64) {
	ext := s.store.GetExternalSignals()
	ext.CarbonIntensity_gCO2_kWh = intensity
	ext.GridRegion = s.config.Region
	// We leave ElectricityPrice_USD_kWh alone (it's managed by another scraper)
	s.store.UpdateExternalSignals(ext)
}

// fetchCarbonIntensity performs the HTTP request to the CO2Signal API.
func (s *CarbonScraper) fetchCarbonIntensity(ctx context.Context) (float64, error) {
	if s.config.APIUrl == "" {
		return s.config.FallbackIntensity, nil // No API configured, use fallback
	}

	reqURL := fmt.Sprintf("%s?countryCode=%s", s.config.APIUrl, s.config.Region)
	req, err := http.NewRequestWithContext(ctx, "GET", reqURL, nil)
	if err != nil {
		return 0, err
	}

	if s.config.APIKey != "" {
		req.Header.Add("auth-token", s.config.APIKey)
	}

	resp, err := s.client.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		return 0, fmt.Errorf("API error %d: %s", resp.StatusCode, string(body))
	}

	var responseData CO2SignalResponse
	if err := json.NewDecoder(resp.Body).Decode(&responseData); err != nil {
		return 0, fmt.Errorf("JSON decode error: %w", err)
	}

	if responseData.Status != "ok" {
		return 0, fmt.Errorf("API returned non-ok status: %s", responseData.Status)
	}

	return responseData.Data.CarbonIntensity, nil
}
