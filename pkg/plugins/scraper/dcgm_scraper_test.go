package scraper

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// ─── Mock HTTP Client ───────────────────────────────────────────────

// mockHTTPClient simulates HTTP responses from vLLM pods for testing.
type mockHTTPClient struct {
	mu sync.Mutex
	// responses maps pod address → response body
	responses map[string]string
	// statusCodes maps pod address → HTTP status code
	statusCodes map[string]int
	// errors maps pod address → error to return
	errors map[string]error
	// callCount tracks how many times each address was called
	callCount map[string]int
}

func newMockClient() *mockHTTPClient {
	return &mockHTTPClient{
		responses:   make(map[string]string),
		statusCodes: make(map[string]int),
		errors:      make(map[string]error),
		callCount:   make(map[string]int),
	}
}

func (m *mockHTTPClient) setResponse(address string, port int, body string) {
	key := fmt.Sprintf("http://%s:%d/metrics", address, port)
	m.responses[key] = body
	m.statusCodes[key] = 200
}

func (m *mockHTTPClient) setError(address string, port int, err error) {
	key := fmt.Sprintf("http://%s:%d/metrics", address, port)
	m.errors[key] = err
}

func (m *mockHTTPClient) Do(req *http.Request) (*http.Response, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	url := req.URL.String()
	m.callCount[url]++

	if err, ok := m.errors[url]; ok {
		return nil, err
	}

	body, ok := m.responses[url]
	if !ok {
		return &http.Response{
			StatusCode: 404,
			Body:       io.NopCloser(strings.NewReader("Not Found")),
		}, nil
	}

	status := m.statusCodes[url]
	if status == 0 {
		status = 200
	}

	return &http.Response{
		StatusCode: status,
		Body:       io.NopCloser(strings.NewReader(body)),
	}, nil
}

// ─── Test Prometheus Metrics Format ─────────────────────────────────

// Sample Prometheus metrics response from a vLLM pod with DCGM exporter.
const sampleMetricsH100 = `# HELP DCGM_FI_DEV_POWER_USAGE Power draw (watts).
# TYPE DCGM_FI_DEV_POWER_USAGE gauge
DCGM_FI_DEV_POWER_USAGE{gpu="0",UUID="GPU-abc123"} 523.4
# HELP DCGM_FI_DEV_GPU_UTIL GPU utilization (%).
# TYPE DCGM_FI_DEV_GPU_UTIL gauge
DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-abc123"} 78.5
# HELP vllm:num_requests_running Number of requests currently being processed.
# TYPE vllm:num_requests_running gauge
vllm:num_requests_running 5
# HELP vllm:num_requests_waiting Number of requests waiting in queue.
# TYPE vllm:num_requests_waiting gauge
vllm:num_requests_waiting 2
# HELP vllm:generation_tokens_total Total number of generation tokens.
# TYPE vllm:generation_tokens_total counter
vllm:generation_tokens_total 150000
`

const sampleMetricsASIC = `# HELP DCGM_FI_DEV_POWER_USAGE Power draw (watts).
# TYPE DCGM_FI_DEV_POWER_USAGE gauge
DCGM_FI_DEV_POWER_USAGE{gpu="0"} 58.2
# HELP DCGM_FI_DEV_GPU_UTIL GPU utilization (%).
# TYPE DCGM_FI_DEV_GPU_UTIL gauge
DCGM_FI_DEV_GPU_UTIL{gpu="0"} 62.0
# HELP vllm:num_requests_running Number of requests currently being processed.
# TYPE vllm:num_requests_running gauge
vllm:num_requests_running 3
# HELP vllm:num_requests_waiting Number of requests waiting in queue.
# TYPE vllm:num_requests_waiting gauge
vllm:num_requests_waiting 0
# HELP vllm:generation_tokens_total Total number of generation tokens.
# TYPE vllm:generation_tokens_total counter
vllm:generation_tokens_total 80000
`

