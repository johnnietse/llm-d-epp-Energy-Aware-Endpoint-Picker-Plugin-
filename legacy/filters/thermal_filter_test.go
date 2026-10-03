package filter

import (
	"context"
	"testing"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

func TestThermalThrottlingFilter_Filter(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)

	// Pod 1: Cool GPU
	store.UpdateProfile(signals.EnergyProfile{
		PodName:        "pod-cool",
		CurrentPower_W: 300.0,
		HardwareClass:  signals.HardwareClass("gpu-high"),
		Temperature_C:  65.0,
	})

	// Pod 2: Hot GPU (exceeds threshold)
	store.UpdateProfile(signals.EnergyProfile{
		PodName:        "pod-hot",
		CurrentPower_W: 700.0,
		HardwareClass:  signals.HardwareClass("gpu-high"),
		Temperature_C:  88.0,
	})

	// Pod 3: Edge case GPU (exactly at threshold)
	store.UpdateProfile(signals.EnergyProfile{
		PodName:        "pod-edge",
		CurrentPower_W: 600.0,
		HardwareClass:  signals.HardwareClass("gpu-high"),
		Temperature_C:  85.0,
	})

	config := ThermalConfig{MaxTemperature_C: 85.0}
	filter := NewThermalThrottlingFilter("thermal-filter", store, config)
	ctx := context.Background()

	tests := []struct {
		name        string
		podName     string
		expectAllow bool
	}{
		{
			name:        "Cool pod should be allowed",
			podName:     "pod-cool",
			expectAllow: true,
		},
		{
			name:        "Hot pod should be rejected",
			podName:     "pod-hot",
			expectAllow: false,
		},
		{
			name:        "Pod at exact threshold should be rejected",
			podName:     "pod-edge",
			expectAllow: false,
		},
		{
			name:        "Unknown pod should fail-open",
			podName:     "pod-unknown",
			expectAllow: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			allowed, err := filter.Filter(ctx, tt.podName)
			if allowed != tt.expectAllow {
				t.Errorf("expected allowed %v, got %v", tt.expectAllow, allowed)
			}
			if !tt.expectAllow && err == nil {
				t.Errorf("expected error when rejected, got nil")
			}
		})
	}
}
