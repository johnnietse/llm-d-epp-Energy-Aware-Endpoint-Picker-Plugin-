// Package metrics provides a Prometheus exporter for the energy-aware EPP.
//
// This exporter publishes custom metrics that enable Grafana dashboards
// to visualize real-time:
//   - Per-pod power consumption and energy-per-token
//   - Phase-aware routing decisions (prefill vs decode winners)
//   - Cluster-wide power budget utilization
//   - Grid carbon intensity and per-token carbon footprint
//   - Token economics (kWh/1M, gCO2/1M, $/1M)
//
// Metrics are served at /metrics in the standard Prometheus text format.
// The existing health server at :8080 also serves these via /metrics/prometheus.
package metrics

import (
	"fmt"
	"io"
	"sort"
	"sync"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// PrometheusExporter generates Prometheus text format metrics from the EnergyStore.
type PrometheusExporter struct {
	store *signals.EnergyStore
	mu    sync.Mutex

	// Routing decision counters
	prefillDecisions map[string]int64 // pod name → times chosen for prefill
	decodeDecisions  map[string]int64 // pod name → times chosen for decode
	totalDecisions   int64
}

// NewPrometheusExporter creates a new exporter.
func NewPrometheusExporter(store *signals.EnergyStore) *PrometheusExporter {
	return &PrometheusExporter{
		store:            store,
		prefillDecisions: make(map[string]int64),
		decodeDecisions:  make(map[string]int64),
	}
}

// RecordRoutingDecision records which pod was selected for a given phase.
// Called by the scoring adapter after each scheduling cycle.
func (e *PrometheusExporter) RecordRoutingDecision(phase signals.InferencePhase, podName string) {
	e.mu.Lock()
	defer e.mu.Unlock()

	e.totalDecisions++
	switch phase {
	case signals.PhasePrefill:
		e.prefillDecisions[podName]++
	case signals.PhaseDecode:
		e.decodeDecisions[podName]++
	}
}

// WriteMetrics writes all metrics to the given writer in Prometheus text format.
func (e *PrometheusExporter) WriteMetrics(w io.Writer) {
	e.mu.Lock()
	defer e.mu.Unlock()

	profiles := e.store.GetAllProfiles()
	ext := e.store.GetExternalSignals()
	now := time.Now().UnixMilli()

	// ─── Per-Pod Power Metrics ──────────────────────────────────────
	writeHelp(w, "epp_pod_power_watts", "Current power draw per pod in watts")
	writeType(w, "epp_pod_power_watts", "gauge")
	for _, p := range sortedProfiles(profiles) {
		writeGauge(w, "epp_pod_power_watts", p.CurrentPower_W, now,
			"pod", p.PodName, "hardware_class", string(p.HardwareClass))
	}

	writeHelp(w, "epp_pod_tdp_watts", "Thermal Design Power per pod in watts")
	writeType(w, "epp_pod_tdp_watts", "gauge")
	for _, p := range sortedProfiles(profiles) {
		writeGauge(w, "epp_pod_tdp_watts", p.TDP_Watts, now,
			"pod", p.PodName, "hardware_class", string(p.HardwareClass))
	}

	writeHelp(w, "epp_pod_tdp_utilization_ratio", "Power draw as fraction of TDP (0-1)")
	writeType(w, "epp_pod_tdp_utilization_ratio", "gauge")
	for _, p := range sortedProfiles(profiles) {
		ratio := 0.0
		if p.TDP_Watts > 0 {
			ratio = p.CurrentPower_W / p.TDP_Watts
		}
		writeGauge(w, "epp_pod_tdp_utilization_ratio", ratio, now,
			"pod", p.PodName, "hardware_class", string(p.HardwareClass))
	}

	// ─── Per-Pod Energy Efficiency Metrics ──────────────────────────
	writeHelp(w, "epp_pod_energy_per_token_mj", "Energy per output token in millijoules")
	writeType(w, "epp_pod_energy_per_token_mj", "gauge")
	for _, p := range sortedProfiles(profiles) {
		writeGauge(w, "epp_pod_energy_per_token_mj", p.EnergyPerToken_mJ, now,
			"pod", p.PodName, "hardware_class", string(p.HardwareClass))
	}

	writeHelp(w, "epp_pod_tokens_per_second", "Output token throughput per pod")
	writeType(w, "epp_pod_tokens_per_second", "gauge")
	for _, p := range sortedProfiles(profiles) {
		writeGauge(w, "epp_pod_tokens_per_second", p.TokensPerSecond, now,
			"pod", p.PodName, "hardware_class", string(p.HardwareClass))
	}

	writeHelp(w, "epp_pod_utilization_ratio", "Accelerator utilization per pod (0-1)")
	writeType(w, "epp_pod_utilization_ratio", "gauge")
	for _, p := range sortedProfiles(profiles) {
		writeGauge(w, "epp_pod_utilization_ratio", p.Utilization, now,
			"pod", p.PodName, "hardware_class", string(p.HardwareClass))
	}

	writeHelp(w, "epp_pod_active_requests", "Active requests per pod")
	writeType(w, "epp_pod_active_requests", "gauge")
	for _, p := range sortedProfiles(profiles) {
		writeGauge(w, "epp_pod_active_requests", float64(p.ActiveRequests), now,
			"pod", p.PodName, "hardware_class", string(p.HardwareClass))
	}

	// ─── Token Economics Metrics ────────────────────────────────────
	writeHelp(w, "epp_pod_energy_per_1m_tokens_kwh", "Energy per 1M output tokens in kWh")
	writeType(w, "epp_pod_energy_per_1m_tokens_kwh", "gauge")
	for _, p := range sortedProfiles(profiles) {
		econ := signals.ComputeTokenEconomics(p, ext)
		writeGauge(w, "epp_pod_energy_per_1m_tokens_kwh", econ.EnergyPer1MTokens_kWh, now,
			"pod", p.PodName, "hardware_class", string(p.HardwareClass))
	}

	writeHelp(w, "epp_pod_carbon_per_1m_tokens_gco2", "Carbon per 1M output tokens in gCO2eq")
	writeType(w, "epp_pod_carbon_per_1m_tokens_gco2", "gauge")
	for _, p := range sortedProfiles(profiles) {
		econ := signals.ComputeTokenEconomics(p, ext)
		writeGauge(w, "epp_pod_carbon_per_1m_tokens_gco2", econ.CarbonPer1MTokens_gCO2e, now,
			"pod", p.PodName, "hardware_class", string(p.HardwareClass))
	}

	writeHelp(w, "epp_pod_cost_per_1m_tokens_usd", "Cost per 1M output tokens in USD")
	writeType(w, "epp_pod_cost_per_1m_tokens_usd", "gauge")
	for _, p := range sortedProfiles(profiles) {
		econ := signals.ComputeTokenEconomics(p, ext)
		writeGauge(w, "epp_pod_cost_per_1m_tokens_usd", econ.CostPer1MTokens_USD, now,
			"pod", p.PodName, "hardware_class", string(p.HardwareClass))
	}

	// ─── Cluster-Wide Metrics ───────────────────────────────────────
	writeHelp(w, "epp_cluster_total_power_watts", "Total cluster power draw in watts")
	writeType(w, "epp_cluster_total_power_watts", "gauge")
	writeGaugeSimple(w, "epp_cluster_total_power_watts", e.store.TotalClusterPower(), now)

	writeHelp(w, "epp_cluster_pod_count", "Number of monitored inference pods")
	writeType(w, "epp_cluster_pod_count", "gauge")
	writeGaugeSimple(w, "epp_cluster_pod_count", float64(e.store.PodCount()), now)

	writeHelp(w, "epp_cluster_avg_energy_per_token_mj", "Cluster-wide average energy per token in mJ")
	writeType(w, "epp_cluster_avg_energy_per_token_mj", "gauge")
	avgEPT := computeClusterAvgEPT(profiles)
	writeGaugeSimple(w, "epp_cluster_avg_energy_per_token_mj", avgEPT, now)

	// ─── External Signal Metrics ────────────────────────────────────
	writeHelp(w, "epp_grid_carbon_intensity_gco2_kwh", "Grid carbon intensity in gCO2eq/kWh")
	writeType(w, "epp_grid_carbon_intensity_gco2_kwh", "gauge")
	writeGauge(w, "epp_grid_carbon_intensity_gco2_kwh", ext.CarbonIntensity_gCO2_kWh, now,
		"region", ext.GridRegion)

	writeHelp(w, "epp_electricity_price_usd_kwh", "Electricity price in USD/kWh")
	writeType(w, "epp_electricity_price_usd_kwh", "gauge")
	writeGauge(w, "epp_electricity_price_usd_kwh", ext.ElectricityPrice_USD_kWh, now,
		"region", ext.GridRegion)

	// ─── Routing Decision Counters ──────────────────────────────────
	writeHelp(w, "epp_routing_decisions_total", "Total routing decisions by phase and pod")
	writeType(w, "epp_routing_decisions_total", "counter")
	for pod, count := range e.prefillDecisions {
		writeGauge(w, "epp_routing_decisions_total", float64(count), now,
			"phase", "prefill", "pod", pod)
	}
	for pod, count := range e.decodeDecisions {
		writeGauge(w, "epp_routing_decisions_total", float64(count), now,
			"phase", "decode", "pod", pod)
	}

	writeHelp(w, "epp_routing_decisions_count", "Total number of routing decisions")
	writeType(w, "epp_routing_decisions_count", "counter")
	writeGaugeSimple(w, "epp_routing_decisions_count", float64(e.totalDecisions), now)
}

// ─── Helpers ────────────────────────────────────────────────────────

func writeHelp(w io.Writer, name, help string) {
	fmt.Fprintf(w, "# HELP %s %s\n", name, help)
}

func writeType(w io.Writer, name, typ string) {
	fmt.Fprintf(w, "# TYPE %s %s\n", name, typ)
}

func writeGauge(w io.Writer, name string, value float64, ts int64, labels ...string) {
	labelStr := ""
	for i := 0; i < len(labels)-1; i += 2 {
		if i > 0 {
			labelStr += ","
		}
		labelStr += fmt.Sprintf(`%s="%s"`, labels[i], labels[i+1])
	}
	fmt.Fprintf(w, "%s{%s} %g %d\n", name, labelStr, value, ts)
}

func writeGaugeSimple(w io.Writer, name string, value float64, ts int64) {
	fmt.Fprintf(w, "%s %g %d\n", name, value, ts)
}

func sortedProfiles(profiles map[string]signals.EnergyProfile) []signals.EnergyProfile {
	names := make([]string, 0, len(profiles))
	for name := range profiles {
		names = append(names, name)
	}
	sort.Strings(names)
	sorted := make([]signals.EnergyProfile, 0, len(names))
	for _, name := range names {
		sorted = append(sorted, profiles[name])
	}
	return sorted
}

// computeClusterAvgEPT computes the cluster-wide average energy per token across all pods.
func computeClusterAvgEPT(profiles map[string]signals.EnergyProfile) float64 {
	if len(profiles) == 0 {
		return 0
	}
	sum := 0.0
	count := 0
	for _, p := range profiles {
		if p.EnergyPerToken_mJ > 0 {
			sum += p.EnergyPerToken_mJ
			count++
		}
	}
	if count == 0 {
		return 0
	}
	return sum / float64(count)
}
