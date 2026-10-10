// Package energypolicy ports the Stage 2 routing policies of
// experiments/scripts/policy_harness.py (class Router) into the llm-d-router
// EPP, as amended by the Stage 5 pre-registration (tag prereg-stage5-v2,
// section 15): open-loop curves with routing on p95 latency (B1, B2), a
// per-endpoint cap (B1), headroom h (B4) and a seeded random tie-break (B5).
//
// The split follows the router's own pipeline. A Scorer decides: it gives 1.0
// to exactly the endpoints the Python Router would choose between before its
// tie-break, and 0.0 to the rest. A Picker breaks the tie, uniformly and from
// a seeded stream. The upstream max-score-picker cannot do that part: it
// breaks ties by a global round-robin rotation, which is neither random nor
// seeded per trial.
package energypolicy

import (
	"encoding/json"
	"fmt"
	"os"
)

// Curve is one GPU type's open-loop curve, as reduced by the Python
// load_openloop_curve and written by export_router_fixtures.py. The Go side
// never re-reduces a curve.csv: one implementation of that reduction exists.
type Curve struct {
	GPUType      string    `json:"gpu_type"`
	Source       string    `json:"source"`
	SourceSHA256 string    `json:"source_sha256"`
	Levels       []float64 `json:"levels"`  // mean in flight, strictly rising
	Power        []float64 `json:"power"`   // W at each level
	TokS         []float64 `json:"tok_s"`   // generated tokens/s at each level
	LatP95       []float64 `json:"lat_p95"` // end-to-end p95 latency, s
}

// LoadCurve reads and checks one exported curve.
func LoadCurve(path string) (*Curve, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Curve
	if err := json.Unmarshal(raw, &c); err != nil {
		return nil, fmt.Errorf("curve %s: %w", path, err)
	}
	n := len(c.Levels)
	if n < 3 {
		return nil, fmt.Errorf("curve %s: %d levels, need at least 3", path, n)
	}
	if len(c.Power) != n || len(c.TokS) != n || len(c.LatP95) != n {
		return nil, fmt.Errorf("curve %s: series lengths differ from %d levels", path, n)
	}
	for i := 1; i < n; i++ {
		if !(c.Levels[i] > c.Levels[i-1]) {
			return nil, fmt.Errorf("curve %s: levels not strictly rising at %d", path, i)
		}
	}
	return &c, nil
}

// interp mirrors policy_harness.interp exactly, including its edges:
// clamped below the first level, absent (ok=false) above the last.
//
// The interpolation is written as vlo + float64(f*(vhi-vlo)). The explicit
// conversion is not decoration: the Go spec lets the compiler fuse x*y+z into
// one FMA instruction, which rounds once instead of twice and can differ
// from Python in the last bit. Ties are decided by exact float equality, so a
// last-bit difference would change which endpoints tie. A conversion forces
// the product to be rounded on its own, as Python does.
func interp(levels, vals []float64, c float64) (float64, bool) {
	n := len(levels)
	if c <= levels[0] {
		return vals[0], true
	}
	if c > levels[n-1] {
		return 0, false
	}
	if c == levels[n-1] {
		return vals[n-1], true
	}
	for i := 0; i+1 < n; i++ {
		lo, hi := levels[i], levels[i+1]
		if lo <= c && c <= hi {
			f := (c - lo) / (hi - lo)
			return vals[i] + float64(f*(vals[i+1]-vals[i])), true
		}
	}
	return 0, false
}
