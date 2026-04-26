package scorer

import (
	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// KVCacheTransferScorerConfig holds parameters for the KV-cache transfer
// energy cost model. This scorer penalizes pods that require cross-node
// KV-cache migration in disaggregated prefill/decode architectures.
//
// From Splitwise (ISCA '24) and Mooncake research:
//   - RDMA transfers consume ~0.5-2 mJ per MB depending on fabric
//   - PCIe transfers consume ~3-5 mJ per MB
//   - Within-node (GPU-GPU via NVLink) is negligible
//
// This scorer adds an energy penalty proportional to estimated transfer
// volume, encouraging the scheduler to colocate related phases.
type KVCacheTransferScorerConfig struct {
	// TransferEnergy_mJ_per_MB is the energy cost of transferring 1 MB
	// of KV-cache data between nodes. Depends on interconnect:
	//   RDMA (InfiniBand):  ~0.8 mJ/MB
	//   TCP/Ethernet:       ~3.0 mJ/MB
	//   NVLink (in-node):   ~0.1 mJ/MB
	TransferEnergy_mJ_per_MB float64 `yaml:"transferEnergyMjPerMb"`

	// EstimatedKVCacheSize_MB is the estimated KV-cache size for a
	// single request. Depends on model and context length:
	//   Llama3-70B, 4096 ctx → ~640 MB
	//   Llama3-7B, 4096 ctx  → ~128 MB
	EstimatedKVCacheSize_MB float64 `yaml:"estimatedKvCacheSizeMb"`

	// Weight is the scorer weight (0-1) in the aggregate score.
	Weight float64 `yaml:"weight"`
}

// DefaultKVCacheTransferScorerConfig returns defaults based on
// RDMA transfers for Llama3-70B.
func DefaultKVCacheTransferScorerConfig() KVCacheTransferScorerConfig {
	return KVCacheTransferScorerConfig{
		TransferEnergy_mJ_per_MB: 0.8,   // RDMA InfiniBand
		EstimatedKVCacheSize_MB:  640.0,  // 70B model, 4k context
		Weight:                   0.15,   // moderate penalty
	}
}

// KVCacheTransferScorer penalizes pods that would require cross-node
// KV-cache transfer in disaggregated serving.
//
// The score is based on the estimated transfer energy cost relative
// to the pod's per-token energy. Pods with higher per-token energy
// (high TDP) are less penalized since the transfer cost is a smaller
// fraction of their total energy budget.
type KVCacheTransferScorer struct {
	name   string
	store  *signals.EnergyStore
	config KVCacheTransferScorerConfig
}

// NewKVCacheTransferScorer creates a new KV-cache transfer energy scorer.
func NewKVCacheTransferScorer(
	name string,
	store *signals.EnergyStore,
	config KVCacheTransferScorerConfig,
) *KVCacheTransferScorer {
	if name == "" {
		name = "kv-cache-transfer-scorer"
	}
	return &KVCacheTransferScorer{name: name, store: store, config: config}
}

// Name returns the scorer name.
func (s *KVCacheTransferScorer) Name() string { return s.name }

// ScorePods calculates transfer energy penalty for each pod.
// Returns scores in [0, 1] where 1 = lowest transfer cost (best).
//
// The penalty model:
//   transferEnergy = kvCacheSize_MB × transferCost_mJ_per_MB
//   transferRatio  = transferEnergy / (tokenEnergy_mJ × estimatedTokens)
//   score          = 1 - clamp(transferRatio, 0, 1)
//
// Pods with low per-token energy are penalized more because the transfer
// cost is a larger fraction of their total energy budget.
func (s *KVCacheTransferScorer) ScorePods(pods []PodInfo) map[string]float64 {
	scores := make(map[string]float64, len(pods))
	if len(pods) == 0 {
		return scores
	}

	transferEnergy_mJ := s.config.EstimatedKVCacheSize_MB * s.config.TransferEnergy_mJ_per_MB

	for _, pod := range pods {
		profile := s.store.GetProfile(pod.Name)
		if profile == nil {
			scores[pod.Name] = 0.5 // neutral fallback
			continue
		}

		if profile.EnergyPerToken_mJ <= 0 {
			scores[pod.Name] = 0.5
			continue
		}

		// Estimate tokens per request (assume ~512 output tokens)
		estimatedOutputTokens := 512.0
		requestEnergy_mJ := profile.EnergyPerToken_mJ * estimatedOutputTokens

		// Transfer cost as fraction of request energy
		// Lower ratio → transfer is negligible → higher score
		transferRatio := transferEnergy_mJ / requestEnergy_mJ
		if transferRatio > 1.0 {
			transferRatio = 1.0
		}

		// Invert: lower transfer cost → higher score
		scores[pod.Name] = 1.0 - (transferRatio * s.config.Weight)
	}

	return scores
}
