package probe

import fwkplugin "github.com/llm-d/llm-d-router/pkg/epp/framework/interface/plugin"

// Register adds the probe to the router's global plugin registry. Alpha
// stability means the EPP refuses to load it unless started with
// --allow-experimental-plugins, which is the correct default for anything
// that is not a measured policy.
func Register() {
	fwkplugin.Register(Type, fwkplugin.StabilityAlpha, Factory)
}
