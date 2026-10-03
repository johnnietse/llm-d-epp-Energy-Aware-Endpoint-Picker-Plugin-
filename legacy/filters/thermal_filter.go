// Package filter implements scheduling filters for the energy-aware EPP.
package filter

import (
	"context"
	"fmt"
	"log"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// ThermalThrottlingFilter prevents traffic from being routed to AI pods
// whose bare-metal hardware (GPUs/ASICs) is exceeding safe thermal thresholds.
// This directly addresses Data Center Automation by preventing physical hot spots
// and massive cooling inefficiencies (PUE degradation).
type ThermalThrottlingFilter struct {
	name             string
	store            *signals.EnergyStore
	maxTemperature_C float64
}

// ThermalConfig holds the threshold configuration for the Thermal filter.
type ThermalConfig struct {
	MaxTemperature_C float64 `yaml:"maxTemperatureC"`
}

// DefaultThermalConfig returns the standard 85C throttle threshold.
func DefaultThermalConfig() ThermalConfig {
	return ThermalConfig{
		MaxTemperature_C: 85.0, // Standard NVIDIA GPU soft throttle point
	}
}

// NewThermalThrottlingFilter creates a new thermal filter.
func NewThermalThrottlingFilter(name string, store *signals.EnergyStore, config ThermalConfig) *ThermalThrottlingFilter {
	return &ThermalThrottlingFilter{
		name:             name,
		store:            store,
		maxTemperature_C: config.MaxTemperature_C,
	}
}

// Name returns the plugin name.
func (f *ThermalThrottlingFilter) Name() string {
	return f.name
}

// Filter evaluates whether a pod should be completely excluded from the routing
// decision based on its current bare-metal GPU/ASIC temperature.
func (f *ThermalThrottlingFilter) Filter(ctx context.Context, podName string) (bool, error) {
	profile := f.store.GetProfile(podName)
	if profile == nil {
		// If we don't have telemetry, we fail-open (allow routing)
		// but in a strict bare-metal environment, you might fail-closed.
		return true, nil
	}

	// Check for thermal saturation
	if profile.Temperature_C >= f.maxTemperature_C {
		log.Printf("[ThermalFilter] REJECTING %s: GPU Temperature %.1f°C exceeds %.1f°C safe limit",
			podName, profile.Temperature_C, f.maxTemperature_C)
		return false, fmt.Errorf("thermal saturation: %.1fC >= %.1fC safe limit", 
			profile.Temperature_C, f.maxTemperature_C)
	}

	// Pod is cool enough to accept heavy LLM inference traffic
	return true, nil
}
