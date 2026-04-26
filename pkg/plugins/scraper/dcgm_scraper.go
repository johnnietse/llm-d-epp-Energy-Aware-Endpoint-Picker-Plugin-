// Package scraper implements the energy metrics scrapers for the llm-d EPP.
// Scrapers run periodically to collect power and throughput telemetry from
// inference pods and update the shared EnergyStore.
//
// This file implements the DCGM scraper, which reads NVIDIA GPU metrics
// from each pod's Prometheus /metrics endpoint. vLLM exposes these as:
//
//	DCGM_FI_DEV_POWER_USAGE      — GPU power draw in watts
//	DCGM_FI_DEV_GPU_UTIL         — GPU utilization percentage
//	vllm:num_requests_running     — active requests
//	vllm:num_requests_waiting     — queued requests
//	vllm:generation_tokens_total  — cumulative generated tokens
//
// Architecture:
//
//	DCGMScraper ──(HTTP GET /metrics)──▶ vLLM Pod ──▶ DCGM Exporter
//	     │
//	     └──(update)──▶ EnergyStore ──▶ EnergyAwareScorer
package scraper

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"math"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// DCGMScraperConfig holds configuration for the DCGM scraper.
type DCGMScraperConfig struct {
	// ScrapeInterval is how often to scrape each pod's metrics endpoint.
	ScrapeInterval time.Duration `yaml:"scrapeInterval"`

	// MetricsPort is the port where vLLM exposes Prometheus metrics.
	MetricsPort int `yaml:"metricsPort"`

	// MetricsPath is the HTTP path to the Prometheus metrics endpoint.
	MetricsPath string `yaml:"metricsPath"`

	// RequestTimeout is the HTTP request timeout per pod scrape.
	RequestTimeout time.Duration `yaml:"requestTimeout"`

	// EWMAAlpha is the smoothing factor for the exponentially weighted moving
	// average of energy-per-token. Range: (0, 1]. Higher = more reactive.
	EWMAAlpha float64 `yaml:"ewmaAlpha"`
}

// DefaultDCGMScraperConfig returns sensible defaults.
func DefaultDCGMScraperConfig() DCGMScraperConfig {
	return DCGMScraperConfig{
		ScrapeInterval: 2 * time.Second,
		MetricsPort:    8000,
		MetricsPath:    "/metrics",
		RequestTimeout: 1 * time.Second,
		EWMAAlpha:      0.3,
	}
}

// PodEndpoint represents a discoverable pod endpoint for scraping.
type PodEndpoint struct {
	// Name is the Kubernetes pod name.
	Name string

	// Address is the pod's IP or DNS name (e.g., "10.0.1.5" or "pod-name.namespace.svc").
	Address string

	// HardwareClass is read from the pod's llm-d.ai/hardware-class label.
	HardwareClass signals.HardwareClass

	// TDP_Watts is read from the pod's llm-d.ai/tdp-watts label.
	TDP_Watts float64
}

// RawMetrics holds the parsed Prometheus metrics from a single pod scrape.
type RawMetrics struct {
	// PowerUsage_W is the GPU power draw from DCGM_FI_DEV_POWER_USAGE.
	PowerUsage_W float64

	// GPUUtilization is the GPU utilization from DCGM_FI_DEV_GPU_UTIL (0-100).
	GPUUtilization float64

	// ActiveRequests is from vllm:num_requests_running.
	ActiveRequests int

	// WaitingRequests is from vllm:num_requests_waiting.
	WaitingRequests int

	// GenerationTokensTotal is the cumulative token count from vllm:generation_tokens_total.
	GenerationTokensTotal float64

	// Timestamp is when this scrape occurred.
	Timestamp time.Time
}

// tokenRate tracks the previous token count for computing tokens-per-second.
type tokenRate struct {
	prevTokens    float64
	prevTimestamp time.Time
	tokensPerSec  float64
}

// DCGMScraper scrapes NVIDIA DCGM and vLLM metrics from inference pods.
type DCGMScraper struct {
	config     DCGMScraperConfig
	store      *signals.EnergyStore
	client     HTTPClient
	tokenRates map[string]*tokenRate // pod name → token rate tracker
	mu         sync.Mutex           // protects tokenRates

	// cancel is used to stop the background scrape loop.
	cancel context.CancelFunc
}

// HTTPClient is an interface for making HTTP requests, enabling test mocking.
type HTTPClient interface {
	Do(req *http.Request) (*http.Response, error)
}

// NewDCGMScraper creates a new DCGM scraper.
func NewDCGMScraper(store *signals.EnergyStore, config DCGMScraperConfig) *DCGMScraper {
	return &DCGMScraper{
		config: config,
		store:  store,
		client: &http.Client{
			Timeout: config.RequestTimeout,
		},
		tokenRates: make(map[string]*tokenRate),
	}
}

// NewDCGMScraperWithClient creates a scraper with a custom HTTP client (for testing).
func NewDCGMScraperWithClient(store *signals.EnergyStore, config DCGMScraperConfig, client HTTPClient) *DCGMScraper {
	return &DCGMScraper{
		config:     config,
		store:      store,
		client:     client,
		tokenRates: make(map[string]*tokenRate),
	}
}

// Start begins the periodic scrape loop in a background goroutine.
// It scrapes all registered pod endpoints every ScrapeInterval.
func (s *DCGMScraper) Start(ctx context.Context, endpoints []PodEndpoint) {
	ctx, s.cancel = context.WithCancel(ctx)

	go func() {
		ticker := time.NewTicker(s.config.ScrapeInterval)
		defer ticker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				s.scrapeAll(ctx, endpoints)
			}
		}
	}()
}

// Stop halts the background scrape loop.
func (s *DCGMScraper) Stop() {
	if s.cancel != nil {
		s.cancel()
	}
}

