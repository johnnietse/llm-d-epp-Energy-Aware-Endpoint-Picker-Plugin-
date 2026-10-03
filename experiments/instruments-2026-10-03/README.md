# Alternative telemetry sources on Frontenac: measured verdicts (2026-10-03)

Question: is NVML still the right choice, or would DCGM, CUPTI, Nsight or IPMI
serve better on this cluster? Answered by running each one rather than by
reading documentation.

Scripts: `../scripts/fetch_instruments.sh` (download + root-free extraction on
the login node), `../scripts/probe_instruments_gpu.sbatch` (the tests, on a
compute node under `--exclusive`).

## Environment

| | |
|---|---|
| OS | Rocky Linux 8.10, host glibc 2.28 |
| Module shell | CVMFS Compute Canada stack, glibc 2.37, Lmod 8.7.47 |
| Bootstrap | `source /cvmfs/soft.computecanada.ca/config/profile/bash.sh` |
| Container runtime | `module load apptainer/1.4.5` |
| Driver | 610.43.02 |
| Node | `frnt152`, 4x Quadro RTX 6000, exclusive, no co-tenant processes |
| Job | 12302443, COMPLETED, 00:01:02, `ConsumedEnergy=0` |

## Verdicts

| Source | Result |
|---|---|
| **NVML** | Works unprivileged. Remains the primary source. |
| **DCGM** | **Refuses every field as non-root**, power and energy included. Unusable here. |
| **Nsight Systems** | Binary runs; counter collection restricted, `perf_event_paranoid` 2, system-wide profiling Fail. |
| **CUPTI** | `RmProfilingAdminOnly: 1`, so counters are denied. Tracing untested (script bug, see below). |
| **IPMI** | `/dev/ipmi0` **exists**, mode 0600 root-owned. Hardware present, permission-gated. |

## The decisive DCGM error

```
level=INFO  msg="DCGM successfully initialized!"
level=INFO  msg="NVML provider successfully initialized"
level=INFO  msg="Successfully queried DCGM profiling metric groups" count=7 gpu_model="Quadro RTX 6000"
level=ERROR msg="Failed to watch DCGM fields"
            field_ids="[100 101 140 150 155 156 ... 1005 1009 1010 1]"
            error="error watching fields: Host engine is running as non-root"
```

Initialisation, NVML attachment and profiling-group discovery all succeed. The
refusal is at the field-watch call and it covers the entire field list, not
just the profiling subset. Embedded mode does not help, because `dcgm-exporter`
already *is* embedded mode.

## Packaging notes, so nobody repeats the hour

- `datacenter-gpu-manager-4-core-4.7.0` is a 13 KB payload-free metapackage.
  The newest `-core` shipping `libdcgm.so.4` is **4.6.1**, established by
  querying the repo's `primary.xml.gz` for the providing package.
- DCGM 3.3.9 is one self-contained 816 MB RPM, but a user-space extraction
  registers only the `topo` subsystem.
- `dcgmi` wants the subsystem **before** `--host`. Reversed, it prints
  `ERROR: Invalid subsystem`, which reads like a privilege error and is not.
- RHEL8 RPMs, not Ubuntu debs: these are Rocky 8 nodes.

## Field identifiers (from `dcgm_fields.h`, correcting plan v1)

| Field | ID | Note |
|---|---|---|
| `DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION` | **156** | millijoules; **not** deprecated |
| `DCGM_FI_DEV_POWER_USAGE` | 155 | watts |
| `DCGM_FI_PROF_SM_ACTIVE` | 1002 | profiling, denied |
| `DCGM_FI_PROF_DRAM_ACTIVE` | 1005 | profiling, denied |

There is no `DCGM_FI_DEV_GPU_ENERGY_JOULES_TOTAL` and no field 1611. Plan v1
asserted both; both were wrong and are corrected.

## Per-die idle spread (input to plan section 13.5)

One `nvidia-smi` call, all four dies, same instant:

| GPU | UUID prefix | Idle power | Temp | SM clock |
|---|---|---|---|---|
| 0 | `GPU-ce3f5de7` | 21.95 W | 25 C | 300 MHz |
| 1 | `GPU-55fdeae3` | 22.29 W | 24 C | 300 MHz |
| 2 | `GPU-e1ef0a37` | 22.68 W | 23 C | 300 MHz |
| 3 | `GPU-ff881352` | 13.04 W | 20 C | 300 MHz |

GPU 3 is 1.69x lower than GPU 2. **Not a finding yet**: GPU 3 is also the
coolest die, so residual power state is an unexcluded explanation. Section 13.5
of the plan specifies the matched-load, randomised, repeated-measures version
that would settle it, including the within-die negative control.

## Pending (script bugs, not cluster limits)

1. **CUPTI tracing.** The container test called `python`; the vLLM image
   provides `python3`. `RmProfilingAdminOnly` gates counters, so tracing may
   still work. Worth one re-run.
2. **`nsys` trace versus counters.** Same distinction, to be tested by
   profiling an actual matmul rather than reading `nsys status`.

Neither affects the NVML decision.

## Other settled facts

- `--exclusive` delivers whole nodes with no co-tenants (`frnt148`, `frnt152`).
- `nvidia-smi -pl 150` returns "Insufficient Permissions"; the RTX 6000 reports
  min 150 W / max 250 W, so a 1.67x controlled envelope needs CAC.
- Persistence mode enabled on all GPUs.
- `frnt152` advertises `intel,avx512,avx512_gpu` and **not** `power_ipmi`; that
  feature is on frnt140-147, so the CAC ask must name those nodes.
- `AcctGatherEnergyType = (null)`, `AcctGatherNodeFreq = 0 sec`.

## Disk cost

`~/energy-epp/opt` is 5.3 GB (DCGM 3.3.9, DCGM 4.6.1 + 4.7.0 modules, DCGM
exporter 4.8.4, Nsight Systems 2025.6.3, plus the downloaded RPMs). Removable
with `rm -rf ~/energy-epp/opt`.
