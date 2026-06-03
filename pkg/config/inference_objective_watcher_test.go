package config

import (
	"context"
	"testing"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/adaptive"
	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

func TestObjectiveWatcher_handleObjectiveChange(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := adaptive.DefaultAdaptiveConfig()
	controller := adaptive.NewAdaptiveController(store, config, nil)

	watcher := NewObjectiveWatcher(controller)

	tests := []struct {
		name         string
		goal         string
		expectedMode adaptive.Mode
	}{
		{
			name:         "Carbon Minimization Objective",
			goal:         "CarbonMinimization",
			expectedMode: adaptive.ModeCarbonHigh,
		},
		{
			name:         "Latency Objective",
			goal:         "Latency",
			expectedMode: adaptive.ModeNormal,
		},
		{
			name:         "Cost Reduction Objective",
			goal:         "CostReduction",
			expectedMode: adaptive.ModeLoadShed,
		},
		{
			name:         "Unknown Objective should not change state",
			goal:         "UnknownMagic",
			expectedMode: adaptive.ModeLoadShed, // will remain in previous state
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			obj := &InferenceObjective{}
			obj.Spec.PrimaryGoal = tt.goal

			watcher.handleObjectiveChange(obj)

			currentMode := controller.CurrentMode()
			if currentMode != tt.expectedMode {
				t.Errorf("expected mode %v after applying %s, got %v", tt.expectedMode, tt.goal, currentMode)
			}
		})
	}
}

func TestObjectiveWatcher_Start(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	config := adaptive.DefaultAdaptiveConfig()
	controller := adaptive.NewAdaptiveController(store, config, nil)

	watcher := NewObjectiveWatcher(controller)
	ctx := context.Background()

	// Ensure Start doesn't panic
	watcher.Start(ctx)
}
