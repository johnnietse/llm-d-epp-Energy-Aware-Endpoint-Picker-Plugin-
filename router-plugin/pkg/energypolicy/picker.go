package energypolicy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand/v2"
	"sort"
	"sync"

	fwkplugin "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/plugin"
	fwksched "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/scheduling"
)

// PickerType is the name an EPP config uses to select the tie-break picker.
const PickerType = "energy-epp-seeded-random-picker"

var _ fwksched.Picker = &Picker{}

type pickerParams struct {
	Seed *uint64 `json:"seed"`
}

// Picker chooses uniformly among the highest-scored endpoints, from a stream
// seeded per trial (amendment B5). It replaces upstream's max-score-picker,
// whose ties rotate through a process-wide counter: neither random nor
// reproducible from a trial seed.
//
// Candidates arrive in map order, which Go randomises per process. They are
// sorted by endpoint name before the draw, so a seed fixes the choice.
type Picker struct {
	typedName fwkplugin.TypedName
	mu        sync.Mutex
	rng       *rand.Rand
}

// PickerFactory builds a Picker; the seed is required.
func PickerFactory(name string, raw *json.Decoder, _ fwkplugin.Handle) (fwkplugin.Plugin, error) {
	if raw == nil {
		return nil, errors.New(PickerType + ": parameters are required (seed)")
	}
	raw.DisallowUnknownFields()
	var p pickerParams
	if err := raw.Decode(&p); err != nil {
		return nil, fmt.Errorf("%s: %w", PickerType, err)
	}
	if p.Seed == nil {
		return nil, errors.New(PickerType + ": seed must be set")
	}
	return NewPicker(name, *p.Seed), nil
}

// NewPicker returns a picker seeded with seed.
func NewPicker(name string, seed uint64) *Picker {
	if name == "" {
		name = PickerType
	}
	return &Picker{
		typedName: fwkplugin.TypedName{Type: PickerType, Name: name},
		rng:       rand.New(rand.NewPCG(seed, seed^0x9e3779b97f4a7c15)),
	}
}

// TypedName identifies the plugin instance.
func (p *Picker) TypedName() fwkplugin.TypedName { return p.typedName }

// Pick returns one endpoint drawn uniformly from those with the top score.
func (p *Picker) Pick(_ context.Context, scored []*fwksched.ScoredEndpoint) *fwksched.ProfileRunResult {
	if len(scored) == 0 {
		return &fwksched.ProfileRunResult{}
	}
	top := scored[0].Score
	for _, s := range scored[1:] {
		if s.Score > top {
			top = s.Score
		}
	}
	var cands []*fwksched.ScoredEndpoint
	for _, s := range scored {
		if s.Score == top {
			cands = append(cands, s)
		}
	}
	sort.Slice(cands, func(a, b int) bool { return name(cands[a]) < name(cands[b]) })
	p.mu.Lock()
	i := p.rng.IntN(len(cands))
	p.mu.Unlock()
	return &fwksched.ProfileRunResult{TargetEndpoints: []fwksched.Endpoint{cands[i].Endpoint}}
}

func name(s *fwksched.ScoredEndpoint) string {
	if md := s.GetMetadata(); md != nil {
		return md.ID.String()
	}
	return s.String()
}
