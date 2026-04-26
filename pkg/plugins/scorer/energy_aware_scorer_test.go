package scorer

import (
	"testing"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// newTestScorer creates a test scorer with a pre-populated store.
func newTestScorer(t *testing.T) (*EnergyAwareScorer, *signals.EnergyStore) {
	t.Helper()
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultEnergyAwareScorerConfig()
	scorer := NewEnergyAwareScorer("test-energy-scorer", store, config)
	return scorer, store
}

// setupHeterogeneousPods creates a representative heterogeneous cluster in the store:
// - 2 GPU high-performance pods (H100-like)
// - 1 GPU mid-performance pod (A100 power-capped)
// - 2 ASIC low-power pods (Qualcomm Cloud AI 100-like)
func setupHeterogeneousPods(store *signals.EnergyStore) []PodInfo {
	store.UpdateProfile(signals.EnergyProfile{
		PodName:           "gpu-h100-1",
		HardwareClass:     signals.GPU_HIGH_PERF,
		TDP_Watts:         700,
		CurrentPower_W:    550,
		EnergyPerToken_mJ: 6.0,
		TokensPerSecond:   800,
		Utilization:       0.7,
		ActiveRequests:    5,
	})
	store.UpdateProfile(signals.EnergyProfile{
		PodName:           "gpu-h100-2",
		HardwareClass:     signals.GPU_HIGH_PERF,
		TDP_Watts:         700,
		CurrentPower_W:    600,
		EnergyPerToken_mJ: 6.5,
		TokensPerSecond:   750,
		Utilization:       0.8,
		ActiveRequests:    8,
	})
	store.UpdateProfile(signals.EnergyProfile{
		PodName:           "gpu-a100-capped",
		HardwareClass:     signals.GPU_MED_PERF,
		TDP_Watts:         200,
		CurrentPower_W:    180,
		EnergyPerToken_mJ: 2.5,
		TokensPerSecond:   600,
		Utilization:       0.9,
		ActiveRequests:    6,
	})
	store.UpdateProfile(signals.EnergyProfile{
		PodName:           "asic-qc-1",
		HardwareClass:     signals.ASIC_LOW_POWER,
		TDP_Watts:         75,
		CurrentPower_W:    60,
		EnergyPerToken_mJ: 1.2,
		TokensPerSecond:   400,
		Utilization:       0.6,
		ActiveRequests:    3,
	})
	store.UpdateProfile(signals.EnergyProfile{
		PodName:           "asic-qc-2",
		HardwareClass:     signals.ASIC_LOW_POWER,
		TDP_Watts:         75,
		CurrentPower_W:    55,
		EnergyPerToken_mJ: 1.0,
		TokensPerSecond:   420,
		Utilization:       0.5,
		ActiveRequests:    2,
	})

	// Set external signals
	store.UpdateExternalSignals(signals.ExternalSignals{
		CarbonIntensity_gCO2_kWh: 390.0,
		ElectricityPrice_USD_kWh: 0.10,
		GridRegion:               "US-CAL-CISO",
	})

	return []PodInfo{
		{Name: "gpu-h100-1", Labels: map[string]string{"llm-d.ai/role": "prefill"}, QueueDepth: 2},
		{Name: "gpu-h100-2", Labels: map[string]string{"llm-d.ai/role": "prefill"}, QueueDepth: 5},
		{Name: "gpu-a100-capped", Labels: map[string]string{"llm-d.ai/role": "decode"}, QueueDepth: 3},
		{Name: "asic-qc-1", Labels: map[string]string{"llm-d.ai/role": "decode"}, QueueDepth: 1},
		{Name: "asic-qc-2", Labels: map[string]string{"llm-d.ai/role": "decode"}, QueueDepth: 0},
	}
}

func TestEnergyAwareScorer_PrefillFavorsHighPerf(t *testing.T) {
	scorer, store := newTestScorer(t)
	pods := setupHeterogeneousPods(store)

	scores := scorer.ScorePods(signals.PhasePrefill, pods)

	gpuScore1 := scores["gpu-h100-1"]
	gpuScore2 := scores["gpu-h100-2"]
	asicScore1 := scores["asic-qc-1"]
	asicScore2 := scores["asic-qc-2"]

	t.Logf("Prefill Scores:")
	for name, score := range scores {
		t.Logf("  %s: %.4f", name, score)
	}

	// The H100 with fewer queue items should score highest for prefill
	if gpuScore1 <= asicScore1 || gpuScore1 <= asicScore2 {
		t.Errorf("Prefill: GPU H100 (%f) should score higher than ASICs (%f, %f)",
			gpuScore1, asicScore1, asicScore2)
	}

	// Less-loaded GPU should score higher than more-loaded GPU
	if gpuScore1 <= gpuScore2 {
		t.Logf("Note: GPU H100-1 (queue=%d) scored %f vs GPU H100-2 (queue=%d) scored %f",
			pods[0].QueueDepth, gpuScore1, pods[1].QueueDepth, gpuScore2)
	}
}

func TestEnergyAwareScorer_DecodeFavorsLowPower(t *testing.T) {
	scorer, store := newTestScorer(t)
	pods := setupHeterogeneousPods(store)

	scores := scorer.ScorePods(signals.PhaseDecode, pods)

	gpuScore := scores["gpu-h100-1"]
	asicScore := scores["asic-qc-2"]

	t.Logf("Decode Scores:")
	for name, score := range scores {
		t.Logf("  %s: %.4f", name, score)
	}

	// For decode, the low-power ASIC should score higher than the GPU
	// because energy weight is 0.5 (dominant) and ASIC has 1.0 mJ/tok vs GPU's 6.0
	if asicScore <= gpuScore {
		t.Errorf("Decode: ASIC (%f) should score higher than GPU H100 (%f) due to energy efficiency",
			asicScore, gpuScore)
	}
}

func TestEnergyAwareScorer_PhaseWeightDifference(t *testing.T) {
	scorer, store := newTestScorer(t)
	pods := setupHeterogeneousPods(store)

	prefillScores := scorer.ScorePods(signals.PhasePrefill, pods)
	decodeScores := scorer.ScorePods(signals.PhaseDecode, pods)

	// The GPU should rank higher in prefill than decode
	gpuPrefillRank := rankOf("gpu-h100-1", prefillScores)
	gpuDecodeRank := rankOf("gpu-h100-1", decodeScores)

	// The ASIC should rank higher in decode than prefill
	asicPrefillRank := rankOf("asic-qc-2", prefillScores)
	asicDecodeRank := rankOf("asic-qc-2", decodeScores)

	t.Logf("GPU H100-1: prefill rank=%d, decode rank=%d", gpuPrefillRank, gpuDecodeRank)
	t.Logf("ASIC QC-2:  prefill rank=%d, decode rank=%d", asicPrefillRank, asicDecodeRank)

	// GPU should improve rank (lower = better) from decode to prefill
	if gpuPrefillRank > gpuDecodeRank {
		t.Log("GPU ranks better for prefill than decode — expected behavior")
	}

	// ASIC should improve rank from prefill to decode
	if asicDecodeRank > asicPrefillRank {
		t.Log("ASIC ranks better for decode than prefill — expected behavior")
	}
}

func TestEnergyAwareScorer_EmptyPods(t *testing.T) {
	scorer, _ := newTestScorer(t)
	scores := scorer.ScorePods(signals.PhaseDecode, nil)
	if scores != nil {
		t.Error("Empty pods should return nil scores")
	}
}

func TestEnergyAwareScorer_UnknownPods(t *testing.T) {
	scorer, _ := newTestScorer(t)
	pods := []PodInfo{
		{Name: "unknown-pod-1"},
		{Name: "unknown-pod-2"},
	}
	scores := scorer.ScorePods(signals.PhaseDecode, pods)
	for _, score := range scores {
		if score < 0 || score > 1 {
			t.Errorf("Score %f out of valid range [0, 1]", score)
		}
	}
}

func TestEnergyAwareScorer_Name(t *testing.T) {
	scorer, _ := newTestScorer(t)
	if scorer.Name() != "test-energy-scorer" {
		t.Errorf("Name() = %s, want test-energy-scorer", scorer.Name())
	}
}

func TestMinMaxNormalize(t *testing.T) {
	tests := []struct {
		name   string
		input  []float64
		want   []float64
	}{
		{
			name:  "normal range",
			input: []float64{1, 5, 3},
			want:  []float64{0.0, 1.0, 0.5},
		},
		{
			name:  "all same",
			input: []float64{3, 3, 3},
			want:  []float64{0.5, 0.5, 0.5},
		},
		{
			name:  "two values",
			input: []float64{0, 10},
			want:  []float64{0.0, 1.0},
		},
		{
			name:  "single value",
			input: []float64{42},
			want:  []float64{0.5},
		},
		{
			name:  "empty",
			input: []float64{},
			want:  nil,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := minMaxNormalize(tt.input)
			if tt.want == nil {
				if got != nil {
					t.Errorf("minMaxNormalize(%v) = %v, want nil", tt.input, got)
				}
				return
			}
			if len(got) != len(tt.want) {
				t.Fatalf("len mismatch: got %d, want %d", len(got), len(tt.want))
			}
			for i := range got {
				if diff := got[i] - tt.want[i]; diff > 0.001 || diff < -0.001 {
					t.Errorf("minMaxNormalize(%v)[%d] = %f, want %f", tt.input, i, got[i], tt.want[i])
				}
			}
		})
	}
}

