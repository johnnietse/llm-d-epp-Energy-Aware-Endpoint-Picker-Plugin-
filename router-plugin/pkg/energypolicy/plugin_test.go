package energypolicy

import (
	"context"
	"encoding/json"
	"fmt"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"testing"

	"github.com/go-logr/logr"
	"github.com/prometheus/client_golang/prometheus/testutil"

	eppdl "github.com/llm-d/llm-d-router/pkg/epp/datalayer"
	fwkdl "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/datalayer"
	fwkplugin "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/plugin"
	fwksched "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/scheduling"
	attrconcurrency "github.com/llm-d/llm-d-router/pkg/epp/framework/plugins/datalayer/attribute/concurrency"
)

func curvePaths() map[string]string {
	dir := filepath.Join("..", "..", "curves")
	return map[string]string{
		"a100":    filepath.Join(dir, "a100.json"),
		"rtx6000": filepath.Join(dir, "rtx6000.json"),
	}
}

func f64(v float64) *float64 { return &v }
func i64(v int64) *int64     { return &v }

// fleet builds real router endpoints: file-discovery labels and the in-flight
// attribute the inflight-load-producer would have written this cycle. They
// are listed in a scrambled order, so the scorer's own index sort is tested.
func fleet(types []string, inflight []int64) []fwksched.Endpoint {
	order := make([]int, len(types))
	for i := range order {
		order[i] = (i*5 + 3) % len(types) // a permutation for n = 8
	}
	var eps []fwksched.Endpoint
	for _, i := range order {
		attrs := fwkdl.NewAttributes()
		attrs.Put(attrconcurrency.InFlightLoadDataKey, &attrconcurrency.InFlightLoad{Requests: inflight[i]})
		md := &fwkdl.EndpointMetadata{
			ID:     fwkdl.ID{Namespace: "default", Name: fmt.Sprintf("vllm-%d", i)},
			Labels: map[string]string{DefaultIndexLabel: strconv.Itoa(i), DefaultTypeLabel: types[i]},
		}
		eps = append(eps, fwksched.NewEndpoint(md, &fwkdl.Metrics{}, attrs))
	}
	return eps
}

func indexOf(e fwksched.Endpoint) int {
	i, _ := strconv.Atoi(e.GetMetadata().Labels[DefaultIndexLabel])
	return i
}

// scoreScoped runs Score exactly as the scheduler does: on endpoints confined
// to what the plugin declared, with the result re-keyed afterwards.
func scoreScoped(s fwksched.Scorer, eps []fwksched.Endpoint) map[fwksched.Endpoint]float64 {
	scoped, _ := eppdl.Scope(logr.Discard(), "scorer", s, eps)
	return eppdl.UnscopeScores(s.Score(context.Background(), nil, scoped))
}

func ones(scores map[fwksched.Endpoint]float64) []int {
	var out []int
	for e, v := range scores {
		if v == 1 {
			out = append(out, indexOf(e))
		}
	}
	slices.Sort(out)
	return out
}

// TestScorerMatchesPythonThroughFramework repeats the fidelity check on real
// framework endpoints behind the router's data scoping, for a sample of the
// fixtures: labels are read, the in-flight count is reachable through the
// declared Consumes, and the 1.0 set is Python's tied set.
func TestScorerMatchesPythonThroughFramework(t *testing.T) {
	f, _ := loadFixtures(t)
	scorers := map[string]*Scorer{}
	get := func(pol string, h float64, cap int64) *Scorer {
		k := fmt.Sprint(pol, h, cap)
		if s := scorers[k]; s != nil {
			return s
		}
		s, err := NewScorer(k, scorerParams{Policy: pol, Curves: curvePaths(),
			SLOSeconds: f64(f.SLOSeconds), Headroom: f64(h), MaxInflight: i64(cap)})
		if err != nil {
			t.Fatal(err)
		}
		eppdl.RegisterScopeSpecs([]fwkplugin.Plugin{s})
		scorers[k] = s
		return s
	}
	n := 0
	for i := 0; i < len(f.Cases); i += 7 {
		c := f.Cases[i]
		s := get(c.Policy, c.Headroom, c.MaxInflight)
		before := testutil.ToFloat64(Picks.WithLabelValues(c.Policy, c.Outcome))
		got := ones(scoreScoped(s, fleet(f.Fleets[c.Fleet], c.Inflight)))
		if !slices.Equal(got, c.Tied) {
			t.Fatalf("case %d %s %v: python %v, plugin %v", i, c.Policy, c.Inflight, c.Tied, got)
		}
		if d := testutil.ToFloat64(Picks.WithLabelValues(c.Policy, c.Outcome)) - before; d != 1 {
			t.Fatalf("case %d: outcome %s counted %v times", i, c.Outcome, d)
		}
		n++
	}
	t.Logf("%d sampled cases agree through the framework", n)
}

