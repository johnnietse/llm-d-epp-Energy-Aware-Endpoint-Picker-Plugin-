package metrics

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

func TestPrometheusExporter_WriteMetrics(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)

	// Populate store
	store.UpdateProfile(signals.EnergyProfile{
		PodName:           "gpu-h100",
		HardwareClass:     signals.GPU_HIGH_PERF,
		TDP_Watts:         700,
		CurrentPower_W:    550,
		EnergyPerToken_mJ: 6.0,
		TokensPerSecond:   800,
		Utilization:       0.78,
		ActiveRequests:    5,
	})
	store.UpdateProfile(signals.EnergyProfile{
		PodName:           "asic-qc",
		HardwareClass:     signals.ASIC_LOW_POWER,
		TDP_Watts:         75,
		CurrentPower_W:    55,
		EnergyPerToken_mJ: 1.0,
		TokensPerSecond:   400,
		Utilization:       0.67,
		ActiveRequests:    3,
	})
	store.UpdateExternalSignals(signals.ExternalSignals{
		CarbonIntensity_gCO2_kWh: 390,
		ElectricityPrice_USD_kWh: 0.10,
		GridRegion:               "US-CAL-CISO",
	})

	exporter := NewPrometheusExporter(store)

	// Record some routing decisions
	exporter.RecordRoutingDecision(signals.PhasePrefill, "gpu-h100")
	exporter.RecordRoutingDecision(signals.PhasePrefill, "gpu-h100")
	exporter.RecordRoutingDecision(signals.PhaseDecode, "asic-qc")
	exporter.RecordRoutingDecision(signals.PhaseDecode, "asic-qc")
	exporter.RecordRoutingDecision(signals.PhaseDecode, "asic-qc")

	// Write metrics
	var buf bytes.Buffer
	exporter.WriteMetrics(&buf)
	output := buf.String()

	// Verify key metrics exist
	requiredMetrics := []string{
		"epp_pod_power_watts",
		"epp_pod_tdp_watts",
		"epp_pod_tdp_utilization_ratio",
		"epp_pod_energy_per_token_mj",
		"epp_pod_tokens_per_second",
		"epp_pod_utilization_ratio",
		"epp_pod_active_requests",
		"epp_pod_energy_per_1m_tokens_kwh",
		"epp_pod_carbon_per_1m_tokens_gco2",
		"epp_pod_cost_per_1m_tokens_usd",
		"epp_cluster_total_power_watts",
		"epp_cluster_pod_count",
		"epp_grid_carbon_intensity_gco2_kwh",
		"epp_electricity_price_usd_kwh",
		"epp_routing_decisions_total",
		"epp_routing_decisions_count",
	}

	for _, metric := range requiredMetrics {
		if !strings.Contains(output, metric) {
			t.Errorf("Missing metric: %s", metric)
		}
	}

	// Verify GPU pod data appears
	if !strings.Contains(output, `pod="gpu-h100"`) {
		t.Error("Missing gpu-h100 pod label")
	}
	if !strings.Contains(output, `pod="asic-qc"`) {
		t.Error("Missing asic-qc pod label")
	}

	// Verify routing decisions
	if !strings.Contains(output, `phase="prefill"`) {
		t.Error("Missing prefill routing decision")
	}
	if !strings.Contains(output, `phase="decode"`) {
		t.Error("Missing decode routing decision")
	}

	// Verify specific values
	if !strings.Contains(output, "550") {
		t.Error("Missing GPU power value 550")
	}
	if !strings.Contains(output, "55") {
		t.Error("Missing ASIC power value 55")
	}

	// Count total HELP lines
	helpCount := strings.Count(output, "# HELP")
	if helpCount < 14 {
		t.Errorf("Expected at least 14 HELP lines, got %d", helpCount)
	}

	t.Logf("Prometheus output: %d bytes, %d metric families", len(output), helpCount)
}

func TestPrometheusExporter_RoutingDecisionCounting(t *testing.T) {
	store := signals.NewEnergyStore(10 * time.Second)
	exporter := NewPrometheusExporter(store)

	// Simulate 100 routing decisions: 70% decode → ASIC, 30% prefill → GPU
	for i := 0; i < 70; i++ {
		exporter.RecordRoutingDecision(signals.PhaseDecode, "asic-qc")
	}
	for i := 0; i < 30; i++ {
		exporter.RecordRoutingDecision(signals.PhasePrefill, "gpu-h100")
	}

	if exporter.totalDecisions != 100 {
		t.Errorf("Expected 100 total decisions, got %d", exporter.totalDecisions)
	}
	if exporter.prefillDecisions["gpu-h100"] != 30 {
		t.Errorf("Expected 30 prefill decisions for GPU, got %d", exporter.prefillDecisions["gpu-h100"])
	}
	if exporter.decodeDecisions["asic-qc"] != 70 {
		t.Errorf("Expected 70 decode decisions for ASIC, got %d", exporter.decodeDecisions["asic-qc"])
	}

	t.Logf("Routing: %d prefill->GPU, %d decode->ASIC (total %d)",
		exporter.prefillDecisions["gpu-h100"],
		exporter.decodeDecisions["asic-qc"],
		exporter.totalDecisions)
}