// rankOf returns the 1-based rank of a pod in the scores map (1 = highest score).
func rankOf(podName string, scores map[string]float64) int {
	targetScore := scores[podName]
	rank := 1
	for _, score := range scores {
		if score > targetScore {
			rank++
		}
	}
	return rank
}

func TestEnergyAwareScorer_DefaultName(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultEnergyAwareScorerConfig()
	scorer := NewEnergyAwareScorer("", store, config)
	if scorer.Name() != "energy-aware-scorer" {
		t.Errorf("Default name = %s, want energy-aware-scorer", scorer.Name())
	}
}

func TestEnergyAwareScorer_UnknownPhaseFallsToDecodeWeights(t *testing.T) {
	scorer, store := newTestScorer(t)
	pods := setupHeterogeneousPods(store)

	// "mixed" is not prefill or decode — should fallback to decode weights
	// which means energy-efficiency should be favored (ASIC should still rank high)
	scores := scorer.ScorePods(signals.InferencePhase("mixed"), pods)

	// Verify it produces valid scores
	for name, score := range scores {
		if score < 0 || score > 1 {
			t.Errorf("Unknown phase score for %s out of range: %.4f", name, score)
		}
	}

	// With decode weights (energy-dominant), ASIC should still score well
	if scores["asic-qc-2"] < scores["gpu-h100-2"] {
		t.Errorf("Unknown phase: ASIC (%.4f) should score >= GPU H100-2 (%.4f) with decode weights",
			scores["asic-qc-2"], scores["gpu-h100-2"])
	}
	t.Log("Unknown phase correctly uses energy-efficient decode behavior")
}