// Updated metrics (simulating a second scrape 2 seconds later)
const sampleMetricsH100Updated = `# HELP DCGM_FI_DEV_POWER_USAGE Power draw (watts).
# TYPE DCGM_FI_DEV_POWER_USAGE gauge
DCGM_FI_DEV_POWER_USAGE{gpu="0",UUID="GPU-abc123"} 540.1
# HELP DCGM_FI_DEV_GPU_UTIL GPU utilization (%).
# TYPE DCGM_FI_DEV_GPU_UTIL gauge
DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-abc123"} 82.0
# HELP vllm:num_requests_running Number of requests currently being processed.
# TYPE vllm:num_requests_running gauge
vllm:num_requests_running 7
# HELP vllm:num_requests_waiting Number of requests waiting in queue.
# TYPE vllm:num_requests_waiting gauge
vllm:num_requests_waiting 3
# HELP vllm:generation_tokens_total Total number of generation tokens.
# TYPE vllm:generation_tokens_total counter
vllm:generation_tokens_total 151600
`

// ─── Tests ──────────────────────────────────────────────────────────

func TestParsePrometheusMetrics_H100(t *testing.T) {
	raw, err := ParsePrometheusMetrics(strings.NewReader(sampleMetricsH100))
	if err != nil {
		t.Fatalf("ParsePrometheusMetrics failed: %v", err)
	}

	if raw.PowerUsage_W != 523.4 {
		t.Errorf("PowerUsage = %f, want 523.4", raw.PowerUsage_W)
	}
	if raw.GPUUtilization != 78.5 {
		t.Errorf("GPUUtilization = %f, want 78.5", raw.GPUUtilization)
	}
	if raw.ActiveRequests != 5 {
		t.Errorf("ActiveRequests = %d, want 5", raw.ActiveRequests)
	}
	if raw.WaitingRequests != 2 {
		t.Errorf("WaitingRequests = %d, want 2", raw.WaitingRequests)
	}
	if raw.GenerationTokensTotal != 150000 {
		t.Errorf("GenerationTokensTotal = %f, want 150000", raw.GenerationTokensTotal)
	}
}

func TestParsePrometheusMetrics_ASIC(t *testing.T) {
	raw, err := ParsePrometheusMetrics(strings.NewReader(sampleMetricsASIC))
	if err != nil {
		t.Fatalf("ParsePrometheusMetrics failed: %v", err)
	}

	if raw.PowerUsage_W != 58.2 {
		t.Errorf("PowerUsage = %f, want 58.2 (low-power ASIC)", raw.PowerUsage_W)
	}
	if raw.ActiveRequests != 3 {
		t.Errorf("ActiveRequests = %d, want 3", raw.ActiveRequests)
	}
}

func TestParsePrometheusMetrics_EmptyBody(t *testing.T) {
	raw, err := ParsePrometheusMetrics(strings.NewReader(""))
	if err != nil {
		t.Fatalf("Empty body should not error: %v", err)
	}
	if raw.PowerUsage_W != 0 {
		t.Errorf("Empty body should produce zero power, got %f", raw.PowerUsage_W)
	}
}

func TestParsePrometheusMetrics_CommentsOnly(t *testing.T) {
	body := `# HELP some_metric A help string
# TYPE some_metric gauge
`
	raw, err := ParsePrometheusMetrics(strings.NewReader(body))
	if err != nil {
		t.Fatalf("Comments-only body should not error: %v", err)
	}
	if raw.PowerUsage_W != 0 {
		t.Error("Comments-only should produce zero metrics")
	}
}

