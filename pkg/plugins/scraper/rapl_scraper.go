// Package scraper implements the RAPL (Running Average Power Limit) scraper
// for reading CPU/package-level energy counters from Linux powercap sysfs.
//
// RAPL is used for:
//  1. Power-capped GPU nodes — measuring total node power via CPU-side RAPL
//  2. CPU-based inference pods — where accelerator is the CPU itself
//  3. Simulated low-power environments — RAPL power capping to emulate ASICs
//
// RAPL interface path:
//
//	/sys/class/powercap/intel-rapl/intel-rapl:0/energy_uj    (Package 0)
//	/sys/class/powercap/intel-rapl/intel-rapl:0:0/energy_uj  (Core subdomain)
//
// Note: On AMD, the interface is the same (amd_energy or powercap subsystem).
// The kernel abstracts both under /sys/class/powercap/.
//
// Energy is read in microjoules (µJ) from cumulative counters. Power is
// derived by computing ΔE/Δt between two consecutive reads.
package scraper

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/johnnie/energy-aware-epp/pkg/signals"
)

// RAPLScraperConfig holds configuration for the RAPL scraper.
type RAPLScraperConfig struct {
	// ScrapeInterval is how often to read RAPL counters.
	ScrapeInterval time.Duration `yaml:"scrapeInterval"`

	// RAPLBasePath is the sysfs base path for RAPL energy counters.
	// Default: /sys/class/powercap/intel-rapl
	RAPLBasePath string `yaml:"raplBasePath"`

	// Domains specifies which RAPL domains to monitor.
	// Default: ["intel-rapl:0"] (Package 0)
	Domains []string `yaml:"domains"`

	// EWMAAlpha is the smoothing factor for power averaging.
	EWMAAlpha float64 `yaml:"ewmaAlpha"`
}

// DefaultRAPLScraperConfig returns sensible defaults.
func DefaultRAPLScraperConfig() RAPLScraperConfig {
	return RAPLScraperConfig{
		ScrapeInterval: 1 * time.Second,
		RAPLBasePath:   "/sys/class/powercap/intel-rapl",
		Domains:        []string{"intel-rapl:0"},
		EWMAAlpha:      0.3,
	}
}

// RAPLReading holds a single reading from a RAPL domain.
type RAPLReading struct {
	// Domain is the RAPL domain identifier (e.g., "intel-rapl:0").
	Domain string

	// Energy_uJ is the cumulative energy counter in microjoules.
	Energy_uJ uint64

	// MaxEnergy_uJ is the maximum value before overflow.
	MaxEnergy_uJ uint64

	// Timestamp is when this reading was taken.
	Timestamp time.Time
}

// RAPLDomainState tracks the state of a RAPL domain across scrapes.
type RAPLDomainState struct {
	PrevReading RAPLReading
	Power_W     float64 // derived power in watts
}

// EnergyReader is an interface for reading RAPL energy counters.
// This allows mocking in tests without requiring actual sysfs access.
type EnergyReader interface {
	// ReadEnergy reads the cumulative energy counter (µJ) for a domain.
	ReadEnergy(basePath, domain string) (uint64, error)

	// ReadMaxEnergy reads the max energy range (µJ) for overflow detection.
	ReadMaxEnergy(basePath, domain string) (uint64, error)

	// ReadPowerConstraint reads the power limit (µW) if set, for TDP estimation.
	ReadPowerConstraint(basePath, domain string) (uint64, error)
}

// SysfsEnergyReader reads RAPL counters from the real sysfs filesystem.
type SysfsEnergyReader struct{}

// ReadEnergy reads energy_uj from sysfs.
func (r *SysfsEnergyReader) ReadEnergy(basePath, domain string) (uint64, error) {
	path := fmt.Sprintf("%s/%s/energy_uj", basePath, domain)
	return readUint64File(path)
}

// ReadMaxEnergy reads max_energy_range_uj from sysfs.
func (r *SysfsEnergyReader) ReadMaxEnergy(basePath, domain string) (uint64, error) {
	path := fmt.Sprintf("%s/%s/max_energy_range_uj", basePath, domain)
	return readUint64File(path)
}

// ReadPowerConstraint reads constraint_0_power_limit_uw from sysfs.
func (r *SysfsEnergyReader) ReadPowerConstraint(basePath, domain string) (uint64, error) {
	path := fmt.Sprintf("%s/%s/constraint_0_power_limit_uw", basePath, domain)
	return readUint64File(path)
}

// readUint64File reads a single uint64 value from a file.
func readUint64File(path string) (uint64, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	return strconv.ParseUint(strings.TrimSpace(string(data)), 10, 64)
}

// MockEnergyReader provides controllable readings for unit tests.
type MockEnergyReader struct {
	mu              sync.Mutex
	energyValues    map[string]uint64 // domain → energy_uj
	maxEnergyValues map[string]uint64 // domain → max_energy_range_uj
	powerLimits     map[string]uint64 // domain → power_limit_uw
}

// NewMockEnergyReader creates a new mock reader.
func NewMockEnergyReader() *MockEnergyReader {
	return &MockEnergyReader{
		energyValues:    make(map[string]uint64),
		maxEnergyValues: make(map[string]uint64),
		powerLimits:     make(map[string]uint64),
	}
}

// SetEnergy sets the energy counter for a domain.
func (r *MockEnergyReader) SetEnergy(domain string, energy_uJ uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.energyValues[domain] = energy_uJ
}