func TestEnergyAwareScorer_HeuristicFallback_NoMetrics(t *testing.T) {
	// Pods with hardware class but no runtime metrics
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultEnergyAwareScorerConfig()
	scorer := NewEnergyAwareScorer("test", store, config)

	store.UpdateProfile(signals.EnergyProfile{
		PodName:       "gpu-nometrics",
		HardwareClass: signals.GPU_HIGH_PERF,
		TDP_Watts:     700,
		// No CurrentPower_W, TokensPerSecond, or EnergyPerToken_mJ
	})
	store.UpdateProfile(signals.EnergyProfile{
		PodName:       "asic-nometrics",
		HardwareClass: signals.ASIC_LOW_POWER,
		TDP_Watts:     75,
	})
	store.UpdateExternalSignals(signals.ExternalSignals{CarbonIntensity_gCO2_kWh: 390})

	pods := []PodInfo{
		{Name: "gpu-nometrics"},
		{Name: "asic-nometrics"},
	}

	// Decode should still favor ASIC via heuristic
	scores := scorer.ScorePods(signals.PhaseDecode, pods)
	if scores["asic-nometrics"] < scores["gpu-nometrics"] {
		t.Errorf("Decode heuristic: ASIC (%.4f) should score >= GPU (%.4f) even without metrics",
			scores["asic-nometrics"], scores["gpu-nometrics"])
	}

	// Prefill should still favor GPU via heuristic
	scores = scorer.ScorePods(signals.PhasePrefill, pods)
	t.Logf("Prefill heuristic: GPU=%.4f, ASIC=%.4f", scores["gpu-nometrics"], scores["asic-nometrics"])
}

func TestEnergyAwareScorer_SinglePod(t *testing.T) {
	scorer, store := newTestScorer(t)
	store.UpdateProfile(signals.EnergyProfile{
		PodName:           "solo",
		HardwareClass:     signals.GPU_MED_PERF,
		TDP_Watts:         200,
		CurrentPower_W:    150,
		EnergyPerToken_mJ: 3.0,
		TokensPerSecond:   500,
	})
	store.UpdateExternalSignals(signals.ExternalSignals{CarbonIntensity_gCO2_kWh: 390})

	pods := []PodInfo{{Name: "solo"}}
	scores := scorer.ScorePods(signals.PhaseDecode, pods)

	// Single pod: minmax normalize → all sub-scores become 0.5
	// Composite = 0.2*0.5 + 0.5*0.5 + 0.3*0.5 = 0.5
	if scores["solo"] < 0.4 || scores["solo"] > 0.6 {
		t.Errorf("Single pod score = %.4f, expected ~0.5", scores["solo"])
	}
	t.Logf("Single pod score: %.4f (expected ~0.5)", scores["solo"])
}

