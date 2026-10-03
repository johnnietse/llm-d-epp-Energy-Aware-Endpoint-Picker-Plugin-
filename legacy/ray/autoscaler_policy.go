// Package ray provides custom autoscaling policies for Ray and KubeRay clusters.
package ray

import (
	"log"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// EnergyAwareRayAutoscaler integrates the EPP logic into Ray Clusters.
// KubeRay typically scales based on pending Ray tasks (e.g., vLLM actors).
// This policy modifies the scale-up decisions to strictly prefer ASIC-based
// Ray worker nodes when the workload is purely decode/memory bound and 
// carbon intensity is high.
type EnergyAwareRayAutoscaler struct {
	store *signals.EnergyStore
}

// NewEnergyAwareRayAutoscaler creates the Ray autoscaler adapter.
func NewEnergyAwareRayAutoscaler(store *signals.EnergyStore) *EnergyAwareRayAutoscaler {
	return &EnergyAwareRayAutoscaler{store: store}
}

// ShouldScaleUp intercepts KubeRay scale-up decisions.
// Returns false if the scale-up should be blocked due to grid constraints.
func (r *EnergyAwareRayAutoscaler) ShouldScaleUp(workerGroupName string, phase signals.InferencePhase) bool {
	ext := r.store.GetExternalSignals()
	
	// Carbon-Aware AI Infrastructure Logic:
	// If Grid Carbon Intensity is extremely high (e.g., > 400 gCO2/kWh), we suppress
	// scale-ups of power-hungry GPU_HIGH_PERF worker groups for Decode phases,
	// forcing the Ray cluster to queue tasks until ASIC workers scale up instead.
	if ext.CarbonIntensity_gCO2_kWh > 400.0 && phase == signals.PhaseDecode {
		if workerGroupName == "gpu-h100-workers" || workerGroupName == "gpu-a100-workers" {
			log.Printf("[KubeRay-Policy] BLOCKING scale-up of %s: High Carbon Intensity (%.1f gCO2/kWh) restricts decode scaling to ASIC workers.", 
				workerGroupName, ext.CarbonIntensity_gCO2_kWh)
			return false
		}
	}
	
	return true
}
