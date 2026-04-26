// Command energy-epp is the main entry point for the Energy-Aware
// Endpoint Picker Plugin binary.
//
// In production, this binary runs as a sidecar or standalone service
// alongside the llm-d inference scheduler. It:
//   1. Initializes the EnergyPluginSuite from YAML config
//   2. Starts background scrapers (DCGM, RAPL, Carbon API)
//   3. Serves health/readiness endpoints on :8080
//   4. Exposes Prometheus metrics on :9090/metrics
//
// For development, it can run in standalone mode to test the scoring
// pipeline with synthetic pod data.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"syscall"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/adaptive"
	"github.com/johnnie/energy-aware-epp/pkg/config"
	"github.com/johnnie/energy-aware-epp/pkg/metrics"
	"github.com/johnnie/energy-aware-epp/pkg/plugins/scorer"
	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

var (
	healthPort = flag.Int("health-port", 8080, "Port for health/readiness endpoints")
	mode       = flag.String("mode", "standalone", "Run mode: 'standalone' (demo) or 'sidecar' (production)")
	region     = flag.String("region", "US-CAL-CISO", "Grid region for carbon intensity API")
	carbonKey  = flag.String("carbon-api-key", "", "API key for CO2signal/ElectricityMaps")
	maxPower   = flag.Float64("max-cluster-power", 2000, "Maximum cluster power budget (watts)")
)

func main() {
	flag.Parse()

	log.Println("╔══════════════════════════════════════════════════════════╗")
	log.Println("║  Energy-Aware Endpoint Picker Plugin for llm-d          ║")
	log.Println("║  Token-Level Routing for Heterogeneous LLM Inference    ║")
	log.Println("╚══════════════════════════════════════════════════════════╝")

	// Build config
	cfg := config.DefaultEnergyConfig()
	cfg.CarbonAPI.Region = *region
	cfg.CarbonAPI.APIKey = *carbonKey
	cfg.Filter.MaxClusterPower_W = *maxPower

	// Initialize the plugin suite
	suite := config.NewEnergyPluginSuite(cfg)
	log.Printf("[Init] Plugin suite created: scorer=%s, filter=%s",
		suite.EnergyScorer.Name(), suite.BudgetFilter.Name())

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	switch *mode {
	case "standalone":
		runStandaloneDemo(ctx, suite)
	case "sidecar":
		runSidecar(ctx, suite)
	default:
		log.Fatalf("Unknown mode: %s (use 'standalone' or 'sidecar')", *mode)
	}
}

