// Package scorer implements scheduling scorers for the EPP pipeline.
package scorer

import (
	"context"
	"math"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// RDMALocalityScorer boosts the scheduling score of pods that reside on bare-metal
// nodes equipped with GPU Direct RDMA, InfiniBand, and optimal NUMA pinning.
// 
// This directly addresses the High-Performance Networking requirement. In distributed
// LLM inference (tensor parallel or pipeline parallel setups), KV-cache transfers
// and weight synchronization across nodes are heavily bottlenecked by standard 
// TCP/IP ethernet stacks. RDMA completely bypasses the CPU for memory transfers.
type RDMALocalityScorer struct {
	name  string
	store *signals.EnergyStore
}

// NewRDMALocalityScorer creates a new scorer for network topology.
func NewRDMALocalityScorer(name string, store *signals.EnergyStore) *RDMALocalityScorer {
	return &RDMALocalityScorer{
		name:  name,
		store: store,
	}
}

// Name returns the plugin name.
func (s *RDMALocalityScorer) Name() string {
	return s.name
}

// Score assigns a score between 0.0 and 1.0 based on network locality hardware.
// A score of 1.0 means perfect InfiniBand and NUMA locality.
func (s *RDMALocalityScorer) Score(ctx context.Context, phase signals.InferencePhase, podName string) float64 {
	profile := s.store.GetProfile(podName)
	if profile == nil {
		return 0.1 // No telemetry, lowest baseline score
	}

	score := 0.2 // Base score for standard ethernet (RoCE fallback)

	// GPU Direct RDMA / InfiniBand enables direct memory access without CPU interrupts
	if profile.HasRDMA {
		score += 0.5
	}

	// NUMA optimization ensures the Network Interface Card (NIC) and the GPU 
	// are on the exact same PCIe root complex, minimizing QPI/UPI cross-talk latency.
	if profile.NUMAOptimized {
		score += 0.3
	}

	// Phase awareness implementation:
	// Prefill (Compute-bound) relies slightly less on inter-node KV-cache
	// transfer than Decode (Memory-bound) does in distributed AI clusters.
	// Therefore, RDMA is extremely critical during Decode token generation.
	if phase == signals.PhasePrefill {
		// Compress the RDMA score advantage for Prefill, as raw FLOPS matter
		// slightly more than network latency for the initial prompt processing.
		score = math.Min(1.0, score * 0.8) 
	}

	return math.Min(1.0, score)
}
