package energypolicy

import fwkplugin "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/plugin"

// Register adds the policy scorer and the seeded picker to the router's
// plugin registry. Alpha: the EPP loads them only with
// --allow-experimental-plugins, as for the probe.
func Register() {
	fwkplugin.Register(ScorerType, fwkplugin.StabilityAlpha, ScorerFactory)
	fwkplugin.Register(PickerType, fwkplugin.StabilityAlpha, PickerFactory)
}