// TestScopingIsReal shows the check above is not vacuous: the same scorer,
// confined as an UNREGISTERED plugin, cannot read the in-flight count and
// reports misconfigured instead of deciding.
func TestScopingIsReal(t *testing.T) {
	s, err := NewScorer("never-registered", scorerParams{Policy: "least_loaded",
		SLOSeconds: f64(2), Headroom: f64(0), MaxInflight: i64(256)})
	if err != nil {
		t.Fatal(err)
	}
	before := testutil.ToFloat64(Picks.WithLabelValues("least_loaded", string(Misconfigured)))
	got := ones(scoreScoped(s, fleet(slices.Repeat([]string{"rtx6000"}, 8), make([]int64, 8))))
	if len(got) != 0 {
		t.Fatalf("an unscoped read succeeded: %v", got)
	}
	if testutil.ToFloat64(Picks.WithLabelValues("least_loaded", string(Misconfigured)))-before != 1 {
		t.Fatal("misconfigured pick not counted")
	}
}

func TestRoundRobinSequence(t *testing.T) {
	f, _ := loadFixtures(t)
	s, err := NewScorer("rr", scorerParams{Policy: "round_robin",
		SLOSeconds: f64(2), Headroom: f64(0), MaxInflight: i64(256)})
	if err != nil {
		t.Fatal(err)
	}
	eppdl.RegisterScopeSpecs([]fwkplugin.Plugin{s})
	eps := fleet(f.Fleets["mixed"], make([]int64, 8))
	for i, want := range f.RoundRobinSequence {
		if got := ones(scoreScoped(s, eps)); !slices.Equal(got, []int{want}) {
			t.Fatalf("pick %d: python %d, plugin %v", i, want, got)
		}
	}
}

func TestFactoryRefusesIncompleteConfig(t *testing.T) {
	c := curvePaths()
	good := fmt.Sprintf(`{"policy":"energy_consolidate","curves":{"a100":%q,"rtx6000":%q},`+
		`"sloSeconds":2.0,"headroom":0,"maxInflight":256}`, c["a100"], c["rtx6000"])
	if _, err := ScorerFactory("ok", json.NewDecoder(strings.NewReader(good)), nil); err != nil {
		t.Fatalf("valid config refused: %v", err)
	}
	for why, cfg := range map[string]string{
		"no headroom":    `{"policy":"least_loaded","sloSeconds":2.0,"maxInflight":256}`,
		"no cap":         `{"policy":"least_loaded","sloSeconds":2.0,"headroom":0}`,
		"no slo":         `{"policy":"least_loaded","headroom":0,"maxInflight":256}`,
		"h out of range": `{"policy":"least_loaded","sloSeconds":2.0,"headroom":1,"maxInflight":256}`,
		"unknown policy": `{"policy":"best_effort","sloSeconds":2.0,"headroom":0,"maxInflight":256}`,
		"unknown field":  `{"policy":"least_loaded","sloSeconds":2.0,"headroom":0,"maxInflight":256,"headrom":0.1}`,
		"no curves":      `{"policy":"slo_packing","sloSeconds":2.0,"headroom":0,"maxInflight":256}`,
		"curve mislabelled": fmt.Sprintf(`{"policy":"slo_packing","curves":{"a100":%q},`+
			`"sloSeconds":2.0,"headroom":0,"maxInflight":256}`, c["rtx6000"]),
	} {
		if _, err := ScorerFactory("x", json.NewDecoder(strings.NewReader(cfg)), nil); err == nil {
			t.Errorf("%s: accepted %s", why, cfg)
		}
	}
	if _, err := PickerFactory("p", json.NewDecoder(strings.NewReader(`{}`)), nil); err == nil {
		t.Error("picker accepted a config without a seed")
	}
}

func scored(scores ...float64) []*fwksched.ScoredEndpoint {
	var out []*fwksched.ScoredEndpoint
	for i, s := range scores {
		md := &fwkdl.EndpointMetadata{ID: fwkdl.ID{Name: fmt.Sprintf("vllm-%d", i)}}
		out = append(out, &fwksched.ScoredEndpoint{
			Endpoint: fwksched.NewEndpoint(md, &fwkdl.Metrics{}, fwkdl.NewAttributes()), Score: s})
	}
	return out
}

func pickName(p *Picker, s []*fwksched.ScoredEndpoint) string {
	r := p.Pick(context.Background(), s)
	return r.TargetEndpoints[0].GetMetadata().ID.Name
}

// TestPickerUniformAndSeeded: only top-scored endpoints are chosen, each about
// equally often, and a seed reproduces the sequence whatever order the
// candidates arrive in.
func TestPickerUniformAndSeeded(t *testing.T) {
	p := NewPicker("t", 501)
	counts := map[string]int{}
	const draws = 30000
	for i := 0; i < draws; i++ {
		s := scored(0, 1, 1, 0, 1)
		if i%2 == 1 {
			slices.Reverse(s)
		}
		counts[pickName(p, s)]++
	}
	if len(counts) != 3 || counts["vllm-0"]+counts["vllm-3"] != 0 {
		t.Fatalf("picked outside the top set: %v", counts)
	}
	for k, c := range counts {
		if c < draws/3-600 || c > draws/3+600 { // about 7 standard deviations
			t.Errorf("%s drawn %d of %d times; not uniform", k, c, draws)
		}
	}
	a, b := NewPicker("a", 7), NewPicker("b", 7)
	for i := 0; i < 200; i++ {
		s1, s2 := scored(1, 1, 1, 1), scored(1, 1, 1, 1)
		slices.Reverse(s2)
		if pickName(a, s1) != pickName(b, s2) {
			t.Fatal("same seed, different picks: candidate order leaks into the draw")
		}
	}
}
