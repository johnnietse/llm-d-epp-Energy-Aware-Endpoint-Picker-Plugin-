// Package adaptive implements the Adaptive Weight Controller for the energy-aware EPP.
//
// This is an "above and beyond" feature that dynamically adjusts scoring weights
// based on real-time cluster conditions:
//
//   - Carbon Spike Mode: When grid carbon intensity exceeds a threshold,
//     temporarily increase carbon weight across all phases to aggressively
//     route to low-power hardware.
//
//   - Load Shedding Mode: When cluster power exceeds budget threshold,
//     increase energy weight to prioritize efficiency over latency.
//
//   - Green Mode: When carbon intensity is very low (e.g., during solar peak),
//     relax energy constraints and allow latency-optimized routing.
//
// The controller runs as a background goroutine, polling the EnergyStore
// every AdaptInterval and updating the scorer's weight vectors accordingly.
//
// This models a closed-loop control system:
//
//	                 ┌──────────────────────────────┐
//	Cluster State ──▶│   Adaptive Weight Controller  │──▶ Updated Weights
//	Carbon Signal ──▶│   (PID-like feedback loop)    │         │
//	                 └──────────────────────────────┘         │
//	                         ▲                                ▼
//	                         │                         EnergyAwareScorer
//	                         └── weight history ◀──────────────┘
package adaptive

import (
	"context"
	"fmt"
	"log"
	"sync"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// Mode represents the current operational mode of the controller.
type Mode string

const (
	ModeNormal    Mode = "normal"     // Default weights
	ModeCarbonHigh Mode = "carbon_high" // Carbon spike — maximize efficiency
	ModeLoadShed  Mode = "load_shed"   // Power budget exceeded — shed load
	ModeGreen     Mode = "green"       // Clean grid — optimize for performance
)

// AdaptiveConfig holds the configuration for the adaptive controller.
type AdaptiveConfig struct {
	// AdaptInterval is how often to re-evaluate cluster conditions.
	AdaptInterval time.Duration `yaml:"adaptInterval"`

	// CarbonHighThreshold is the gCO2/kWh threshold for carbon spike mode.
	// Above this: aggressively prefer low-power hardware.
	CarbonHighThreshold float64 `yaml:"carbonHighThreshold"`

	// CarbonLowThreshold is the gCO2/kWh threshold for green mode.
	// Below this: allow latency-optimized routing.
	CarbonLowThreshold float64 `yaml:"carbonLowThreshold"`

	// PowerBudgetThreshold is the fraction of max cluster power (0-1)
	// that triggers load shedding mode.
	PowerBudgetThreshold float64 `yaml:"powerBudgetThreshold"`

	// MaxClusterPower_W is the total power budget for the cluster.
	MaxClusterPower_W float64 `yaml:"maxClusterPowerW"`

	// BaseWeightsPrefill are the default prefill weights (used in normal mode).
	BaseWeightsPrefill signals.WeightVector `yaml:"baseWeightsPrefill"`

	// BaseWeightsDecode are the default decode weights (used in normal mode).
	BaseWeightsDecode signals.WeightVector `yaml:"baseWeightsDecode"`
}

// DefaultAdaptiveConfig returns sensible defaults.
func DefaultAdaptiveConfig() AdaptiveConfig {
	return AdaptiveConfig{
		AdaptInterval:       30 * time.Second,
		CarbonHighThreshold: 500.0, // gCO2/kWh — above US average triggers carbon mode
		CarbonLowThreshold:  100.0, // gCO2/kWh — below French nuclear triggers green mode
		PowerBudgetThreshold: 0.85,
		MaxClusterPower_W:   2000.0,
		BaseWeightsPrefill:  signals.DefaultPrefillWeights(),
		BaseWeightsDecode:   signals.DefaultDecodeWeights(),
	}
}

// WeightSnapshot captures a weight state for logging/metrics.
type WeightSnapshot struct {
	Timestamp       time.Time          `json:"timestamp"`
	Mode            Mode               `json:"mode"`
	PrefillWeights  signals.WeightVector `json:"prefillWeights"`
	DecodeWeights   signals.WeightVector `json:"decodeWeights"`
	CarbonIntensity float64            `json:"carbonIntensity"`
	ClusterPower    float64            `json:"clusterPowerW"`
	Reason          string             `json:"reason"`
}

// WeightUpdateCallback is called whenever weights are adjusted.
type WeightUpdateCallback func(prefill, decode signals.WeightVector)

// AdaptiveController monitors cluster conditions and adjusts scoring weights.
type AdaptiveController struct {
	config   AdaptiveConfig
	store    *signals.EnergyStore
	callback WeightUpdateCallback

	mu       sync.RWMutex
	mode     Mode
	current  WeightSnapshot
	history  []WeightSnapshot // rolling history for analysis

	cancel context.CancelFunc
}

// NewAdaptiveController creates a new controller.
func NewAdaptiveController(
	store *signals.EnergyStore,
	config AdaptiveConfig,
	callback WeightUpdateCallback,
) *AdaptiveController {
	return &AdaptiveController{
		config:   config,
		store:    store,
		callback: callback,
		mode:     ModeNormal,
		current: WeightSnapshot{
			Mode:           ModeNormal,
			PrefillWeights: config.BaseWeightsPrefill,
			DecodeWeights:  config.BaseWeightsDecode,
		},
		history: make([]WeightSnapshot, 0, 1000),
	}
}

// Start begins the background adaptation loop.
func (c *AdaptiveController) Start(ctx context.Context) {
	ctx, c.cancel = context.WithCancel(ctx)

	// Evaluate immediately
	c.evaluate()

	go func() {
		ticker := time.NewTicker(c.config.AdaptInterval)
		defer ticker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				c.evaluate()
			}
		}
	}()
}