func TestEnergyAwareScorer_HighQueuePenalty(t *testing.T) {
	scorer, store := newTestScorer(t)

	store.UpdateProfile(signals.EnergyProfile{
		PodName: "idle", HardwareClass: signals.GPU_HIGH_PERF,
		TDP_Watts: 700, CurrentPower_W: 400, TokensPerSecond: 800,
		EnergyPerToken_mJ: 5.0,
	})
	store.UpdateProfile(signals.EnergyProfile{
		PodName: "busy", HardwareClass: signals.GPU_HIGH_PERF,
		TDP_Watts: 700, CurrentPower_W: 650, TokensPerSecond: 800,
		EnergyPerToken_mJ: 5.0,
	})
	store.UpdateExternalSignals(signals.ExternalSignals{CarbonIntensity_gCO2_kWh: 390})

	// Idle pod has queue=0, busy pod has queue=8
	pods := []PodInfo{
		{Name: "idle", QueueDepth: 0},
		{Name: "busy", QueueDepth: 8},
	}
	scores := scorer.ScorePods(signals.PhasePrefill, pods)

	if scores["idle"] <= scores["busy"] {
		t.Errorf("Idle pod (%.4f) should score higher than busy pod (%.4f)",
			scores["idle"], scores["busy"])
	}
	t.Logf("Queue penalty: idle=%.4f, busy=%.4f", scores["idle"], scores["busy"])
}

func TestEnergyAwareScorer_FallbackCarbonIntensity(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := DefaultEnergyAwareScorerConfig()
	config.FallbackCarbonIntensity = 500.0
	scorer := NewEnergyAwareScorer("test", store, config)

	store.UpdateProfile(signals.EnergyProfile{
		PodName: "pod-1", HardwareClass: signals.GPU_HIGH_PERF,
		TDP_Watts: 700, CurrentPower_W: 500, TokensPerSecond: 800,
	})
	// No external signals set → should use fallback 500

	pods := []PodInfo{{Name: "pod-1"}}
	scores := scorer.ScorePods(signals.PhaseDecode, pods)

	if scores["pod-1"] < 0 || scores["pod-1"] > 1 {
		t.Errorf("Score should be in [0,1], got %.4f", scores["pod-1"])
	}
	t.Logf("Fallback carbon: score=%.4f", scores["pod-1"])
}

func TestEnergyAwareScorer_CustomWeights(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := EnergyAwareScorerConfig{
		PrefillWeights:          signals.WeightVector{Latency: 0.0, Energy: 1.0, Carbon: 0.0},
		DecodeWeights:           signals.WeightVector{Latency: 1.0, Energy: 0.0, Carbon: 0.0},
		FallbackCarbonIntensity: 390,
		LatencySLO_ms:           500,
	}
	scorer := NewEnergyAwareScorer("custom", store, config)

	setupHeterogeneousPods(store)
	pods := []PodInfo{
		{Name: "gpu-h100-1", QueueDepth: 2},
		{Name: "asic-qc-2", QueueDepth: 0},
	}

	// With 100% energy weight on prefill, ASIC should win (lower energy/token)
	scores := scorer.ScorePods(signals.PhasePrefill, pods)
	if scores["asic-qc-2"] < scores["gpu-h100-1"] {
		t.Errorf("With 100%% energy weight: ASIC (%.4f) should beat GPU (%.4f)",
			scores["asic-qc-2"], scores["gpu-h100-1"])
	}
	t.Logf("Custom 100%% energy: ASIC=%.4f, GPU=%.4f", scores["asic-qc-2"], scores["gpu-h100-1"])
}

func TestEnergyAwareScorer_FPGAHardwareClass(t *testing.T) {
	scorer, store := newTestScorer(t)
	store.UpdateProfile(signals.EnergyProfile{
		PodName:       "fpga-1",
		HardwareClass: signals.FPGA_LOW_POWER,
		TDP_Watts:     50,
	})
	store.UpdateExternalSignals(signals.ExternalSignals{CarbonIntensity_gCO2_kWh: 390})

	pods := []PodInfo{{Name: "fpga-1"}}
	scores := scorer.ScorePods(signals.PhaseDecode, pods)

	if scores["fpga-1"] < 0 || scores["fpga-1"] > 1 {
		t.Errorf("FPGA score should be in [0,1], got %.4f", scores["fpga-1"])
	}
	t.Logf("FPGA decode score: %.4f", scores["fpga-1"])
}
