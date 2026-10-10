package energypolicy

import (
	"fmt"
	"math"
)

// Policy names match policy_harness.POLICIES, so a result file names the same
// rule whichever side ran it.
type Policy string

const (
	RoundRobin        Policy = "round_robin"
	LeastLoaded       Policy = "least_loaded"
	SLOPacking        Policy = "slo_packing"
	EnergyGreedy      Policy = "energy_greedy"
	EnergyConsolidate Policy = "energy_consolidate"
)

// needsCurves reports whether a policy reads the latency and energy curves.
func (p Policy) needsCurves() bool {
	return p == SLOPacking || p == EnergyGreedy || p == EnergyConsolidate
}

// ParsePolicy rejects anything that is not one of the measured rules.
func ParsePolicy(s string) (Policy, error) {
	switch p := Policy(s); p {
	case RoundRobin, LeastLoaded, SLOPacking, EnergyGreedy, EnergyConsolidate:
		return p, nil
	}
	return "", fmt.Errorf("unknown policy %q", s)
}

// Outcome says how a pick was made. The Python Router counts the same three
// cases (router_saturated_frac, router_ungrounded_frac), and the
// pre-registration's validity rule (section 7: more than 2% ungrounded picks
// invalidates a cell) needs them from the router too.
type Outcome string

const (
	// Feasible: at least one endpoint met the packing limit.
	Feasible Outcome = "feasible"
	// Saturated: the curves answered for some endpoint and none was within
	// the limit. The policy fell back to least-loaded. Expected past the knee.
	Saturated Outcome = "saturated"
	// Ungrounded: no endpoint's in-flight level was inside its curve, so the
	// policy had no measurement to stand on. Too many of these invalidate a cell.
	Ungrounded Outcome = "ungrounded"
)

// Params are the parts of the Python Router's state that are configuration.
type Params struct {
	SLOSeconds  float64
	Headroom    float64           // h; admit while p95 <= (1 - h) * SLO
	MaxInflight int64             // per-endpoint cap; 0 means none (Stage 2)
	Curves      map[string]*Curve // by GPU type
}

func (p *Params) packLimit() float64 { return p.SLOSeconds * (1.0 - p.Headroom) }

// Decide returns the endpoints a policy chooses between before its tie-break
// (ascending indices), and how the pick was made. It is Router._pick_locked
// for every policy except round_robin, which is stateful and lives in the
// Scorer. types[i] must have a curve when the policy needs one; the Scorer
// checks that before calling.
func Decide(pol Policy, types []string, inflight []int64, p *Params) ([]int, Outcome) {
	n := len(inflight)
	all := make([]int, n)
	for i := range all {
		all[i] = i
	}
	load := func(k int) float64 { return float64(inflight[k]) }

	if pol == LeastLoaded {
		return best(all, load, false), Feasible
	}

	// The feasibility scan, as in the Python list comprehension. nodata
	// counts endpoints whose curve had no point for their next level; an
	// endpoint excluded by the cap is not "no data", it is a known "full".
	limit := p.packLimit()
	var feas []int
	nodata := 0
	for k := 0; k < n; k++ {
		lat, missing := p.projLatency(types[k], inflight[k])
		if missing {
			nodata++
		}
		if lat <= limit {
			feas = append(feas, k)
		}
	}
	if len(feas) == 0 {
		// Every packing policy falls back to least-loaded, and the pick is
		// attributed to its cause exactly as Router._no_feasible does.
		oc := Saturated
		if nodata >= n {
			oc = Ungrounded
		}
		return best(all, load, false), oc
	}

	switch pol {
	case SLOPacking:
		return best(feas, load, true), Feasible
	case EnergyGreedy:
		return best(feas, func(k int) float64 { return p.jtok(types[k], inflight[k]) }, false), Feasible
	case EnergyConsolidate:
		// Prefer an already-busy endpoint; wake an idle one only when no busy
		// endpoint is feasible. Then minimise (J/token, -in-flight).
		var busy []int
		for _, k := range feas {
			if inflight[k] > 0 {
				busy = append(busy, k)
			}
		}
		pool := feas
		if len(busy) > 0 {
			pool = busy
		}
		j := func(k int) float64 { return p.jtok(types[k], inflight[k]) }
		first := best(pool, j, false)
		return best(first, func(k int) float64 { return -load(k) }, false), Feasible
	}
	panic("energypolicy: Decide called with " + string(pol))
}

// projLatency is Router._proj_latency for an open-loop curve: the measured
// p95 at the endpoint's next in-flight level, +Inf when capped (missing=false)
// or when the curve has no point there (missing=true).
func (p *Params) projLatency(gpu string, inflight int64) (lat float64, missing bool) {
	c := inflight + 1
	if p.MaxInflight > 0 && c > p.MaxInflight {
		return math.Inf(1), false
	}
	cur := p.Curves[gpu]
	v, ok := interp(cur.Levels, cur.LatP95, float64(c))
	if !ok {
		return math.Inf(1), true
	}
	return v, false
}

// jtok is Router._jtok: power over throughput at the next level, J/token.
func (p *Params) jtok(gpu string, inflight int64) float64 {
	c := float64(inflight + 1)
	cur := p.Curves[gpu]
	thr, ok1 := interp(cur.Levels, cur.TokS, c)
	pwr, ok2 := interp(cur.Levels, cur.Power, c)
	if !ok1 || !ok2 || !(thr > 0) {
		return math.Inf(1)
	}
	return pwr / thr
}

// best returns every candidate whose key equals the minimum (or maximum),
// in the order given. Equality is exact, as in Python's `v == best`; the
// interpolation is written so that Go and Python produce the same bits.
func best(cands []int, key func(int) float64, maximize bool) []int {
	var out []int
	var bk float64
	for i, k := range cands {
		v := key(k)
		switch {
		case i == 0 || (maximize && v > bk) || (!maximize && v < bk):
			bk, out = v, append(out[:0], k)
		case v == bk:
			out = append(out, k)
		}
	}
	return out
}