// runStandaloneDemo runs a self-contained demo that simulates a heterogeneous
// cluster and demonstrates the energy-aware scoring difference between
// Prefill and Decode phases. Useful for development and thesis demos.
func runStandaloneDemo(ctx context.Context, suite *config.EnergyPluginSuite) {
	log.Println("[Demo] Running standalone demo with synthetic pod data...")

	// Populate synthetic profiles (matching hardware_profiles.yaml)
	synthProfiles := []signals.EnergyProfile{
		{PodName: "gpu-h100-1", HardwareClass: signals.GPU_HIGH_PERF, TDP_Watts: 700, CurrentPower_W: 550, EnergyPerToken_mJ: 6.0, TokensPerSecond: 800, Utilization: 0.78, ActiveRequests: 5},
		{PodName: "gpu-h100-2", HardwareClass: signals.GPU_HIGH_PERF, TDP_Watts: 700, CurrentPower_W: 600, EnergyPerToken_mJ: 6.5, TokensPerSecond: 750, Utilization: 0.85, ActiveRequests: 8},
		{PodName: "gpu-a100-cap", HardwareClass: signals.GPU_MED_PERF, TDP_Watts: 200, CurrentPower_W: 160, EnergyPerToken_mJ: 2.5, TokensPerSecond: 600, Utilization: 0.80, ActiveRequests: 6},
		{PodName: "asic-qc-1", HardwareClass: signals.ASIC_LOW_POWER, TDP_Watts: 75, CurrentPower_W: 55, EnergyPerToken_mJ: 1.0, TokensPerSecond: 420, Utilization: 0.73, ActiveRequests: 3},
		{PodName: "asic-qc-2", HardwareClass: signals.ASIC_LOW_POWER, TDP_Watts: 75, CurrentPower_W: 50, EnergyPerToken_mJ: 0.9, TokensPerSecond: 400, Utilization: 0.67, ActiveRequests: 2},
	}
	for _, p := range synthProfiles {
		suite.Store.UpdateProfile(p)
	}

	suite.Store.UpdateExternalSignals(signals.ExternalSignals{
		CarbonIntensity_gCO2_kWh: 390, ElectricityPrice_USD_kWh: 0.10, GridRegion: "US-CAL-CISO",
	})

	// Build PodInfo list
	pods := make([]scorer.PodInfo, len(synthProfiles))
	for i, p := range synthProfiles {
		pods[i] = scorer.PodInfo{
			Name:       p.PodName,
			Labels:     map[string]string{"llm-d.ai/hardware-class": string(p.HardwareClass)},
			QueueDepth: p.ActiveRequests,
		}
	}

	// ─── Score for Prefill ──────────────────────────────────────────
	fmt.Println()
	fmt.Println("┌──────────────────────────────────────────────────────────┐")
	fmt.Println("│                 PREFILL SCORING RESULTS                  │")
	fmt.Println("├──────────────────┬──────────┬─────────┬────────┬────────┤")
	fmt.Println("│ Pod              │ Class    │ Power W │ mJ/tok │ Score  │")
	fmt.Println("├──────────────────┼──────────┼─────────┼────────┼────────┤")

	prefillScores := suite.EnergyScorer.ScorePods(signals.PhasePrefill, pods)
	sortedNames := sortByScore(prefillScores)
	for _, name := range sortedNames {
		p := suite.Store.GetProfile(name)
		fmt.Printf("│ %-16s │ %-8s │ %5.0f   │ %5.1f  │ %.4f │\n",
			name, shortClass(p.HardwareClass), p.CurrentPower_W, p.EnergyPerToken_mJ, prefillScores[name])
	}
	fmt.Println("└──────────────────┴──────────┴─────────┴────────┴────────┘")
	fmt.Printf("  → Prefill winner: %s\n", sortedNames[0])

	// ─── Score for Decode ───────────────────────────────────────────
	fmt.Println()
	fmt.Println("┌──────────────────────────────────────────────────────────┐")
	fmt.Println("│                  DECODE SCORING RESULTS                  │")
	fmt.Println("├──────────────────┬──────────┬─────────┬────────┬────────┤")
	fmt.Println("│ Pod              │ Class    │ Power W │ mJ/tok │ Score  │")
	fmt.Println("├──────────────────┼──────────┼─────────┼────────┼────────┤")

	decodeScores := suite.EnergyScorer.ScorePods(signals.PhaseDecode, pods)
	sortedNames = sortByScore(decodeScores)
	for _, name := range sortedNames {
		p := suite.Store.GetProfile(name)
		fmt.Printf("│ %-16s │ %-8s │ %5.0f   │ %5.1f  │ %.4f │\n",
			name, shortClass(p.HardwareClass), p.CurrentPower_W, p.EnergyPerToken_mJ, decodeScores[name])
	}
	fmt.Println("└──────────────────┴──────────┴─────────┴────────┴────────┘")
	fmt.Printf("  → Decode winner: %s\n", sortedNames[0])

	// ─── Token Economics Comparison ─────────────────────────────────
	fmt.Println()
	fmt.Println("┌──────────────────────────────────────────────────────────┐")
	fmt.Println("│              TOKEN ECONOMICS COMPARISON                  │")
	fmt.Println("├──────────────────┬──────────┬──────────┬────────────────┤")
	fmt.Println("│ Pod              │ kWh/1M   │ gCO2/1M  │ Cost $/1M     │")
	fmt.Println("├──────────────────┼──────────┼──────────┼────────────────┤")

	ext := suite.Store.GetExternalSignals()
	for _, name := range sortedNames {
		p := suite.Store.GetProfile(name)
		econ := signals.ComputeTokenEconomics(*p, ext)
		fmt.Printf("│ %-16s │ %7.4f  │ %7.2f  │ $%-12.4f │\n",
			name, econ.EnergyPer1MTokens_kWh, econ.CarbonPer1MTokens_gCO2e, econ.CostPer1MTokens_USD)
	}
	fmt.Println("└──────────────────┴──────────┴──────────┴────────────────┘")

	// Output as JSON for programmatic consumption
	result := map[string]interface{}{
		"prefill_scores": prefillScores,
		"decode_scores":  decodeScores,
		"cluster_power":  suite.Store.TotalClusterPower(),
		"pod_count":      suite.Store.PodCount(),
	}
	jsonBytes, _ := json.MarshalIndent(result, "", "  ")
	fmt.Printf("\nJSON output:\n%s\n", string(jsonBytes))
}

