// Package config provides the plugin registration and configuration layer
// that bridges our energy-aware plugins with the llm-d EPP framework.
//
// This package defines:
//   - EnergyConfig: Master configuration for all energy plugins
//   - Factory functions: Follow the llm-d plugin registration pattern
//   - GIE adapters: Thin wrappers that translate our plugin interfaces
//     to the llm-d/GIE Filter/Scorer interfaces
//
// The llm-d EPP plugin interfaces (from Gateway API Inference Extension):
//
//	Filter(ctx, cycleState, request, pods) []Pod
//	Score(ctx, cycleState, request, pod) (int64, error)
//
// Our plugins use abstract types (PodInfo/PodCandidate) for testability.
// The adapters in this package translate between GIE types and ours.
package config

import (
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/plugins/filter"
	"github.com/johnnie/energy-aware-epp/pkg/plugins/scorer"
	"github.com/johnnie/energy-aware-epp/pkg/plugins/scraper"
	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// EnergyConfig is the master configuration for all energy-aware components.
// It configures the scorer, filter, scrapers, and external API clients.
type EnergyConfig struct {
	// ─── Plugin Settings ──────────────────────────────────────────────
	Scorer       scorer.EnergyAwareScorerConfig    `yaml:"scorer"`
	Filter       filter.EnergyBudgetFilterConfig   `yaml:"filter"`
	CarbonScorer scorer.CarbonIntensityScorerConfig `yaml:"carbonScorer"`

	// ─── Scraper Settings ─────────────────────────────────────────────
	DCGMScraper  scraper.DCGMScraperConfig       `yaml:"dcgmScraper"`
	RAPLScraper  scraper.RAPLScraperConfig       `yaml:"raplScraper"`
	CarbonAPI    scraper.CarbonAPIScraperConfig   `yaml:"carbonApi"`

	// ─── Store Settings ───────────────────────────────────────────────
	StaleDuration time.Duration `yaml:"staleDuration"`
}

// DefaultEnergyConfig returns a fully populated default configuration.
func DefaultEnergyConfig() EnergyConfig {
	return EnergyConfig{
		Scorer:       scorer.DefaultEnergyAwareScorerConfig(),
		Filter:       filter.DefaultEnergyBudgetFilterConfig(),
		CarbonScorer: scorer.DefaultCarbonIntensityScorerConfig(),
		DCGMScraper:  scraper.DefaultDCGMScraperConfig(),
		RAPLScraper:  scraper.DefaultRAPLScraperConfig(),
		CarbonAPI:    scraper.DefaultCarbonAPIScraperConfig(),
		StaleDuration: 10 * time.Second,
	}
}

// EnergyPluginSuite holds all instantiated energy-aware components.
// This is the main entry point — create one of these during EPP startup
// and wire the plugins into the scheduling pipeline.
type EnergyPluginSuite struct {
	// Store is the shared energy data store.
	Store *signals.EnergyStore

	// EnergyScorer is the multi-objective energy-aware scorer.
	EnergyScorer *scorer.EnergyAwareScorer

	// BudgetFilter is the power budget enforcement filter.
	BudgetFilter *filter.EnergyBudgetFilter

	// CarbonScorer is the standalone carbon intensity scorer.
	CarbonScorer *scorer.CarbonIntensityScorer

	// DCGMScraper is the GPU metrics scraper.
	DCGMScraper *scraper.DCGMScraper

	// CarbonScraper is the carbon API client.
	CarbonScraper *scraper.CarbonScraper
}

// NewEnergyPluginSuite creates all energy-aware components from config.
// This is the factory function called during EPP initialization.
func NewEnergyPluginSuite(config EnergyConfig) *EnergyPluginSuite {
	store := signals.NewEnergyStore(config.StaleDuration)

	return &EnergyPluginSuite{
		Store: store,

		EnergyScorer: scorer.NewEnergyAwareScorer(
			"energy-aware-scorer",
			store,
			config.Scorer,
		),

		BudgetFilter: filter.NewEnergyBudgetFilter(
			"energy-budget-filter",
			store,
			config.Filter,
		),

		CarbonScorer: scorer.NewCarbonIntensityScorer(
			"carbon-intensity-scorer",
			store,
			config.CarbonScorer,
		),

		DCGMScraper: scraper.NewDCGMScraper(store, config.DCGMScraper),

		CarbonScraper: scraper.NewCarbonScraper(store, config.CarbonAPI),
	}
}
