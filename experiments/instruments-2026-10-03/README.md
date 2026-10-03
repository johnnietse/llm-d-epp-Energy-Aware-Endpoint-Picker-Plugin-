# Alternative telemetry sources on Frontenac: measured verdicts (2026-10-03)

Question: is NVML still the right choice, or would DCGM, CUPTI, Nsight or IPMI
serve better on this cluster? Answered by running each one.

Scripts: `../scripts/fetch_instruments.sh` (download + root-free extraction on
the login node), then `probe_instruments_gpu.sbatch`,
`probe_dcgm_exporter.sbatch`, `probe_dcgm_fields.sbatch`,
`probe_dcgm_isolate.sbatch`, `probe_dcgm_pernode.sbatch`.

## Environment

| | |
|---|---|
| OS | Rocky Linux 8.10, host glibc 2.28 |
| Module shell | CVMFS Compute Canada stack, glibc 2.37, Lmod 8.7.47 |
| Bootstrap | `source /cvmfs/soft.computecanada.ca/config/profile/bash.sh` |
| Container runtime | `module load apptainer/1.4.5` |
| Driver | 610.43.02 on every node tested |
| Nodes | `frnt148`, `frnt149`, `frnt152`, each 4x Quadro RTX 6000, `--exclusive` |
| Jobs | 12302443, 12302774, 12302779, 12302781, 12302784, 12302788, 12302790, 12302791 |

## Headline

**NVML stays primary**, because it is the only source that worked on every node
and needs no privilege. But the reason is more interesting than expected:

> **Instrumentation permission is not uniform across nodes of this cluster.**

| Node | `RmProfilingAdminOnly` | Kernel | Profiling fields | `dcgm-exporter` (shipped CSV) |
|---|---|---|---|---|
| `frnt148` | **0** | 4.18.0-553.**45**.1 | 1002/1003/1004/1005/1009/1010 all readable | UP, 80 series, 20 profiling |
| `frnt149` | **1** | 4.18.0-553.**148**.1 | all denied, `Result: -29` | dies at startup |

### Cluster survey: how common is each state?

`survey_profiling_permission.sh` read the bit directly on every GPU node that
would take a one-CPU job. 15 answered:

```
  RmProfilingAdminOnly=0 on  2 node(s)   (frnt148, frnt110)
  RmProfilingAdminOnly=1 on 13 node(s)
```

**It does not track the kernel build**, so the "permissive nodes are just
behind on patching" explanation is wrong:

| Count | Bit | Kernel |
|---|---|---|
| 1 | 0 | 4.18.0-553.148.1 |
| 1 | 0 | 4.18.0-553.45.1 |
| 5 | **1** | 4.18.0-553.**148.1** |
| 8 | 1 | 4.18.0-553.150.1 |

`frnt110` is permissive on the same kernel five restricted nodes run. This is
per-node configuration drift. Permissive nodes are a ~13% minority and the
exceptions look accidental, so nothing may depend on profiling counters.

### Driver version also varies per node

| Driver | Seen on |
|---|---|
| 580.173.02 | frnt110 (V100) |
| 610.43.02 | frnt108, frnt109, frnt140, frnt148, frnt149, frnt151 |
| 610.57.04 | frnt107, frnt142-147, frnt150 |

This matters more for the measurements than the profiling bit does. Counter
sampling behaviour is a driver and architecture property, so two runs on the
same GPU model under different drivers are not automatically comparable.
Driver version is promoted from a recorded detail to a blocking comparability
variable, pinned or verified like GPU model.

Energy (**156**) and power (**155**) were readable on **both** nodes tested,
with and without root.

## Verdicts

| Source | Result |
|---|---|
| **NVML** | Works everywhere, unprivileged. Primary. |
| **DCGM energy/power** | Work everywhere, unprivileged. |
| **DCGM profiling fields** | Node-dependent, per the table above. |
| **dcgm-exporter** | Serves all 80 series unprivileged on a permissive node. Refuses to start on a restricted one, because the shipped counter file requests profiling fields. |
| **CUPTI tracing** | Works even on a restricted node: `CUPTI OK: captured 17 events carrying device time`. |
| **Nsight tracing** | Works: `nsys profile --trace=cuda` wrote a 939 KB report. |
| **CUPTI/Nsight counters** | Denied where `RmProfilingAdminOnly=1`. `nsys status -e`: CPU process-tree OK, system-wide Fail, `perf_event_paranoid` 2. |
| **IPMI** | `/dev/ipmi0` exists as `crw------- root root`. Hardware present, permission-gated. |

## DCGM and NVML read the same counter

One die, NVML sampled either side of DCGM:

```
NVML before   164901081136 mJ
DCGM (156)    164901192038 mJ
NVML after    164901212094 mJ
```

DCGM's value falls between the NVML values, so field 156 is the NVML counter
surfaced through DCGM, **not** an independent sensor. Adding DCGM does not give
a second opinion on energy. The only genuinely independent cross-check
available would be node-level IPMI, which is why that CAC ask matters.

## The denial, when it happens