// SetMaxEnergy sets the max energy range for a domain.
func (r *MockEnergyReader) SetMaxEnergy(domain string, maxEnergy_uJ uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.maxEnergyValues[domain] = maxEnergy_uJ
}

// SetPowerLimit sets the power limit for a domain.
func (r *MockEnergyReader) SetPowerLimit(domain string, limit_uW uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.powerLimits[domain] = limit_uW
}

func (r *MockEnergyReader) ReadEnergy(basePath, domain string) (uint64, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	v, ok := r.energyValues[domain]
	if !ok {
		return 0, fmt.Errorf("domain %s not found", domain)
	}
	return v, nil
}

func (r *MockEnergyReader) ReadMaxEnergy(basePath, domain string) (uint64, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	v, ok := r.maxEnergyValues[domain]
	if !ok {
		return 0, fmt.Errorf("domain %s not found", domain)
	}
	return v, nil
}

func (r *MockEnergyReader) ReadPowerConstraint(basePath, domain string) (uint64, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	v, ok := r.powerLimits[domain]
	if !ok {
		return 0, fmt.Errorf("domain %s not found", domain)
	}
	return v, nil
}

// RAPLScraper reads RAPL energy counters and derives power consumption.
type RAPLScraper struct {
	config      RAPLScraperConfig
	store       *signals.EnergyStore
	reader      EnergyReader
	domainState map[string]*RAPLDomainState
	mu          sync.Mutex
}

// NewRAPLScraper creates a new RAPL scraper with the real sysfs reader.
func NewRAPLScraper(store *signals.EnergyStore, config RAPLScraperConfig) *RAPLScraper {
	return &RAPLScraper{
		config:      config,
		store:       store,
		reader:      &SysfsEnergyReader{},
		domainState: make(map[string]*RAPLDomainState),
	}
}

// NewRAPLScraperWithReader creates a scraper with a custom reader (for testing).
func NewRAPLScraperWithReader(store *signals.EnergyStore, config RAPLScraperConfig, reader EnergyReader) *RAPLScraper {
	return &RAPLScraper{
		config:      config,
		store:       store,
		reader:      reader,
		domainState: make(map[string]*RAPLDomainState),
	}
}

// Scrape performs a single scrape cycle: reads all configured RAPL domains,
// computes power from ΔE/Δt, and updates the EnergyStore.
//
// The podName parameter associates this node-level reading with a specific pod.
// In a real deployment, a DaemonSet would run the RAPL scraper on each node.
func (s *RAPLScraper) Scrape(podName string, hardwareClass signals.HardwareClass) {
	s.mu.Lock()
	defer s.mu.Unlock()

	var totalPower float64

	for _, domain := range s.config.Domains {
		energy_uJ, err := s.reader.ReadEnergy(s.config.RAPLBasePath, domain)
		if err != nil {
			continue
		}

		now := time.Now()
		reading := RAPLReading{
			Domain:    domain,
			Energy_uJ: energy_uJ,
			Timestamp: now,
		}

		// Get max energy for overflow handling
		maxEnergy_uJ, _ := s.reader.ReadMaxEnergy(s.config.RAPLBasePath, domain)
		reading.MaxEnergy_uJ = maxEnergy_uJ

		state, exists := s.domainState[domain]
		if !exists {
			// First reading — store baseline, no power yet
			s.domainState[domain] = &RAPLDomainState{
				PrevReading: reading,
			}
			continue
		}

		// Compute power from ΔE/Δt
		power := s.computePower(state.PrevReading, reading)

		// EWMA smooth
		state.Power_W = s.config.EWMAAlpha*power + (1-s.config.EWMAAlpha)*state.Power_W
		state.PrevReading = reading

		totalPower += state.Power_W
	}

	// Read TDP from power constraint (if available)
	tdp := s.readTDP()

	// Update store
	s.store.UpdateProfile(signals.EnergyProfile{
		PodName:        podName,
		HardwareClass:  hardwareClass,
		TDP_Watts:      tdp,
		CurrentPower_W: totalPower,
	})
}

// computePower derives power (W) from two consecutive energy readings.
// Handles counter overflow using max_energy_range_uj.
func (s *RAPLScraper) computePower(prev, curr RAPLReading) float64 {
	dt := curr.Timestamp.Sub(prev.Timestamp).Seconds()
	if dt <= 0 {
		return 0
	}

	var deltaEnergy_uJ uint64
	if curr.Energy_uJ >= prev.Energy_uJ {
		deltaEnergy_uJ = curr.Energy_uJ - prev.Energy_uJ
	} else {
		// Counter overflow
		if curr.MaxEnergy_uJ > 0 {
			deltaEnergy_uJ = (curr.MaxEnergy_uJ - prev.Energy_uJ) + curr.Energy_uJ
		} else {
			// Unknown max — assume 32-bit overflow
			deltaEnergy_uJ = (^uint64(0) - prev.Energy_uJ) + curr.Energy_uJ
		}
	}

	// Convert µJ to Watts: power = energy (µJ) / time (s) / 1,000,000
	return float64(deltaEnergy_uJ) / dt / 1_000_000.0
}

// readTDP reads the power constraint (TDP) from the first domain.
func (s *RAPLScraper) readTDP() float64 {
	if len(s.config.Domains) == 0 {
		return 0
	}
	limit_uW, err := s.reader.ReadPowerConstraint(s.config.RAPLBasePath, s.config.Domains[0])
	if err != nil {
		return 0
	}
	// Convert µW to W
	return float64(limit_uW) / 1_000_000.0
}
