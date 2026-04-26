package scorer

import (
	"testing"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

func TestKVCacheTransferScorer_HighTDP_LowPenalty(t *testing.T) {
	store := signals.NewEnergyStore(30 * time.Second)

	// H100 GPU: 6 mJ/token → request energy = 6 * 512 = 3072 mJ
	// Transfer energy = 640 * 0.8 = 512 mJ → ratio = 512/3072 = 0.167
	store.UpdateProfile(signals.EnergyProfile{
		PodName:           "h100-gpu",
		EnergyPerToken_mJ: 6.0,
		LastUpdated:       time.Now(),
	})

	s := NewKVCacheTransferScorer("kv-transfer", store, DefaultKVCacheTransferScorerConfig())
	scores := s.ScorePods([]PodInfo{{Name: "h100-gpu"}})

	score := scores["h100-gpu"]
	t.Logf("H100 GPU KV-transfer score: %.3f", score)

	// Score should be close to 1.0 (low penalty)
	// 1 - (0.167 * 0.15) = 1 - 0.025 = 0.975
	if score < 0.95 {
		t.Errorf("H100 GPU should have low transfer penalty, got %.3f", score)
	}
}

func TestKVCacheTransferScorer_LowTDP_HighPenalty(t *testing.T) {
	store := signals.NewEnergyStore(30 * time.Second)

	// ASIC: 1 mJ/token → request energy = 1 * 512 = 512 mJ
	// Transfer energy = 512 mJ → ratio = 512/512 = 1.0
	store.UpdateProfile(signals.EnergyProfile{
		PodName:           "asic-pod",
		EnergyPerToken_mJ: 1.0,
		LastUpdated:       time.Now(),
	})

	s := NewKVCacheTransferScorer("kv-transfer", store, DefaultKVCacheTransferScorerConfig())
	scores := s.ScorePods([]PodInfo{{Name: "asic-pod"}})

	score := scores["asic-pod"]
	t.Logf("ASIC KV-transfer score: %.3f", score)

	// Score = 1 - (1.0 * 0.15) = 0.85
	if score > 0.90 {
		t.Errorf("ASIC should have higher transfer penalty, got %.3f", score)
	}
}

func TestKVCacheTransferScorer_ComparativeRanking(t *testing.T) {
	store := signals.NewEnergyStore(30 * time.Second)

	store.UpdateProfile(signals.EnergyProfile{
		PodName: "h100", EnergyPerToken_mJ: 6.0, LastUpdated: time.Now(),
	})
	store.UpdateProfile(signals.EnergyProfile{
		PodName: "a100", EnergyPerToken_mJ: 3.5, LastUpdated: time.Now(),
	})
	store.UpdateProfile(signals.EnergyProfile{
		PodName: "asic", EnergyPerToken_mJ: 1.0, LastUpdated: time.Now(),
	})

	s := NewKVCacheTransferScorer("kv-transfer", store, DefaultKVCacheTransferScorerConfig())
	scores := s.ScorePods([]PodInfo{{Name: "h100"}, {Name: "a100"}, {Name: "asic"}})

	t.Logf("H100: %.3f, A100: %.3f, ASIC: %.3f", scores["h100"], scores["a100"], scores["asic"])

	// H100 should have highest score (lowest penalty)
	if scores["h100"] <= scores["a100"] || scores["a100"] <= scores["asic"] {
		t.Error("Expected order: h100 > a100 > asic")
	}
}

func TestKVCacheTransferScorer_NoTelemetry(t *testing.T) {
	store := signals.NewEnergyStore(30 * time.Second)
	s := NewKVCacheTransferScorer("kv", store, DefaultKVCacheTransferScorerConfig())

	scores := s.ScorePods([]PodInfo{{Name: "unknown-pod"}})
	if scores["unknown-pod"] != 0.5 {
		t.Errorf("Expected 0.5 fallback, got %.3f", scores["unknown-pod"])
	}
}

func TestKVCacheTransferScorer_Custom_TCP_Config(t *testing.T) {
	store := signals.NewEnergyStore(30 * time.Second)

	store.UpdateProfile(signals.EnergyProfile{
		PodName: "gpu", EnergyPerToken_mJ: 6.0, LastUpdated: time.Now(),
	})

	// TCP is ~4x more expensive than RDMA
	tcpConfig := KVCacheTransferScorerConfig{
		TransferEnergy_mJ_per_MB: 3.0,   // TCP
		EstimatedKVCacheSize_MB:  640.0,
		Weight:                   0.15,
	}

	s := NewKVCacheTransferScorer("kv-tcp", store, tcpConfig)
	rdmaScorer := NewKVCacheTransferScorer("kv-rdma", store, DefaultKVCacheTransferScorerConfig())

	tcpScores := s.ScorePods([]PodInfo{{Name: "gpu"}})
	rdmaScores := rdmaScorer.ScorePods([]PodInfo{{Name: "gpu"}})

	t.Logf("TCP score: %.3f, RDMA score: %.3f", tcpScores["gpu"], rdmaScores["gpu"])

	if tcpScores["gpu"] >= rdmaScores["gpu"] {
		t.Error("TCP should have worse (lower) score than RDMA")
	}
}