// Stop halts the background loop.
func (c *AdaptiveController) Stop() {
	if c.cancel != nil {
		c.cancel()
	}
}

// CurrentMode returns the current operational mode.
func (c *AdaptiveController) CurrentMode() Mode {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.mode
}

// CurrentSnapshot returns the current weight state.
func (c *AdaptiveController) CurrentSnapshot() WeightSnapshot {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return c.current
}

// History returns the rolling weight adjustment history.
func (c *AdaptiveController) History() []WeightSnapshot {
	c.mu.RLock()
	defer c.mu.RUnlock()
	result := make([]WeightSnapshot, len(c.history))
	copy(result, c.history)
	return result
}

// evaluate checks cluster conditions and adjusts weights if needed.
func (c *AdaptiveController) evaluate() {
	ext := c.store.GetExternalSignals()
	clusterPower := c.store.TotalClusterPower()

	carbonIntensity := ext.CarbonIntensity_gCO2_kWh
	powerRatio := 0.0
	if c.config.MaxClusterPower_W > 0 {
		powerRatio = clusterPower / c.config.MaxClusterPower_W
	}

	// Determine mode
	newMode := ModeNormal
	reason := "nominal conditions"

	if powerRatio >= c.config.PowerBudgetThreshold {
		newMode = ModeLoadShed
		reason = fmt.Sprintf("cluster power %.0fW exceeds %.0f%% of %.0fW budget",
			clusterPower, c.config.PowerBudgetThreshold*100, c.config.MaxClusterPower_W)
	} else if carbonIntensity >= c.config.CarbonHighThreshold {
		newMode = ModeCarbonHigh
		reason = fmt.Sprintf("carbon intensity %.0f gCO2/kWh exceeds %.0f threshold",
			carbonIntensity, c.config.CarbonHighThreshold)
	} else if carbonIntensity > 0 && carbonIntensity <= c.config.CarbonLowThreshold {
		newMode = ModeGreen
		reason = fmt.Sprintf("carbon intensity %.0f gCO2/kWh below %.0f threshold (clean grid)",
			carbonIntensity, c.config.CarbonLowThreshold)
	}

	// Compute adjusted weights
	prefill, decode := c.computeWeights(newMode)

	c.mu.Lock()
	oldMode := c.mode
	c.mode = newMode
	c.current = WeightSnapshot{
		Timestamp:       time.Now(),
		Mode:            newMode,
		PrefillWeights:  prefill,
		DecodeWeights:   decode,
		CarbonIntensity: carbonIntensity,
		ClusterPower:    clusterPower,
		Reason:          reason,
	}
	c.history = append(c.history, c.current)
	// Keep last 1000 entries
	if len(c.history) > 1000 {
		c.history = c.history[len(c.history)-1000:]
	}
	c.mu.Unlock()

	// Log mode transitions
	if newMode != oldMode {
		log.Printf("[AdaptiveController] Mode: %s -> %s (%s)", oldMode, newMode, reason)
		log.Printf("[AdaptiveController] Prefill weights: L=%.2f E=%.2f C=%.2f",
			prefill.Latency, prefill.Energy, prefill.Carbon)
		log.Printf("[AdaptiveController] Decode weights:  L=%.2f E=%.2f C=%.2f",
			decode.Latency, decode.Energy, decode.Carbon)
	}

	// Notify scorer of new weights
	if c.callback != nil {
		c.callback(prefill, decode)
	}
}

// computeWeights returns adjusted weight vectors for the given mode.
func (c *AdaptiveController) computeWeights(mode Mode) (signals.WeightVector, signals.WeightVector) {
	base := c.config

	switch mode {
	case ModeCarbonHigh:
		// Carbon spike: increase carbon weight, reduce latency weight
		return signals.WeightVector{
			Latency: base.BaseWeightsPrefill.Latency * 0.5,
			Energy:  base.BaseWeightsPrefill.Energy * 1.2,
			Carbon:  base.BaseWeightsPrefill.Carbon * 2.0,
		}.Normalize(), signals.WeightVector{
			Latency: base.BaseWeightsDecode.Latency * 0.3,
			Energy:  base.BaseWeightsDecode.Energy * 1.0,
			Carbon:  base.BaseWeightsDecode.Carbon * 2.5,
		}.Normalize()

	case ModeLoadShed:
		// Power budget exceeded: maximize energy efficiency
		return signals.WeightVector{
			Latency: base.BaseWeightsPrefill.Latency * 0.3,
			Energy:  base.BaseWeightsPrefill.Energy * 3.0,
			Carbon:  base.BaseWeightsPrefill.Carbon * 1.0,
		}.Normalize(), signals.WeightVector{
			Latency: base.BaseWeightsDecode.Latency * 0.1,
			Energy:  base.BaseWeightsDecode.Energy * 3.0,
			Carbon:  base.BaseWeightsDecode.Carbon * 1.0,
		}.Normalize()

	case ModeGreen:
		// Clean grid: relax energy constraints, favor performance
		return signals.WeightVector{
			Latency: base.BaseWeightsPrefill.Latency * 1.5,
			Energy:  base.BaseWeightsPrefill.Energy * 0.5,
			Carbon:  base.BaseWeightsPrefill.Carbon * 0.3,
		}.Normalize(), signals.WeightVector{
			Latency: base.BaseWeightsDecode.Latency * 1.5,
			Energy:  base.BaseWeightsDecode.Energy * 0.7,
			Carbon:  base.BaseWeightsDecode.Carbon * 0.3,
		}.Normalize()

	default: // ModeNormal
		return base.BaseWeightsPrefill, base.BaseWeightsDecode
	}
}
