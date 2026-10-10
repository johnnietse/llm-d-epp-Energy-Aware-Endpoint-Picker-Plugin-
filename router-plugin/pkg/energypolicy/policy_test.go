package energypolicy

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"testing"
)

// fixtures.json is written by experiments/scripts/export_router_fixtures.py
// from the measured Python Router (amendment B11). Each case is one fleet
// state and one policy, with the set of endpoints Python chose between
// before its tie-break and how the pick was made.
type fixtureFile struct {
	SLOSeconds         float64             `json:"slo_s"`
	Fleets             map[string][]string `json:"fleets"`
	Curves             map[string]string   `json:"curves"`
	RoundRobinSequence []int               `json:"round_robin_sequence"`
	Cases              []struct {
		Fleet       string  `json:"fleet"`
		Headroom    float64 `json:"headroom"`
		MaxInflight int64   `json:"max_inflight"`
		Policy      string  `json:"policy"`
		Inflight    []int64 `json:"inflight"`
		Tied        []int   `json:"tied"`
		Outcome     string  `json:"outcome"`
	} `json:"cases"`
}

func loadFixtures(t *testing.T) (*fixtureFile, map[string]*Curve) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "fixtures.json"))
	if err != nil {
		t.Fatal(err)
	}
	var f fixtureFile
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatal(err)
	}
	curves := map[string]*Curve{}
	for gpu, rel := range f.Curves {
		// rel is repository-relative; this package is router-plugin/pkg/energypolicy.
		c, err := LoadCurve(filepath.Join("..", "..", "..", filepath.FromSlash(rel)))
		if err != nil {
			t.Fatal(err)
		}
		curves[gpu] = c
	}
	if len(f.Cases) == 0 {
		t.Fatal("no fixture cases")
	}
	return &f, curves
}

// TestDecideMatchesPython is the fidelity test of pre-registration section 10
// item 2 as amended by B11: on every recorded state, the Go rule chooses
// between exactly the endpoints the Python rule chose between, and attributes
// the pick to the same cause.
func TestDecideMatchesPython(t *testing.T) {
	f, curves := loadFixtures(t)
	seen := map[string]int{}
	ties := 0
	for i, c := range f.Cases {
		pol, err := ParsePolicy(c.Policy)
		if err != nil {
			t.Fatal(err)
		}
		p := &Params{SLOSeconds: f.SLOSeconds, Headroom: c.Headroom,
			MaxInflight: c.MaxInflight, Curves: curves}
		tied, oc := Decide(pol, f.Fleets[c.Fleet], c.Inflight, p)
		if !slices.Equal(tied, c.Tied) || string(oc) != c.Outcome {
			t.Fatalf("case %d %s %s h=%v cap=%d inflight=%v:\n  python %v %s\n  go     %v %s",
				i, c.Fleet, c.Policy, c.Headroom, c.MaxInflight, c.Inflight,
				c.Tied, c.Outcome, tied, oc)
		}
		seen[c.Policy+"/"+c.Outcome]++
		if len(tied) > 1 {
			ties++
		}
	}
	// A fixture that never reaches a branch tests nothing there.
	for _, k := range []string{"slo_packing/feasible", "slo_packing/saturated", "slo_packing/ungrounded",
		"energy_greedy/feasible", "energy_greedy/saturated", "energy_greedy/ungrounded",
		"energy_consolidate/feasible", "energy_consolidate/saturated", "energy_consolidate/ungrounded",
		"least_loaded/feasible"} {
		if seen[k] == 0 {
			t.Errorf("fixtures never exercise %s", k)
		}
	}
	if ties == 0 {
		t.Error("fixtures contain no ties; the tie-break set is untested")
	}
	t.Logf("%d cases agree (%d with ties): %v", len(f.Cases), ties, seen)
}

func TestInterpEdges(t *testing.T) {
	lv := []float64{1, 2, 4}
	v := []float64{10, 20, 40}
	for _, c := range []struct {
		x    float64
		want float64
		ok   bool
	}{{0, 10, true}, {1, 10, true}, {1.5, 15, true}, {3, 30, true}, {4, 40, true}, {4.0001, 0, false}} {
		got, ok := interp(lv, v, c.x)
		if ok != c.ok || (ok && got != c.want) {
			t.Errorf("interp(%v) = %v,%v want %v,%v", c.x, got, ok, c.want, c.ok)
		}
	}
}
