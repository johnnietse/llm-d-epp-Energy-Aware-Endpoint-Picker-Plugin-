/*
Copyright 2025 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package energyaware

import (
	"context"
	"testing"
)

func TestNewEnergyAware_DefaultParams(t *testing.T) {
	scorer := NewEnergyAware(context.Background(), parameters{
		PrefillLatencyWeight:    defaultPrefillWtLat,
		PrefillEnergyWeight:     defaultPrefillWtEnergy,
		PrefillCarbonWeight:     defaultPrefillWtCarbon,
		DecodeLatencyWeight:     defaultDecodeWtLat,
		DecodeEnergyWeight:      defaultDecodeWtEnergy,
		DecodeCarbonWeight:      defaultDecodeWtCarbon,
		FallbackCarbonIntensity: defaultCarbonIntensity,
	})

	if scorer == nil {
		t.Fatal("expected non-nil scorer")
	}

	tn := scorer.TypedName()
	if tn.Type != EnergyAwareType {
		t.Errorf("expected type %q, got %q", EnergyAwareType, tn.Type)
	}
}

func TestEnergyAware_ScoreEmpty(t *testing.T) {
	scorer := NewEnergyAware(context.Background(), parameters{
		PrefillLatencyWeight:    defaultPrefillWtLat,
		PrefillEnergyWeight:     defaultPrefillWtEnergy,
		PrefillCarbonWeight:     defaultPrefillWtCarbon,
		DecodeLatencyWeight:     defaultDecodeWtLat,
		DecodeEnergyWeight:      defaultDecodeWtEnergy,
		DecodeCarbonWeight:      defaultDecodeWtCarbon,
		FallbackCarbonIntensity: defaultCarbonIntensity,
	})

	// nil endpoints should return nil
	result := scorer.Score(context.Background(), nil, nil, nil)
	if result != nil {
		t.Errorf("expected nil for empty endpoints, got %v", result)
	}
}

func TestMinMaxNormalize(t *testing.T) {
	tests := []struct {
		name   string
		input  []float64
		expect []float64
	}{
		{
			name:   "empty",
			input:  []float64{},
			expect: nil,
		},
		{
			name:   "all same",
			input:  []float64{5.0, 5.0, 5.0},
			expect: []float64{0.5, 0.5, 0.5},
		},
		{
			name:   "spread",
			input:  []float64{0, 5, 10},
			expect: []float64{0, 0.5, 1.0},
		},
		{
			name:   "reverse",
			input:  []float64{10, 5, 0},
			expect: []float64{1.0, 0.5, 0},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := minMaxNormalize(tt.input)
			if len(result) != len(tt.expect) {
				t.Fatalf("expected length %d, got %d", len(tt.expect), len(result))
			}
			for i := range result {
				if diff := result[i] - tt.expect[i]; diff > 1e-9 || diff < -1e-9 {
					t.Errorf("index %d: expected %.4f, got %.4f", i, tt.expect[i], result[i])
				}
			}
		})
	}
}

func TestLabelFloat(t *testing.T) {
	labels := map[string]string{
		"gpu-power": "250.5",
		"invalid":   "not-a-number",
		"empty":     "",
	}

	if v := labelFloat(labels, "gpu-power"); v != 250.5 {
		t.Errorf("expected 250.5, got %f", v)
	}
	if v := labelFloat(labels, "invalid"); v != 0 {
		t.Errorf("expected 0 for invalid, got %f", v)
	}
	if v := labelFloat(labels, "missing"); v != 0 {
		t.Errorf("expected 0 for missing, got %f", v)
	}
	if v := labelFloat(labels, "empty"); v != 0 {
		t.Errorf("expected 0 for empty, got %f", v)
	}
}

func TestHardwareClassScore(t *testing.T) {
	tests := []struct {
		class    string
		expected float64
	}{
		{"asic-low", 0.95},
		{"fpga-low", 0.90},
		{"gpu-med", 0.60},
		{"gpu-high", 0.30},
		{"unknown", 0.50},
		{"", 0.50},
	}

	for _, tt := range tests {
		t.Run(tt.class, func(t *testing.T) {
			if score := hardwareClassScore(tt.class); score != tt.expected {
				t.Errorf("class %q: expected %.2f, got %.2f", tt.class, tt.expected, score)
			}
		})
	}
}

func TestComputeEnergyScore_WithEPT(t *testing.T) {
	scorer := NewEnergyAware(context.Background(), parameters{
		FallbackCarbonIntensity: defaultCarbonIntensity,
	})

	// Low energy-per-token (efficient) should score higher than high EPT
	labelsEfficient := map[string]string{LabelEnergyPerToken: "1.0"}
	labelsInefficient := map[string]string{LabelEnergyPerToken: "10.0"}

	scoreEfficient := scorer.computeEnergyScore(labelsEfficient)
	scoreInefficient := scorer.computeEnergyScore(labelsInefficient)

	if scoreEfficient <= scoreInefficient {
		t.Errorf("efficient (EPT=1.0 → %.4f) should score higher than inefficient (EPT=10.0 → %.4f)",
			scoreEfficient, scoreInefficient)
	}
}

func TestComputeLatencyScore_HighTDPBetter(t *testing.T) {
	scorer := NewEnergyAware(context.Background(), parameters{})

	// H100 (700W TDP) should score higher than A100-40GB (250W TDP) for latency
	labelsH100 := map[string]string{LabelTDPWatts: "700"}
	labelsA100 := map[string]string{LabelTDPWatts: "250"}

	scoreH100 := scorer.computeLatencyScore(labelsH100, nil)
	scoreA100 := scorer.computeLatencyScore(labelsA100, nil)

	if scoreH100 <= scoreA100 {
		t.Errorf("H100 (TDP=700 → %.4f) should score higher than A100 (TDP=250 → %.4f) for latency",
			scoreH100, scoreA100)
	}
}
