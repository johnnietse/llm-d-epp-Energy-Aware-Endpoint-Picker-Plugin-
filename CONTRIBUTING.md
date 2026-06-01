# Contributing to the Energy-Aware EPP

Thank you for your interest in contributing! This guide covers how to work with the codebase and how to submit changes.

## Development Setup

### Prerequisites

- Go 1.25+
- Docker 24+
- kubectl 1.25+
- Kind 0.20+ (for local cluster testing)
- Python 3.10+ (optional, for diagram generation)

### Getting Started

```bash
# Clone the repository
git clone https://github.com/johnnietse/llm-d-epp-Energy-Aware-Endpoint-Picker-Plugin-.git
cd llm-d-epp-Energy-Aware-Endpoint-Picker-Plugin-

# Verify your setup
./scripts/validate-setup.sh --quick

# Run all tests
go test -v ./pkg/...
```

## Project Structure

```
pkg/
├── adaptive/        # FSM controller (Normal/Carbon-Critical/Green modes)
├── config/          # GIE-compatible plugin configuration
├── metrics/         # Prometheus metrics (17 families)
├── plugins/
│   ├── filter/      # SLO + energy budget filters
│   ├── scorer/      # Multi-objective energy scorer (core algorithm)
│   └── scraper/     # DCGM/RAPL telemetry scraper
├── signals/         # EnergyStore, SCI calculator, types
└── simulation/      # 1000-cycle E2E simulation test
upstream-port/       # Bridge file for official llm-d-router integration
```

## Making Changes

### 1. Fork and branch

```bash
git checkout -b feature/your-change
```

### 2. Run tests before committing

```bash
go test -v -race ./pkg/...
go vet ./pkg/...
```

### 3. Commit with conventional commit messages

```
feat: add DVFS frequency scaling to scorer
fix: correct carbon intensity calculation for EU regions
docs: update deployment guide with AKS instructions
test: add edge case for zero-power endpoints
```

### 4. Submit a pull request

Push your branch and open a PR against `main`. CI will automatically run tests.

## Code Guidelines

- **Follow existing patterns**: The scorer plugin follows the same structure as llm-d-router's built-in scorers. Maintain consistency.
- **Keep the upstream-port clean**: The `upstream-port/` directory should only contain code that directly implements the `scheduling.Scorer` interface. All supporting logic stays in `pkg/`.
- **Test everything**: Every new function should have a corresponding test. Target >80% coverage.
- **Document changes**: Update relevant documentation if behavior changes.

## Upstream Contribution

If you want to help get the energy-aware scorer merged into the official [llm-d-router](https://github.com/llm-d/llm-d-router):

1. Read the [llm-d contributing guide](https://github.com/llm-d/llm-d/blob/main/CONTRIBUTING.md)
2. Review the [upstream integration walkthrough](upstream_integration_walkthrough.md)
3. The PR template is at `.github/PULL_REQUEST_TEMPLATE.md`
4. Join the `#sig-router` channel on [llm-d Slack](https://llm-d.slack.com)

## Reporting Issues

Use GitHub Issues for:
- Bug reports (include `go version`, OS, and error output)
- Feature requests (describe the use case)
- Questions (or use Discussions)

## License

By contributing, you agree that your contributions will be licensed under the Apache License 2.0.
