// Package probe is a deliberately inert scorer whose only job is to prove that
// an out-of-tree plugin registers with, is configured by, and is invoked by the
// llm-d-router EPP. It is NOT a routing policy and must never appear in a
// measured arm: it scores every endpoint 1.0, which is neutral by construction.
//
// Why it exists before the real scorer. Stage 2 measured routing rules written
// in the Python load generator. Before porting the winning rule to Go (Stage
// 4), three things had to be shown on Frontenac, each of which had previously
// been asserted from documentation only: the module compiles against the
// router we pin, a static Linux binary can be produced without a Go toolchain
// on the cluster, and the EPP runs in file-discovery mode with no Kubernetes.
// A counter is the evidence for the last one - a log line can be misread, a
// counter that moved cannot.
package probe

import (
	"context"
	"encoding/json"

	"github.com/prometheus/client_golang/prometheus"

	fwkplugin "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/plugin"
	fwksched "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/scheduling"
)

// Type is the name a scheduling profile uses to select this plugin.
const Type = "energy-epp-plumbing-probe"

// Calls counts Score invocations. Exposed on the EPP metrics port through
// runner.WithCustomCollectors, so a smoke test can scrape it.
var Calls = prometheus.NewCounter(prometheus.CounterOpts{
	Name: "energy_epp_probe_score_calls_total",
	Help: "Score() invocations of the inert plumbing probe; proves the out-of-tree plugin is wired in.",
})

var _ fwksched.Scorer = &Scorer{}

// Scorer is the inert probe.
type Scorer struct {
	typedName fwkplugin.TypedName
}

// Factory builds a Scorer from configuration. The probe takes no parameters,
// and refuses any so a config that thinks it is tuning a real policy fails
// loudly instead of being silently ignored.
func Factory(name string, params *json.Decoder, _ fwkplugin.Handle) (fwkplugin.Plugin, error) {
	if params != nil {
		var fields map[string]json.RawMessage
		if err := params.Decode(&fields); err == nil && len(fields) > 0 {
			return nil, errNoParams
		}
	}
	return New(name), nil
}

// New returns a probe with the given instance name.
func New(name string) *Scorer {
	if name == "" {
		name = Type
	}
	return &Scorer{typedName: fwkplugin.TypedName{Type: Type, Name: name}}
}

// TypedName identifies the plugin instance.
func (s *Scorer) TypedName() fwkplugin.TypedName { return s.typedName }

// Category is Distribution: a constant score expresses no locality preference.
func (s *Scorer) Category() fwksched.ScorerCategory { return fwksched.Distribution }

// Score gives every endpoint the same neutral score and records the call.
func (s *Scorer) Score(_ context.Context, _ *fwksched.InferenceRequest, endpoints []fwksched.Endpoint) map[fwksched.Endpoint]float64 {
	Calls.Inc()
	out := make(map[fwksched.Endpoint]float64, len(endpoints))
	for _, e := range endpoints {
		out[e] = 1.0
	}
	return out
}
