# deploy/ from the first design: Kubernetes manifests, never used for a result

This folder was `deploy/` at the repository root until 2026-10-09. It was moved
here unchanged with `git mv`; the tag `archive-2026-10-09-pre-amendment` keeps
the previous layout.

It deploys the **first design's** EPP (`cmd/energy-epp`, built from `pkg/`):
- a local Kind cluster;
- a **simulated** heterogeneous pool, labelled as H100, A100 and Qualcomm
  Cloud AI hardware classes (`GPU_HIGH_PERF`, `GPU_MED_PERF`,
  `ASIC_LOW_POWER`). The project never had the H100 or the ASIC;
- example configurations with carbon and prefill/decode weights;
- a Grafana dashboard.

No measured result came from any of it. The measurements ran on a Slurm
cluster with no Kubernetes. The router path used there is llm-d-router
v0.11.0's EPP in file-discovery mode behind Envoy, built by
`router-plugin/build.sh` and documented in `router-plugin/README.md` and
`QUICKSTART.md` section 4.
