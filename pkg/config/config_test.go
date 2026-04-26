package config

import (
	"context"
	"testing"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// ─── Mock GIE Types ─────────────────────────────────────────────────

type mockPod struct {
	name        string
	labels      map[string]string
	queueLength int
}

func (p *mockPod) GetName() string              { return p.name }
func (p *mockPod) GetLabels() map[string]string  { return p.labels }
func (p *mockPod) GetQueueLength() int           { return p.queueLength }

type mockRequest struct {
	model   string
	headers map[string]string
}

func (r *mockRequest) GetModel() string              { return r.model }
func (r *mockRequest) GetHeaders() map[string]string  { return r.headers }

type mockCycleState struct {
	profile string
}

func (c *mockCycleState) GetSchedulingProfile() string { return c.profile }

// ─── Integration Test: Full Pipeline ────────────────────────────────

func TestEnergyPluginSuite_Creation(t *testing.T) {
	config := DefaultEnergyConfig()
	suite := NewEnergyPluginSuite(config)

	if suite.Store == nil {
		t.Fatal("Store should not be nil")
	}
	if suite.EnergyScorer == nil {
		t.Fatal("EnergyScorer should not be nil")
	}
	if suite.BudgetFilter == nil {
		t.Fatal("BudgetFilter should not be nil")
	}
	if suite.CarbonScorer == nil {
		t.Fatal("CarbonScorer should not be nil")
	}
	if suite.DCGMScraper == nil {
		t.Fatal("DCGMScraper should not be nil")
	}
	if suite.CarbonScraper == nil {
		t.Fatal("CarbonScraper should not be nil")
	}

	t.Log("All plugin suite components created successfully")
}

// TestFilterAdapter_EndToEnd tests the full flow: GIE pods → adapter → filter → GIE pods
func TestFilterAdapter_EndToEnd(t *testing.T) {
	config := DefaultEnergyConfig()
	suite := NewEnergyPluginSuite(config)

	// Populate store with energy profiles
	suite.Store.UpdateProfile(signals.EnergyProfile{
		PodName:        "gpu-ok",
		TDP_Watts:      700,
		CurrentPower_W: 400, // 57% — below 90% threshold
	})
	suite.Store.UpdateProfile(signals.EnergyProfile{
		PodName:        "gpu-hot",
		TDP_Watts:      700,
		CurrentPower_W: 680, // 97% — above threshold
	})
	suite.Store.UpdateProfile(signals.EnergyProfile{
		PodName:        "asic-ok",
		TDP_Watts:      75,
		CurrentPower_W: 50, // 67% — OK
	})

	adapter := NewEnergyBudgetFilterAdapter(suite.BudgetFilter)

	// Create GIE-typed pods
	giePods := []GIEPod{
		&mockPod{name: "gpu-ok", labels: map[string]string{"llm-d.ai/role": "prefill"}},
		&mockPod{name: "gpu-hot", labels: map[string]string{"llm-d.ai/role": "prefill"}},
		&mockPod{name: "asic-ok", labels: map[string]string{"llm-d.ai/role": "decode"}},
	}

	ctx := context.Background()
	cs := &mockCycleState{profile: "decode"}
	req := &mockRequest{model: "llama-7b"}

	// Run the adapter
	accepted := adapter.Filter(ctx, cs, req, giePods)

	// gpu-hot should be filtered out
	if len(accepted) != 2 {
		t.Errorf("Expected 2 accepted pods, got %d", len(accepted))
	}

	for _, pod := range accepted {
		if pod.GetName() == "gpu-hot" {
			t.Error("gpu-hot should have been filtered out (97% TDP utilization)")
		}
	}

	t.Logf("Filter adapter: %d → %d pods (filtered %d)",
		len(giePods), len(accepted), len(giePods)-len(accepted))
}

// TestScorerAdapter_PrefillProfile tests scoring through the GIE adapter
// using the prefill scheduling profile.
func TestScorerAdapter_PrefillProfile(t *testing.T) {
	config := DefaultEnergyConfig()
	suite := NewEnergyPluginSuite(config)

	// Populate store
	suite.Store.UpdateProfile(signals.EnergyProfile{
		PodName:           "gpu-h100",
		HardwareClass:     signals.GPU_HIGH_PERF,
		TDP_Watts:         700,
		CurrentPower_W:    500,
		EnergyPerToken_mJ: 6.0,
		TokensPerSecond:   800,
	})
	suite.Store.UpdateProfile(signals.EnergyProfile{
		PodName:           "asic-qc",
		HardwareClass:     signals.ASIC_LOW_POWER,
		TDP_Watts:         75,
		CurrentPower_W:    55,
		EnergyPerToken_mJ: 1.0,
		TokensPerSecond:   400,
	})

	suite.Store.UpdateExternalSignals(signals.ExternalSignals{
		CarbonIntensity_gCO2_kWh: 390,
		ElectricityPrice_USD_kWh: 0.10,
	})

	adapter := NewEnergyAwareScorerAdapter(suite.EnergyScorer)

	ctx := context.Background()
	prefillCS := &mockCycleState{profile: "prefill"}
	req := &mockRequest{model: "llama-7b"}

	gpuPod := &mockPod{name: "gpu-h100", labels: map[string]string{}, queueLength: 2}
	asicPod := &mockPod{name: "asic-qc", labels: map[string]string{}, queueLength: 1}

	gpuScore, err := adapter.Score(ctx, prefillCS, req, gpuPod)
	if err != nil {
		t.Fatalf("GPU score error: %v", err)
	}

	asicScore, err := adapter.Score(ctx, prefillCS, req, asicPod)
	if err != nil {
		t.Fatalf("ASIC score error: %v", err)
	}

	t.Logf("Prefill scores — GPU: %d/1000, ASIC: %d/1000", gpuScore, asicScore)

	// For prefill, both are scored individually (not batch-normalized against each other
	// since each Score call creates a single-element list), so the ranking depends
	// on the raw sub-scores. The absolute values matter for GIE's weighted combination.
	if gpuScore < 0 || gpuScore > 1000 {
		t.Errorf("GPU score %d out of [0, 1000] range", gpuScore)
	}
	if asicScore < 0 || asicScore > 1000 {
		t.Errorf("ASIC score %d out of [0, 1000] range", asicScore)
	}
}

// TestScorerAdapter_DecodeProfile tests scoring through the GIE adapter
// using the decode scheduling profile.
func TestScorerAdapter_DecodeProfile(t *testing.T) {
	config := DefaultEnergyConfig()
	suite := NewEnergyPluginSuite(config)

	suite.Store.UpdateProfile(signals.EnergyProfile{
		PodName:           "gpu-h100",
		HardwareClass:     signals.GPU_HIGH_PERF,
		TDP_Watts:         700,
		CurrentPower_W:    500,
		EnergyPerToken_mJ: 6.0,
		TokensPerSecond:   800,
	})

	suite.Store.UpdateExternalSignals(signals.ExternalSignals{
		CarbonIntensity_gCO2_kWh: 390,
	})

	adapter := NewEnergyAwareScorerAdapter(suite.EnergyScorer)

	ctx := context.Background()
	decodeCS := &mockCycleState{profile: "decode"}
	req := &mockRequest{model: "llama-7b"}
	gpuPod := &mockPod{name: "gpu-h100", queueLength: 3}

	score, err := adapter.Score(ctx, decodeCS, req, gpuPod)
	if err != nil {
		t.Fatalf("Score error: %v", err)
	}

	t.Logf("Decode score for GPU H100: %d/1000", score)
	if score < 0 || score > 1000 {
		t.Errorf("Score %d out of [0, 1000] range", score)
	}
}

// TestCarbonScorerAdapter tests the carbon scorer through the GIE adapter.
func TestCarbonScorerAdapter(t *testing.T) {
	config := DefaultEnergyConfig()
	suite := NewEnergyPluginSuite(config)

	suite.Store.UpdateProfile(signals.EnergyProfile{
		PodName:         "asic-1",
		CurrentPower_W:  55,
		TokensPerSecond: 400,
		TDP_Watts:       75,
	})
	suite.Store.UpdateExternalSignals(signals.ExternalSignals{
		CarbonIntensity_gCO2_kWh: 240,
	})

	adapter := NewCarbonIntensityScorerAdapter(suite.CarbonScorer)

	ctx := context.Background()
	cs := &mockCycleState{profile: "decode"}
	req := &mockRequest{model: "llama-7b"}
	pod := &mockPod{name: "asic-1", queueLength: 0}

	score, err := adapter.Score(ctx, cs, req, pod)
	if err != nil {
		t.Fatalf("Carbon score error: %v", err)
	}

	t.Logf("Carbon score for ASIC: %d/1000", score)
	if score < 0 || score > 1000 {
		t.Errorf("Score %d out of [0, 1000] range", score)
	}
}

// TestInferPhaseFromCycleState tests the phase detection helper.
func TestInferPhaseFromCycleState(t *testing.T) {
	tests := []struct {
		profile string
		want    signals.InferencePhase
	}{
		{"prefill", signals.PhasePrefill},
		{"decode", signals.PhaseDecode},
		{"unknown", signals.PhaseDecode},
		{"", signals.PhaseDecode},
	}

	for _, tt := range tests {
		t.Run(tt.profile, func(t *testing.T) {
			cs := &mockCycleState{profile: tt.profile}
			got := inferPhaseFromCycleState(cs)
			if got != tt.want {
				t.Errorf("inferPhaseFromCycleState(%q) = %s, want %s", tt.profile, got, tt.want)
			}
		})
	}

	// Test nil cycle state
	if got := inferPhaseFromCycleState(nil); got != signals.PhaseDecode {
		t.Errorf("nil cycleState should default to decode, got %s", got)
	}
}

// TestParseHardwareClassLabel tests label parsing.
func TestParseHardwareClassLabel(t *testing.T) {
	labels := map[string]string{
		"llm-d.ai/hardware-class": "ASIC_LOW_POWER",
		"llm-d.ai/tdp-watts":     "75",
	}

	class := ParseHardwareClassLabel(labels)
	if class != signals.ASIC_LOW_POWER {
		t.Errorf("ParseHardwareClassLabel = %s, want ASIC_LOW_POWER", class)
	}

	tdp := ParseTDPLabel(labels)
	if tdp != 75 {
		t.Errorf("ParseTDPLabel = %f, want 75", tdp)
	}
}

// TestParseLabels_Defaults tests default label values.
func TestParseLabels_Defaults(t *testing.T) {
	empty := map[string]string{}

	class := ParseHardwareClassLabel(empty)
	if class != signals.GPU_MED_PERF {
		t.Errorf("Default class = %s, want GPU_MED_PERF", class)
	}

	tdp := ParseTDPLabel(empty)
	if tdp != 200 {
		t.Errorf("Default TDP = %f, want 200", tdp)
	}
}

// TestFullPipeline_HeterogeneousCluster simulates a complete scheduling cycle
// with a heterogeneous cluster: filter → score → pick winner.
func TestFullPipeline_HeterogeneousCluster(t *testing.T) {
	config := DefaultEnergyConfig()
	suite := NewEnergyPluginSuite(config)

	// Populate a realistic cluster
	profiles := []signals.EnergyProfile{
		{PodName: "gpu-h100-1", HardwareClass: signals.GPU_HIGH_PERF, TDP_Watts: 700, CurrentPower_W: 550, EnergyPerToken_mJ: 6.0, TokensPerSecond: 800, Utilization: 0.78},
		{PodName: "gpu-h100-2", HardwareClass: signals.GPU_HIGH_PERF, TDP_Watts: 700, CurrentPower_W: 680, EnergyPerToken_mJ: 7.0, TokensPerSecond: 700, Utilization: 0.97}, // HOT — should be filtered
		{PodName: "gpu-a100-cap", HardwareClass: signals.GPU_MED_PERF, TDP_Watts: 200, CurrentPower_W: 160, EnergyPerToken_mJ: 2.5, TokensPerSecond: 600, Utilization: 0.80},
		{PodName: "asic-qc-1", HardwareClass: signals.ASIC_LOW_POWER, TDP_Watts: 75, CurrentPower_W: 55, EnergyPerToken_mJ: 1.0, TokensPerSecond: 420, Utilization: 0.73},
		{PodName: "asic-qc-2", HardwareClass: signals.ASIC_LOW_POWER, TDP_Watts: 75, CurrentPower_W: 50, EnergyPerToken_mJ: 0.9, TokensPerSecond: 400, Utilization: 0.67},
	}
	for _, p := range profiles {
		suite.Store.UpdateProfile(p)
	}
	suite.Store.UpdateExternalSignals(signals.ExternalSignals{
		CarbonIntensity_gCO2_kWh: 390, ElectricityPrice_USD_kWh: 0.10, GridRegion: "US-CAL-CISO",
	})

	// Create GIE pods
	giePods := []GIEPod{
		&mockPod{name: "gpu-h100-1", labels: map[string]string{"llm-d.ai/hardware-class": "GPU_HIGH_PERF"}, queueLength: 2},
		&mockPod{name: "gpu-h100-2", labels: map[string]string{"llm-d.ai/hardware-class": "GPU_HIGH_PERF"}, queueLength: 5},
		&mockPod{name: "gpu-a100-cap", labels: map[string]string{"llm-d.ai/hardware-class": "GPU_MED_PERF"}, queueLength: 3},
		&mockPod{name: "asic-qc-1", labels: map[string]string{"llm-d.ai/hardware-class": "ASIC_LOW_POWER"}, queueLength: 1},
		&mockPod{name: "asic-qc-2", labels: map[string]string{"llm-d.ai/hardware-class": "ASIC_LOW_POWER"}, queueLength: 0},
	}

	ctx := context.Background()
	req := &mockRequest{model: "llama-7b"}

	// ─── DECODE CYCLE ───────────────────────────────────────────────
	t.Log("=== DECODE SCHEDULING CYCLE ===")
	decodeCS := &mockCycleState{profile: "decode"}

	// Step 1: Filter
	filterAdapter := NewEnergyBudgetFilterAdapter(suite.BudgetFilter)
	filtered := filterAdapter.Filter(ctx, decodeCS, req, giePods)
	t.Logf("Filter: %d → %d pods", len(giePods), len(filtered))

	// gpu-h100-2 should be filtered (97% > 90% threshold)
	for _, pod := range filtered {
		if pod.GetName() == "gpu-h100-2" {
			t.Error("gpu-h100-2 should be filtered (97% TDP)")
		}
	}

	// Step 2: Score remaining pods
	scorerAdapter := NewEnergyAwareScorerAdapter(suite.EnergyScorer)
	scores := make(map[string]int64)
	for _, pod := range filtered {
		score, err := scorerAdapter.Score(ctx, decodeCS, req, pod)
		if err != nil {
			t.Fatalf("Score error for %s: %v", pod.GetName(), err)
		}
		scores[pod.GetName()] = score
	}

	t.Log("Decode scores:")
	for name, score := range scores {
		t.Logf("  %s: %d/1000", name, score)
	}

	// Step 3: Pick winner (max score)
	var winner string
	var maxScore int64 = -1
	for name, score := range scores {
		if score > maxScore {
			maxScore = score
			winner = name
		}
	}
	t.Logf("Winner (decode): %s with score %d/1000", winner, maxScore)

	// ─── PREFILL CYCLE ──────────────────────────────────────────────
	t.Log("\n=== PREFILL SCHEDULING CYCLE ===")
	prefillCS := &mockCycleState{profile: "prefill"}

	filtered = filterAdapter.Filter(ctx, prefillCS, req, giePods)
	t.Logf("Filter: %d → %d pods", len(giePods), len(filtered))

	scores = make(map[string]int64)
	for _, pod := range filtered {
		score, err := scorerAdapter.Score(ctx, prefillCS, req, pod)
		if err != nil {
			t.Fatalf("Score error: %v", err)
		}
		scores[pod.GetName()] = score
	}

	t.Log("Prefill scores:")
	for name, score := range scores {
		t.Logf("  %s: %d/1000", name, score)
	}

	winner = ""
	maxScore = -1
	for name, score := range scores {
		if score > maxScore {
			maxScore = score
			winner = name
		}
	}
	t.Logf("Winner (prefill): %s with score %d/1000", winner, maxScore)
}

// Ensure time import is used
var _ = time.Second