// runSidecar starts the production sidecar mode with scrapers and health endpoints.
func runSidecar(ctx context.Context, suite *config.EnergyPluginSuite) {
	log.Println("[Sidecar] Starting production mode...")

	// Start carbon API scraper
	suite.CarbonScraper.Start(ctx)
	log.Println("[Sidecar] Carbon API scraper started")

	// Start adaptive weight controller
	adaptCfg := adaptive.DefaultAdaptiveConfig()
	adaptCfg.MaxClusterPower_W = *maxPower
	adaptCtrl := adaptive.NewAdaptiveController(
		suite.Store,
		adaptCfg,
		func(prefill, decode signals.WeightVector) {
			// In a full integration, this would update the scorer's weights.
			// For now, log the transitions for observability.
			log.Printf("[Adaptive] Weights updated: prefill=L%.2f/E%.2f/C%.2f, decode=L%.2f/E%.2f/C%.2f",
				prefill.Latency, prefill.Energy, prefill.Carbon,
				decode.Latency, decode.Energy, decode.Carbon)
		},
	)
	adaptCtrl.Start(ctx)
	log.Printf("[Sidecar] Adaptive controller started (mode=%s)", adaptCtrl.CurrentMode())

	// Initialize Prometheus exporter
	exporter := metrics.NewPrometheusExporter(suite.Store)
	log.Println("[Sidecar] Prometheus exporter initialized")

	// Note: DCGM scraper needs pod endpoints from K8s discovery.
	log.Println("[Sidecar] DCGM scraper ready - awaiting pod endpoint discovery")

	// Health/readiness server
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		snap := adaptCtrl.CurrentSnapshot()
		fmt.Fprintf(w, `{"status":"ok","pods":%d,"clusterPowerW":%.1f,"mode":"%s","stale":%d}`,
			suite.Store.PodCount(), suite.Store.TotalClusterPower(),
			adaptCtrl.CurrentMode(), suite.Store.StaleCount())
		_ = snap // used for future expansion
	})
	mux.HandleFunc("/readyz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, `{"ready":true}`)
	})
	mux.HandleFunc("/metrics/energy", func(w http.ResponseWriter, r *http.Request) {
		profiles := suite.Store.GetAllProfiles()
		ext := suite.Store.GetExternalSignals()
		w.Header().Set("Content-Type", "application/json")
		result := map[string]interface{}{
			"profiles":        profiles,
			"externalSignals": ext,
			"clusterPowerW":   suite.Store.TotalClusterPower(),
			"adaptiveMode":    adaptCtrl.CurrentMode(),
		}
		json.NewEncoder(w).Encode(result)
	})
	mux.HandleFunc("/metrics/prometheus", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
		exporter.WriteMetrics(w)
	})

	server := &http.Server{
		Addr:    fmt.Sprintf(":%d", *healthPort),
		Handler: mux,
	}

	go func() {
		log.Printf("[Sidecar] Health server listening on :%d", *healthPort)
		log.Printf("[Sidecar] Endpoints: /healthz, /readyz, /metrics/energy, /metrics/prometheus")
		if err := server.ListenAndServe(); err != http.ErrServerClosed {
			log.Fatalf("Health server error: %v", err)
		}
	}()

	// Wait for shutdown signal
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	<-sigCh

	log.Println("[Sidecar] Shutting down...")
	adaptCtrl.Stop()
	suite.CarbonScraper.Stop()
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer shutdownCancel()
	server.Shutdown(shutdownCtx)
	log.Println("[Sidecar] Shutdown complete")
}

// sortByScore returns pod names sorted by score (descending).
func sortByScore(scores map[string]float64) []string {
	names := make([]string, 0, len(scores))
	for name := range scores {
		names = append(names, name)
	}
	sort.Slice(names, func(i, j int) bool {
		return scores[names[i]] > scores[names[j]]
	})
	return names
}

// shortClass returns a short display name for a hardware class.
func shortClass(class signals.HardwareClass) string {
	switch class {
	case signals.GPU_HIGH_PERF:
		return "GPU-HI"
	case signals.GPU_MED_PERF:
		return "GPU-MED"
	case signals.ASIC_LOW_POWER:
		return "ASIC-LP"
	case signals.FPGA_LOW_POWER:
		return "FPGA-LP"
	default:
		return "UNKNOWN"
	}
}
