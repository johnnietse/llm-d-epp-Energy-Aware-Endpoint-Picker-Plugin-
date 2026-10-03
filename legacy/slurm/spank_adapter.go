// Package slurm provides an adapter for integrating the Energy-Aware logic
// with the Slurm workload manager via SPANK (Slurm Plugin Architecture).
package slurm

import (
	"fmt"
	"log"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// SpankEnergyPlugin allows Slurm to make energy-aware bare-metal node allocations.
// In traditional HPC, Slurm schedules jobs purely based on CPU/GPU availability.
// This plugin forces Slurm to select nodes with the lowest Carbon Intensity
// or best Thermal profile, bridging modern AI telemetry into classic HPC environments.
type SpankEnergyPlugin struct {
	store *signals.EnergyStore
}

// NewSpankEnergyPlugin creates a new adapter.
func NewSpankEnergyPlugin(store *signals.EnergyStore) *SpankEnergyPlugin {
	return &SpankEnergyPlugin{store: store}
}

// EvaluateNode evaluates a bare-metal Slurm node's energy profile.
// Returns a node weight modifier (in Slurm topology, lower weight = higher priority).
func (p *SpankEnergyPlugin) EvaluateNode(nodeName string) (int32, error) {
	profile := p.store.GetProfile(nodeName)
	if profile == nil {
		// Failsafe: if no bare-metal telemetry exists, apply maximum penalty
		// to avoid blindly routing jobs to unmonitored hardware.
		return 1000, fmt.Errorf("no energy telemetry for bare-metal node %s", nodeName)
	}

	// Base weight based on real-time Power consumption.
	// E.g., 400W -> weight of 40
	weight := int32(profile.CurrentPower_W / 10.0) 
	
	// Thermal penalty: heavily penalize nodes nearing thermal saturation
	// to optimize Data Center PUE and prevent throttling during long Slurm jobs.
	if profile.Temperature_C > 80.0 {
		weight += 500 // Massive penalty for physically hot nodes
	}

	log.Printf("[Slurm-SPANK-Adapter] Node %s evaluated. Power: %.1fW, Temp: %.1fC -> Final Slurm Weight: %d", 
		nodeName, profile.CurrentPower_W, profile.Temperature_C, weight)

	return weight, nil
}