// scrapeAll scrapes all pod endpoints and updates the store.
func (s *DCGMScraper) scrapeAll(ctx context.Context, endpoints []PodEndpoint) {
	var wg sync.WaitGroup
	for _, ep := range endpoints {
		wg.Add(1)
		go func(ep PodEndpoint) {
			defer wg.Done()
			s.scrapePod(ctx, ep)
		}(ep)
	}
	wg.Wait()
}

// scrapePod scrapes a single pod's metrics endpoint and updates the store.
func (s *DCGMScraper) scrapePod(ctx context.Context, ep PodEndpoint) {
	url := fmt.Sprintf("http://%s:%d%s", ep.Address, s.config.MetricsPort, s.config.MetricsPath)

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return // skip this pod
	}

	resp, err := s.client.Do(req)
	if err != nil {
		return // pod may be unreachable — skip
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return
	}

	raw, err := ParsePrometheusMetrics(resp.Body)
	if err != nil {
		return
	}

	// Compute tokens per second from cumulative counter
	tps := s.computeTokenRate(ep.Name, raw)

	// Compute energy per token (EWMA)
	energyPerToken := s.computeEnergyPerToken(ep.Name, raw.PowerUsage_W, tps)

	// Build and store the profile
	profile := signals.EnergyProfile{
		PodName:           ep.Name,
		HardwareClass:     ep.HardwareClass,
		TDP_Watts:         ep.TDP_Watts,
		CurrentPower_W:    raw.PowerUsage_W,
		EnergyPerToken_mJ: energyPerToken,
		Utilization:       raw.GPUUtilization / 100.0,
		TokensPerSecond:   tps,
		ActiveRequests:    raw.ActiveRequests,
	}

	s.store.UpdateProfile(profile)
}

// computeTokenRate computes tokens/sec from the cumulative token counter.
func (s *DCGMScraper) computeTokenRate(podName string, raw RawMetrics) float64 {
	s.mu.Lock()
	defer s.mu.Unlock()

	tr, exists := s.tokenRates[podName]
	if !exists {
		s.tokenRates[podName] = &tokenRate{
			prevTokens:    raw.GenerationTokensTotal,
			prevTimestamp:  raw.Timestamp,
			tokensPerSec:  0,
		}
		return 0 // first scrape — no rate yet
	}

	dt := raw.Timestamp.Sub(tr.prevTimestamp).Seconds()
	if dt <= 0 {
		return tr.tokensPerSec
	}

	dTokens := raw.GenerationTokensTotal - tr.prevTokens
	if dTokens < 0 {
		dTokens = 0 // counter reset
	}

	newRate := dTokens / dt

	// Apply EWMA smoothing
	tr.tokensPerSec = s.config.EWMAAlpha*newRate + (1-s.config.EWMAAlpha)*tr.tokensPerSec
	tr.prevTokens = raw.GenerationTokensTotal
	tr.prevTimestamp = raw.Timestamp

	return tr.tokensPerSec
}

// computeEnergyPerToken computes mJ per token using power and throughput.
func (s *DCGMScraper) computeEnergyPerToken(podName string, power_W float64, tps float64) float64 {
	if tps <= 0 || power_W <= 0 {
		return 0
	}
	// Energy per token = power (W) / throughput (tokens/s) * 1000 (to convert J to mJ)
	// = power / tps * 1000 mJ
	return (power_W / tps) * 1000.0
}

// ParsePrometheusMetrics parses a Prometheus text exposition format response body
// and extracts the specific metrics we care about.
func ParsePrometheusMetrics(body io.Reader) (RawMetrics, error) {
	raw := RawMetrics{
		Timestamp: time.Now(),
	}

	scanner := bufio.NewScanner(body)
	for scanner.Scan() {
		line := scanner.Text()

		// Skip comments and empty lines
		if strings.HasPrefix(line, "#") || strings.TrimSpace(line) == "" {
			continue
		}

		// Parse metric name and value
		name, value, ok := parseMetricLine(line)
		if !ok {
			continue
		}

		switch {
		case strings.HasPrefix(name, "DCGM_FI_DEV_POWER_USAGE"):
			raw.PowerUsage_W = value
		case strings.HasPrefix(name, "DCGM_FI_DEV_GPU_UTIL"):
			raw.GPUUtilization = value
		case strings.HasPrefix(name, "vllm:num_requests_running"):
			raw.ActiveRequests = int(math.Round(value))
		case strings.HasPrefix(name, "vllm:num_requests_waiting"):
			raw.WaitingRequests = int(math.Round(value))
		case strings.HasPrefix(name, "vllm:generation_tokens_total"):
			raw.GenerationTokensTotal = value
		}
	}

	return raw, scanner.Err()
}

// parseMetricLine parses a single line of Prometheus text format.
// Returns the metric name (with labels), the value, and whether parsing succeeded.
// Example: `DCGM_FI_DEV_POWER_USAGE{gpu="0"} 523.4` → ("DCGM_FI_DEV_POWER_USAGE{gpu=\"0\"}", 523.4, true)
func parseMetricLine(line string) (string, float64, bool) {
	// Find the last space — everything before is the metric name+labels, after is the value
	lastSpace := strings.LastIndex(line, " ")
	if lastSpace < 0 {
		return "", 0, false
	}

	name := line[:lastSpace]
	valueStr := strings.TrimSpace(line[lastSpace+1:])

	// Handle timestamps (Prometheus format may have timestamp after value)
	parts := strings.Fields(valueStr)
	if len(parts) == 0 {
		return "", 0, false
	}
	valueStr = parts[0]

	value, err := strconv.ParseFloat(valueStr, 64)
	if err != nil {
		return "", 0, false
	}

	return name, value, true
}
