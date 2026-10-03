package scorer

import (
	"context"
	"testing"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

func TestRDMALocalityScorer_Score(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)

	// Pod 1: Full RDMA + NUMA Optimized
	store.UpdateProfile(signals.EnergyProfile{
		PodName:        "pod-rdma-numa",
		CurrentPower_W: 700.0,
		HardwareClass:  signals.HardwareClass("gpu-high"),
		HasRDMA:        true,
		NUMAOptimized:  true,
	})

	// Pod 2: RDMA only, not NUMA optimized
	store.UpdateProfile(signals.EnergyProfile{
		PodName:        "pod-rdma-only",
		CurrentPower_W: 700.0,
		HardwareClass:  signals.HardwareClass("gpu-high"),
		HasRDMA:        true,
		NUMAOptimized:  false,
	})

	// Pod 3: No RDMA
	store.UpdateProfile(signals.EnergyProfile{
		PodName:        "pod-no-rdma",
		CurrentPower_W: 200.0,
		HardwareClass:  signals.HardwareClass("gpu-med"),
		HasRDMA:        false,
		NUMAOptimized:  false,
	})

	scorer := NewRDMALocalityScorer("rdma-scorer", store)
	ctx := context.Background()

	tests := []struct {
		name          string
		podName       string
		phase         signals.InferencePhase
		expectedScore float64
	}{
		{
			name:          "Decode with full RDMA and NUMA",
			podName:       "pod-rdma-numa",
			phase:         signals.PhaseDecode,
			expectedScore: 1.0, // 0.2 + 0.5 + 0.3
		},
		{
			name:          "Prefill with full RDMA and NUMA",
			podName:       "pod-rdma-numa",
			phase:         signals.PhasePrefill,
			expectedScore: 0.8, // 1.0 * 0.8
		},
		{
			name:          "Decode with RDMA only",
			podName:       "pod-rdma-only",
			phase:         signals.PhaseDecode,
			expectedScore: 0.7, // 0.2 + 0.5
		},
		{
			name:          "Decode with no RDMA",
			podName:       "pod-no-rdma",
			phase:         signals.PhaseDecode,
			expectedScore: 0.2, // Base score
		},
		{
			name:          "Unknown pod",
			podName:       "pod-unknown",
			phase:         signals.PhaseDecode,
			expectedScore: 0.1, // Lowest baseline
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			score := scorer.Score(ctx, tt.phase, tt.podName)
			// check float equality with small epsilon
			if mathAbs(score-tt.expectedScore) > 0.001 {
				t.Errorf("expected score %.2f, got %.2f", tt.expectedScore, score)
			}
		})
	}
}

func mathAbs(x float64) float64 {
	if x < 0 {
		return -x
	}
	return x
}
