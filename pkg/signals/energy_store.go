// Package signals provides the EnergyStore, a thread-safe in-memory store for
// real-time energy telemetry from inference pods. It serves as the data bridge
// between scrapers (writers) and scorers/filters (readers) in the EPP pipeline.
//
// Architecture:
//
//	DCGM Scraper ──┐
//	                ├──▶ EnergyStore ──▶ EnergyAwareScorer
//	RAPL Scraper ──┘                  ──▶ EnergyBudgetFilter
//	Carbon API ────────▶ ExternalSignals ──▶ CarbonIntensityScorer
package signals

import (
	"sync"
	"time"
)

// EnergyStore is a concurrent-safe store for per-pod energy profiles and
// cluster-wide external signals. It uses a read-write mutex to allow
// multiple concurrent scorer reads while serializing scraper writes.
type EnergyStore struct {
	mu       sync.RWMutex
	profiles map[string]*EnergyProfile // keyed by pod name
	external ExternalSignals

	// staleDuration is the maximum age of a profile before it's considered stale.
	// Stale profiles are still returned but with a degraded confidence score.
	staleDuration time.Duration
}

// NewEnergyStore creates a new EnergyStore with the specified stale threshold.
// Profiles older than staleDuration will be flagged as potentially outdated.
func NewEnergyStore(staleDuration time.Duration) *EnergyStore {
	return &EnergyStore{
		profiles:      make(map[string]*EnergyProfile),
		staleDuration: staleDuration,
	}
}

// UpdateProfile inserts or updates the energy profile for a pod.
// Called by scrapers on each scrape interval (typically every 1-2 seconds).
func (s *EnergyStore) UpdateProfile(profile EnergyProfile) {
	s.mu.Lock()
	defer s.mu.Unlock()
	profile.LastUpdated = time.Now()
	s.profiles[profile.PodName] = &profile
}

// GetProfile returns the energy profile for a specific pod.
// Returns nil if no profile exists for the given pod name.
func (s *EnergyStore) GetProfile(podName string) *EnergyProfile {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if p, ok := s.profiles[podName]; ok {
		cp := *p // return a copy to prevent data races
		return &cp
	}
	return nil
}

// GetAllProfiles returns a snapshot of all current profiles.
// The returned map is a copy — safe to iterate without holding locks.
func (s *EnergyStore) GetAllProfiles() map[string]EnergyProfile {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make(map[string]EnergyProfile, len(s.profiles))
	for k, v := range s.profiles {
		result[k] = *v
	}
	return result
}

// RemoveProfile deletes the profile for a pod (e.g., when a pod is terminated).
func (s *EnergyStore) RemoveProfile(podName string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.profiles, podName)
}

// IsStale returns true if the profile for the given pod is older than staleDuration.
func (s *EnergyStore) IsStale(podName string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	p, ok := s.profiles[podName]
	if !ok {
		return true // no profile = stale
	}
	return time.Since(p.LastUpdated) > s.staleDuration
}

// TotalClusterPower returns the sum of CurrentPower_W across all tracked pods.
// Used by the EnergyBudgetFilter to enforce cluster-wide power limits.
func (s *EnergyStore) TotalClusterPower() float64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var total float64
	for _, p := range s.profiles {
		total += p.CurrentPower_W
	}
	return total
}

// PodCount returns the number of tracked pods.
func (s *EnergyStore) PodCount() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return len(s.profiles)
}

// UpdateExternalSignals updates the cluster-wide carbon and electricity signals.
// Called by the carbon API scraper and electricity price scraper.
func (s *EnergyStore) UpdateExternalSignals(ext ExternalSignals) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ext.LastUpdated = time.Now()
	s.external = ext
}

// GetExternalSignals returns a copy of the current external signals.
func (s *EnergyStore) GetExternalSignals() ExternalSignals {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.external
}

// AverageEnergyPerToken returns the mean energy-per-token across all pods of a given hardware class.
// Returns 0 if no matching pods are found.
func (s *EnergyStore) AverageEnergyPerToken(class HardwareClass) float64 {
	s.mu.RLock()
	defer s.mu.RUnlock()
	var sum float64
	var count int
	for _, p := range s.profiles {
		if p.HardwareClass == class {
			sum += p.EnergyPerToken_mJ
			count++
		}
	}
	if count == 0 {
		return 0
	}
	return sum / float64(count)
}

// EvictStaleProfiles removes all profiles older than staleDuration.
// Returns the names of evicted pods. Called periodically by the scraper
// to prevent ghost pods from influencing scoring decisions after termination.
func (s *EnergyStore) EvictStaleProfiles() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var evicted []string
	for name, p := range s.profiles {
		if time.Since(p.LastUpdated) > s.staleDuration {
			delete(s.profiles, name)
			evicted = append(evicted, name)
		}
	}
	return evicted
}

// StaleCount returns the number of profiles older than staleDuration.
func (s *EnergyStore) StaleCount() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	count := 0
	for _, p := range s.profiles {
		if time.Since(p.LastUpdated) > s.staleDuration {
			count++
		}
	}
	return count
}
