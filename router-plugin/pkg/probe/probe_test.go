package probe

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/prometheus/client_golang/prometheus/testutil"

	fwkdl "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/datalayer"
	fwkplugin "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/plugin"
	fwksched "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/scheduling"
)

func endpoint(name string) fwksched.Endpoint {
	return fwksched.NewEndpoint(&fwkdl.EndpointMetadata{Name: name, Address: "127.0.0.1", Port: "8000"},
		fwkdl.NewMetrics(), nil)
}

func TestScoreIsNeutralAndCounted(t *testing.T) {
	s := New("")
	eps := []fwksched.Endpoint{endpoint("a"), endpoint("b"), endpoint("c")}
	before := testutil.ToFloat64(Calls)

	got := s.Score(context.Background(), nil, eps)

	if len(got) != len(eps) {
		t.Fatalf("scored %d endpoints, want %d", len(got), len(eps))
	}
	for _, e := range eps {
		if got[e] != 1.0 {
			t.Errorf("score for %s = %v, want 1.0: a probe that prefers an endpoint is a policy", e, got[e])
		}
	}
	if after := testutil.ToFloat64(Calls); after != before+1 {
		t.Errorf("Calls moved %v -> %v, want exactly +1", before, after)
	}
}

func TestTypedNameDefaultsToType(t *testing.T) {
	if got := New("").TypedName(); got.Type != Type || got.Name != Type {
		t.Errorf("TypedName() = %+v, want type and name %q", got, Type)
	}
	if got := New("custom").TypedName().Name; got != "custom" {
		t.Errorf("instance name = %q, want %q", got, "custom")
	}
}

func TestFactoryRefusesParameters(t *testing.T) {
	dec := fwkplugin.StrictDecoder(json.RawMessage(`{"weight": 2}`))
	if _, err := Factory("x", dec, nil); err == nil || !strings.Contains(err.Error(), "takes no parameters") {
		t.Fatalf("Factory with parameters returned err=%v; it must refuse so nobody mistakes the probe for a tunable policy", err)
	}
	if _, err := Factory("x", nil, nil); err != nil {
		t.Fatalf("Factory without parameters failed: %v", err)
	}
}

func TestRegistersUnderType(t *testing.T) {
	Register()
	if _, ok := fwkplugin.Registry[Type]; !ok {
		t.Fatalf("type %q missing from the router's plugin registry after Register()", Type)
	}
	if got := fwkplugin.RegistryMetadata[Type].Stability; got != fwkplugin.StabilityAlpha {
		t.Errorf("stability = %q, want Alpha: the EPP must be started with --allow-experimental-plugins", got)
	}
}