func TestParseMetricLine(t *testing.T) {
	tests := []struct {
		line      string
		wantName  string
		wantValue float64
		wantOK    bool
	}{
		{
			line:      `DCGM_FI_DEV_POWER_USAGE{gpu="0"} 523.4`,
			wantName:  `DCGM_FI_DEV_POWER_USAGE{gpu="0"}`,
			wantValue: 523.4,
			wantOK:    true,
		},
		{
			line:      `vllm:num_requests_running 5`,
			wantName:  `vllm:num_requests_running`,
			wantValue: 5,
			wantOK:    true,
		},
		{
			line:      `vllm:generation_tokens_total 150000`,
			wantName:  `vllm:generation_tokens_total`,
			wantValue: 150000,
			wantOK:    true,
		},
		{
			line:   `# HELP this is a comment`,
			wantOK: false, // comments shouldn't even reach here, but handle gracefully
		},
		{
			line:   `invalid_no_value`,
			wantOK: false,
		},
		{
			line:   ``,
			wantOK: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.line, func(t *testing.T) {
			name, value, ok := parseMetricLine(tt.line)
			if ok != tt.wantOK {
				t.Fatalf("parseMetricLine(%q) ok = %v, want %v", tt.line, ok, tt.wantOK)
			}
			if !ok {
				return
			}
			if name != tt.wantName {
				t.Errorf("name = %q, want %q", name, tt.wantName)
			}
			if value != tt.wantValue {
				t.Errorf("value = %f, want %f", value, tt.wantValue)
			}
		})
	}
}

func TestDCGMScraper_ScrapePod(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultDCGMScraperConfig()
	client := newMockClient()
	scraper := NewDCGMScraperWithClient(store, config, client)

	// Set up mock response
	client.setResponse("10.0.1.5", 8000, sampleMetricsH100)

	ep := PodEndpoint{
		Name:          "gpu-h100-1",
		Address:       "10.0.1.5",
		HardwareClass: signals.GPU_HIGH_PERF,
		TDP_Watts:     700,
	}

	// First scrape — establishes baseline
	scraper.scrapePod(context.Background(), ep)

	profile := store.GetProfile("gpu-h100-1")
	if profile == nil {
		t.Fatal("Expected profile after first scrape")
	}

	if profile.CurrentPower_W != 523.4 {
		t.Errorf("CurrentPower = %f, want 523.4", profile.CurrentPower_W)
	}
	if profile.HardwareClass != signals.GPU_HIGH_PERF {
		t.Errorf("HardwareClass = %s, want GPU_HIGH_PERF", profile.HardwareClass)
	}
	if profile.TDP_Watts != 700 {
		t.Errorf("TDP = %f, want 700", profile.TDP_Watts)
	}
	// First scrape: tokens/sec should be 0 (no previous baseline)
	if profile.TokensPerSecond != 0 {
		t.Errorf("First scrape TokensPerSec = %f, want 0", profile.TokensPerSecond)
	}

	t.Logf("After first scrape: power=%.1fW, util=%.1f%%, activeReqs=%d",
		profile.CurrentPower_W, profile.Utilization*100, profile.ActiveRequests)
}

func TestDCGMScraper_TokenRateComputation(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultDCGMScraperConfig()
	scraper := NewDCGMScraperWithClient(store, config, newMockClient())

	// Simulate two consecutive scrapes
	raw1 := RawMetrics{
		GenerationTokensTotal: 150000,
		Timestamp:             time.Now(),
	}
	raw2 := RawMetrics{
		GenerationTokensTotal: 151600, // 1600 more tokens
		Timestamp:             raw1.Timestamp.Add(2 * time.Second),
	}

	// First scrape — baseline
	rate1 := scraper.computeTokenRate("pod-1", raw1)
	if rate1 != 0 {
		t.Errorf("First scrape rate = %f, want 0", rate1)
	}

	// Second scrape — should have 1600 tokens / 2 seconds = 800 tok/s
	rate2 := scraper.computeTokenRate("pod-1", raw2)
	// EWMA: 0.3 * 800 + 0.7 * 0 = 240
	expectedRate := 0.3 * 800.0
	if rate2 < expectedRate-1 || rate2 > expectedRate+1 {
		t.Errorf("Second scrape rate = %f, want ~%f (EWMA)", rate2, expectedRate)
	}

	t.Logf("Token rate after 2nd scrape: %.1f tok/s (raw=800, EWMA alpha=%.1f)",
		rate2, config.EWMAAlpha)
}