```
Error setting watches. Result: -29: Unable to watch one or more of the
requested fields because doing so requires the host engine to be running as root.
```

and from the exporter:

```
error="error watching fields: Host engine is running as non-root"
```

## Two errors in the first version of this file

Both are recorded rather than quietly fixed.

1. **"DCGM refuses every field as non-root."** Wrong. It came from a `dcgmi`
   call with arguments in the wrong order; `dcgmi` wants the subsystem
   **before** `--host`, and the reversed form prints `ERROR: Invalid subsystem`,
   which reads like a privilege error. Correct syntax reads energy and power
   without root.
2. **Generalising from one node.** The exporter failure was real but was on
   `frnt152`. Four follow-up conditions on `frnt148` (clean, after a killed
   standalone host engine, with one still running, and with dcgm3 libraries
   ahead of dcgm4) all passed, which is what exposed the mistake. Only the
   per-node probe explained it.

## Packaging notes, so nobody repeats the hour

- `datacenter-gpu-manager-4-core-4.7.0` is a 13 KB payload-free metapackage.
  The newest `-core` shipping `libdcgm.so.4` is **4.6.1**, established by
  querying the repo's `primary.xml.gz` for the providing package.
- DCGM 3.3.9 is one self-contained 816 MB RPM, but a user-space extraction
  registers only the `topo` subsystem.
- RHEL8 RPMs, not Ubuntu debs: these are Rocky 8 nodes.
- The exporter's counter-file flag is `-f` / `--collectors`.
- Do not hand-write field names into a counter CSV. `DCGM_FI_DEV_MEMORY_CLOCK`
  does not exist (it is `DCGM_FI_DEV_MEM_CLOCK`), and one bad name aborts the
  exporter before it reaches the privilege question. Filter the shipped CSV
  instead.
- `DCGM_FI_PROF_SM_ACTIVE` is commented out in the shipped
  `default-counters.csv`, which is why that file never requests the field most
  likely to need privilege.

## Field identifiers (from `dcgm_fields.h`, correcting plan v1)

| Field | ID |
|---|---|
| `DCGM_FI_DEV_TOTAL_ENERGY_CONSUMPTION` | **156** (mJ, current, not deprecated) |
| `DCGM_FI_DEV_POWER_USAGE` | 155 |
| `DCGM_FI_PROF_SM_ACTIVE` | 1002 |
| `DCGM_FI_PROF_GR_ENGINE_ACTIVE` | 1003 |
| `DCGM_FI_PROF_PIPE_TENSOR_ACTIVE` | 1004 |
| `DCGM_FI_PROF_DRAM_ACTIVE` | 1005 |
| `DCGM_FI_PROF_PCIE_TX_BYTES` | 1009 |
| `DCGM_FI_PROF_PCIE_RX_BYTES` | 1010 |

There is no `DCGM_FI_DEV_GPU_ENERGY_JOULES_TOTAL` and no field 1611. Plan v1
asserted both.

## Per-die idle spread (input to plan section 13.5)

`frnt152`, one `nvidia-smi` call, all four dies, same instant:

| GPU | UUID prefix | Idle power | Temp | SM clock |
|---|---|---|---|---|
| 0 | `GPU-ce3f5de7` | 21.95 W | 25 C | 300 MHz |
| 1 | `GPU-55fdeae3` | 22.29 W | 24 C | 300 MHz |
| 2 | `GPU-e1ef0a37` | 22.68 W | 23 C | 300 MHz |
| 3 | `GPU-ff881352` | 13.04 W | 20 C | 300 MHz |

GPU 3 is 1.69x lower than GPU 2. **Not a finding**: GPU 3 is also the coolest
die, so residual power state is unexcluded. `frnt149` idle dies spanned
12.67-15.47 W, a different spread again. Plan section 13.5 specifies the
matched-load, randomised, repeated-measures design with a within-die negative
control that would settle it.

## Consequences for the measurement campaign

1. `RmProfilingAdminOnly` must be recorded in `instruments.txt` for every run.
2. `-C` or `-w` pinning is required for telemetry comparability, not only for
   hardware comparability. Blocking defect B1 has a sibling: permission varies
   between runs.
3. No claim may depend on profiling fields. `frnt148` is on an older kernel
   than `frnt149`, so its permissive setting looks like a node that is behind
   rather than a deliberate grant, and it could vanish on reboot.

## Other settled facts

- `--exclusive` delivers whole nodes with no co-tenants.
- `nvidia-smi -pl 150` returns "Insufficient Permissions"; the RTX 6000 reports
  min 150 W / max 250 W.
- Persistence mode enabled on all GPUs.
- `frnt152` advertises `intel,avx512,avx512_gpu` and not `power_ipmi`; that
  feature is on frnt140-147.
- `AcctGatherEnergyType = (null)`, `AcctGatherNodeFreq = 0 sec`,
  `ConsumedEnergy=0` on every job.

## Disk cost

`~/energy-epp/opt` is 5.3 GB. Remove with `rm -rf ~/energy-epp/opt`.
