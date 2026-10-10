package energypolicy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"sync/atomic"

	"github.com/prometheus/client_golang/prometheus"
	"sigs.k8s.io/controller-runtime/pkg/log"

	fwkplugin "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/plugin"
	fwksched "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/scheduling"
	attrconcurrency "github.com/llm-d/llm-d-router/pkg/epp/framework/plugins/datalayer/attribute/concurrency"
)

// ScorerType is the name an EPP config uses to select the policy scorer.
const ScorerType = "energy-epp-policy-scorer"

// Default endpoint labels, set per endpoint in the file-discovery list.
const (
	DefaultTypeLabel  = "energy-epp/gpu-type"
	DefaultIndexLabel = "energy-epp/index"
)

// Misconfigured is counted, never routed around silently: a pick made without
// a GPU type, a curve or an in-flight count is not the policy being claimed.
// A run is valid only if this count is zero.
const Misconfigured Outcome = "misconfigured"

// Picks counts every scheduling decision by policy and outcome; the run
// harness scrapes it to compute the router's saturated and ungrounded
// fractions, as the Python Router reported them.
var Picks = prometheus.NewCounterVec(prometheus.CounterOpts{
	Name: "energy_epp_policy_picks_total",
	Help: "Scheduling decisions of the energy-epp policy scorer, by policy and outcome (feasible, saturated, ungrounded, misconfigured).",
}, []string{"policy", "outcome"})

var (
	_ fwksched.Scorer          = &Scorer{}
	_ fwkplugin.ConsumerPlugin = &Scorer{}
)

// scorerParams is the plugin's configuration. Every parameter that changes
// the rule is a pointer and required: a config must state h and the cap, so
// no run can inherit a default nobody wrote down.
type scorerParams struct {
	Policy                   string            `json:"policy"`
	Curves                   map[string]string `json:"curves"`
	SLOSeconds               *float64          `json:"sloSeconds"`
	Headroom                 *float64          `json:"headroom"`
	MaxInflight              *int64            `json:"maxInflight"`
	TypeLabel                string            `json:"typeLabel"`
	IndexLabel               string            `json:"indexLabel"`
	InFlightLoadProducerName string            `json:"inFlightLoadProducerName"`
}

// Scorer gives 1.0 to exactly the endpoints the policy chooses between and
// 0.0 to the rest. A tie-breaking Picker then chooses one of the 1.0 set.
type Scorer struct {
	typedName  fwkplugin.TypedName
	policy     Policy
	params     Params
	typeLabel  string
	indexLabel string
	inflightDK fwkplugin.DataKey
	rr         atomic.Uint64
}

// ScorerFactory builds a Scorer from configuration and refuses anything
// incomplete or unknown.
func ScorerFactory(name string, raw *json.Decoder, _ fwkplugin.Handle) (fwkplugin.Plugin, error) {
	if raw == nil {
		return nil, errors.New(ScorerType + ": parameters are required")
	}
	raw.DisallowUnknownFields()
	var p scorerParams
	if err := raw.Decode(&p); err != nil {
		return nil, fmt.Errorf("%s: %w", ScorerType, err)
	}
	return NewScorer(name, p)
}

// NewScorer validates parameters and loads curves.
func NewScorer(name string, p scorerParams) (*Scorer, error) {
	pol, err := ParsePolicy(p.Policy)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", ScorerType, err)
	}
	if p.SLOSeconds == nil || !(*p.SLOSeconds > 0) {
		return nil, fmt.Errorf("%s: sloSeconds must be set and positive", ScorerType)
	}
	if p.Headroom == nil || *p.Headroom < 0 || *p.Headroom >= 1 {
		return nil, fmt.Errorf("%s: headroom must be set, in [0, 1)", ScorerType)
	}
	if p.MaxInflight == nil || *p.MaxInflight < 0 {
		return nil, fmt.Errorf("%s: maxInflight must be set (0 means no cap)", ScorerType)
	}
	curves := map[string]*Curve{}
	for gpu, path := range p.Curves {
		c, err := LoadCurve(path)
		if err != nil {
			return nil, fmt.Errorf("%s: %w", ScorerType, err)
		}
		if c.GPUType != gpu {
			return nil, fmt.Errorf("%s: curve %s is for %q, configured as %q", ScorerType, path, c.GPUType, gpu)
		}
		curves[gpu] = c
	}
	if pol.needsCurves() && len(curves) == 0 {
		return nil, fmt.Errorf("%s: policy %s needs curves", ScorerType, pol)
	}
	if name == "" {
		name = ScorerType
	}
	s := &Scorer{
		typedName: fwkplugin.TypedName{Type: ScorerType, Name: name},
		policy:    pol,
		params: Params{SLOSeconds: *p.SLOSeconds, Headroom: *p.Headroom,
			MaxInflight: *p.MaxInflight, Curves: curves},
		typeLabel:  p.TypeLabel,
		indexLabel: p.IndexLabel,
		inflightDK: attrconcurrency.InFlightLoadDataKey.WithNonEmptyProducerName(p.InFlightLoadProducerName),
	}
	if s.typeLabel == "" {
		s.typeLabel = DefaultTypeLabel
	}
	if s.indexLabel == "" {
		s.indexLabel = DefaultIndexLabel
	}
	for _, oc := range []Outcome{Feasible, Saturated, Ungrounded, Misconfigured} {
		Picks.WithLabelValues(string(pol), string(oc)) // export zeros, so absence is visible
	}
	return s, nil
}