func TestDCGMScraper_EnergyPerTokenComputation(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultDCGMScraperConfig()
	scraper := NewDCGMScraperWithClient(store, config, newMockClient())

	// H100 at 500W doing 800 tok/s
	ept := scraper.computeEnergyPerToken("gpu-1", 500.0, 800.0)
	// 500W / 800 tok/s = 0.625 J/tok = 625 mJ/tok
	if ept < 620 || ept > 630 {
		t.Errorf("GPU energy/token = %f mJ, want ~625 mJ", ept)
	}

	// ASIC at 60W doing 400 tok/s
	eptASIC := scraper.computeEnergyPerToken("asic-1", 60.0, 400.0)
	// 60W / 400 tok/s = 0.15 J/tok = 150 mJ/tok
	if eptASIC < 145 || eptASIC > 155 {
		t.Errorf("ASIC energy/token = %f mJ, want ~150 mJ", eptASIC)
	}

	// Key check: ASIC is more efficient
	ratio := ept / eptASIC
	if ratio < 4.0 || ratio > 4.5 {
		t.Errorf("GPU/ASIC energy ratio = %f, want ~4.17", ratio)
	}
	t.Logf("GPU: %.0f mJ/tok, ASIC: %.0f mJ/tok → ASIC is %.1fx more efficient",
		ept, eptASIC, ratio)
}

func TestDCGMScraper_EnergyPerToken_ZeroCases(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultDCGMScraperConfig()
	scraper := NewDCGMScraperWithClient(store, config, newMockClient())

	// Zero throughput
	if ept := scraper.computeEnergyPerToken("pod", 500, 0); ept != 0 {
		t.Errorf("Zero throughput should give 0 energy/token, got %f", ept)
	}

	// Zero power
	if ept := scraper.computeEnergyPerToken("pod", 0, 800); ept != 0 {
		t.Errorf("Zero power should give 0 energy/token, got %f", ept)
	}
}

func TestDCGMScraper_ScrapePodError(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultDCGMScraperConfig()
	client := newMockClient()
	scraper := NewDCGMScraperWithClient(store, config, client)

	// Simulate unreachable pod
	client.setError("10.0.1.99", 8000, fmt.Errorf("connection refused"))

	ep := PodEndpoint{
		Name:    "unreachable-pod",
		Address: "10.0.1.99",
	}
	scraper.scrapePod(context.Background(), ep)

	// Should not crash and should not create a profile
	if store.GetProfile("unreachable-pod") != nil {
		t.Error("Unreachable pod should not have a profile")
	}
}

func TestDCGMScraper_ScrapeAll_Heterogeneous(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultDCGMScraperConfig()
	client := newMockClient()
	scraper := NewDCGMScraperWithClient(store, config, client)

	// Set up two different pod types
	client.setResponse("10.0.1.5", 8000, sampleMetricsH100)
	client.setResponse("10.0.2.10", 8000, sampleMetricsASIC)

	endpoints := []PodEndpoint{
		{Name: "gpu-h100", Address: "10.0.1.5", HardwareClass: signals.GPU_HIGH_PERF, TDP_Watts: 700},
		{Name: "asic-qc", Address: "10.0.2.10", HardwareClass: signals.ASIC_LOW_POWER, TDP_Watts: 75},
	}

	scraper.scrapeAll(context.Background(), endpoints)

	// Verify both pods were scraped
	gpuProfile := store.GetProfile("gpu-h100")
	asicProfile := store.GetProfile("asic-qc")

	if gpuProfile == nil || asicProfile == nil {
		t.Fatal("Both pods should have profiles after scrapeAll")
	}

	if gpuProfile.CurrentPower_W != 523.4 {
		t.Errorf("GPU power = %f, want 523.4", gpuProfile.CurrentPower_W)
	}
	if asicProfile.CurrentPower_W != 58.2 {
		t.Errorf("ASIC power = %f, want 58.2", asicProfile.CurrentPower_W)
	}

	// Power difference should be dramatic
	powerRatio := gpuProfile.CurrentPower_W / asicProfile.CurrentPower_W
	t.Logf("GPU draws %.1fW, ASIC draws %.1fW → GPU uses %.1fx more power",
		gpuProfile.CurrentPower_W, asicProfile.CurrentPower_W, powerRatio)

	if powerRatio < 8 {
		t.Errorf("Power ratio = %f, expected GPU to draw >8x more than ASIC", powerRatio)
	}
}

