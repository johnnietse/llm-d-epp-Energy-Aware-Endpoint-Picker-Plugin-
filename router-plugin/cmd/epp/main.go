// Command epp is the llm-d-router endpoint picker with this project's
// out-of-tree plugins registered. Everything except the Register calls is the
// upstream runner, unchanged, so behaviour differences between this binary and
// stock llm-d come only from plugins a config explicitly selects.
package main

import (
	"os"

	ctrl "sigs.k8s.io/controller-runtime"

	"github.com/llm-d/llm-d-router/cmd/epp/runner"

	"github.com/johnnie/energy-aware-epp/router-plugin/pkg/probe"
)

func main() {
	os.Exit(run())
}

func run() int {
	// ctrl.SetupSignalHandler comes from controller-runtime, a Kubernetes
	// library, but only for SIGTERM/SIGINT handling; it does not need a
	// cluster. This mirrors upstream cmd/epp/main.go exactly.
	ctx := ctrl.SetupSignalHandler()

	probe.Register()

	if err := runner.NewRunner().
		WithExecutableName("energy-epp").
		WithCustomCollectors(probe.Calls).
		Run(ctx); err != nil {
		return 1
	}
	return 0
}