// TypedName identifies the plugin instance.
func (s *Scorer) TypedName() fwkplugin.TypedName { return s.typedName }

// Category is Balance: the packing policies concentrate, the others spread.
func (s *Scorer) Category() fwksched.ScorerCategory { return fwksched.Balance }

// Consumes declares the in-flight count. The router confines a scorer to the
// data it declares, so without this the reads below would be refused.
func (s *Scorer) Consumes() fwkplugin.DataDependencies {
	return fwkplugin.DataDependencies{
		Required: map[fwkplugin.DataKey]any{s.inflightDK: attrconcurrency.InFlightLoad{}},
	}
}

type indexed struct {
	ep    fwksched.Endpoint
	index int
	gpu   string
	load  int64
}

// Score applies the policy. Endpoints are put in index-label order first, so
// position i means the same endpoint here as in the Python fleet list.
func (s *Scorer) Score(ctx context.Context, _ *fwksched.InferenceRequest, endpoints []fwksched.Endpoint) map[fwksched.Endpoint]float64 {
	out := make(map[fwksched.Endpoint]float64, len(endpoints))
	eps, err := s.collect(endpoints)
	if err != nil {
		Picks.WithLabelValues(string(s.policy), string(Misconfigured)).Inc()
		log.FromContext(ctx).Error(err, "energy-epp policy cannot decide; scoring every endpoint 0", "policy", s.policy)
		for _, e := range endpoints {
			out[e] = 0
		}
		return out
	}
	var tied []int
	oc := Feasible
	if s.policy == RoundRobin {
		tied = []int{int((s.rr.Add(1) - 1) % uint64(len(eps)))}
	} else {
		types := make([]string, len(eps))
		load := make([]int64, len(eps))
		for i, e := range eps {
			types[i], load[i] = e.gpu, e.load
		}
		tied, oc = Decide(s.policy, types, load, &s.params)
	}
	Picks.WithLabelValues(string(s.policy), string(oc)).Inc()
	for _, e := range eps {
		out[e.ep] = 0
	}
	for _, i := range tied {
		out[eps[i].ep] = 1
	}
	return out
}

func (s *Scorer) collect(endpoints []fwksched.Endpoint) ([]indexed, error) {
	if len(endpoints) == 0 {
		return nil, errors.New("no endpoints")
	}
	eps := make([]indexed, 0, len(endpoints))
	seen := map[int]bool{}
	for _, e := range endpoints {
		md := e.GetMetadata()
		if md == nil {
			return nil, errors.New("endpoint without metadata")
		}
		idx, err := strconv.Atoi(md.Labels[s.indexLabel])
		if err != nil || idx < 0 || seen[idx] {
			return nil, fmt.Errorf("endpoint %s: label %s missing, invalid or duplicate", md.ID, s.indexLabel)
		}
		seen[idx] = true
		gpu := md.Labels[s.typeLabel]
		if s.policy.needsCurves() && s.params.Curves[gpu] == nil {
			return nil, fmt.Errorf("endpoint %s: no curve for %s=%q", md.ID, s.typeLabel, gpu)
		}
		v, ok := e.Get(s.inflightDK)
		load, isLoad := v.(*attrconcurrency.InFlightLoad)
		if !ok || !isLoad || load == nil {
			return nil, fmt.Errorf("endpoint %s: no in-flight count", md.ID)
		}
		eps = append(eps, indexed{ep: e, index: idx, gpu: gpu, load: load.Requests})
	}
	sort.Slice(eps, func(a, b int) bool { return eps[a].index < eps[b].index })
	return eps, nil
}