func TestDCGMScraper_StartStop(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DCGMScraperConfig{
		ScrapeInterval: 50 * time.Millisecond, // fast for testing
		MetricsPort:    8000,
		MetricsPath:    "/metrics",
		RequestTimeout: 100 * time.Millisecond,
		EWMAAlpha:      0.3,
	}
	client := newMockClient()
	scraper := NewDCGMScraperWithClient(store, config, client)

	client.setResponse("10.0.1.5", 8000, sampleMetricsH100)

	endpoints := []PodEndpoint{
		{Name: "gpu-h100", Address: "10.0.1.5", HardwareClass: signals.GPU_HIGH_PERF, TDP_Watts: 700},
	}

	// Start scraper
	ctx := context.Background()
	scraper.Start(ctx, endpoints)

	// Wait for a few scrape cycles
	time.Sleep(200 * time.Millisecond)

	// Stop scraper
	scraper.Stop()

	// Verify profile exists
	profile := store.GetProfile("gpu-h100")
	if profile == nil {
		t.Fatal("Profile should exist after scraper ran")
	}

	// Verify multiple scrapes occurred
	url := "http://10.0.1.5:8000/metrics"
	client.mu.Lock()
	calls := client.callCount[url]
	client.mu.Unlock()
	if calls < 2 {
		t.Errorf("Expected at least 2 scrape calls, got %d", calls)
	}
	t.Logf("Scraper made %d calls in 200ms (interval=50ms)", calls)
}

func TestParsePrometheusMetrics_RealWorldFormat(t *testing.T) {
	// More realistic vLLM output with additional metrics we don't care about
	body := `# HELP python_gc_objects_collected_total Objects collected during gc
# TYPE python_gc_objects_collected_total counter
python_gc_objects_collected_total{generation="0"} 1234.0
python_gc_objects_collected_total{generation="1"} 131.0
# HELP DCGM_FI_DEV_POWER_USAGE Power draw (watts).
# TYPE DCGM_FI_DEV_POWER_USAGE gauge
DCGM_FI_DEV_POWER_USAGE{gpu="0",UUID="GPU-abc123",modelName="A100"} 312.7
# HELP DCGM_FI_DEV_GPU_UTIL GPU utilization (%).
# TYPE DCGM_FI_DEV_GPU_UTIL gauge
DCGM_FI_DEV_GPU_UTIL{gpu="0",UUID="GPU-abc123",modelName="A100"} 45.0
# HELP vllm:num_requests_running Number of requests being processed.
# TYPE vllm:num_requests_running gauge
vllm:num_requests_running 12
# HELP vllm:num_requests_waiting Number of requests waiting.
# TYPE vllm:num_requests_waiting gauge
vllm:num_requests_waiting 0
# HELP vllm:generation_tokens_total Total number of tokens generated.
# TYPE vllm:generation_tokens_total counter
vllm:generation_tokens_total 9876543
# HELP vllm:prompt_tokens_total Total number of prompt tokens processed.
# TYPE vllm:prompt_tokens_total counter
vllm:prompt_tokens_total 12345678
`
	raw, err := ParsePrometheusMetrics(bytes.NewBufferString(body))
	if err != nil {
		t.Fatalf("Failed to parse: %v", err)
	}

	if raw.PowerUsage_W != 312.7 {
		t.Errorf("Power = %f, want 312.7", raw.PowerUsage_W)
	}
	if raw.GPUUtilization != 45.0 {
		t.Errorf("GPU util = %f, want 45.0", raw.GPUUtilization)
	}
	if raw.ActiveRequests != 12 {
		t.Errorf("Active requests = %d, want 12", raw.ActiveRequests)
	}
	if raw.GenerationTokensTotal != 9876543 {
		t.Errorf("Tokens total = %f, want 9876543", raw.GenerationTokensTotal)
	}
}
