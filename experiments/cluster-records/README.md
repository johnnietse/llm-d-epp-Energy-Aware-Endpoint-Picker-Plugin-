# Cluster records

Every measurement record from the Frontenac runs, pulled off the cluster so the
evidence does not live only in one `$HOME` on a shared system. Fetched
2026-10-07 with `fr-fetchall.sh`.

Before this, the repository held experiment data only through **2026-10-03**.
Everything from 2026-10-04 onward, including both Stage 2 arms and every
heterogeneous run, existed solely on the cluster.

## Layout

| Path | What |
|---|---|
| `results/h1-*` | Stage 1 energy-vs-concurrency sweeps, one directory per job |
| `results/stage2-*` | Homogeneous Stage 2 runs and the smoke/calibration jobs |
| `results/stage2het-*` | Heterogeneous Stage 2 runs |
| `results/hetpre-*`, `results/hetsteps-*` | Heterogeneous pre-flight and launcher probes |
| `results/counter-char-*` | NVML counter characterisation |
| `slurm-logs/*.out` | Slurm job logs: the node, driver and GPU each result came from |
| `instruments-probe/` | Per-node instrument probes behind the measurement protocol |
| `logs/`, `config/` | Harness logs and configuration |

## Compression

Files over 1 MiB named `*.log`, `*.out` or `*.txt` are gzipped: 365 MiB down to
13 MiB, because vLLM server logs are long runs of near-identical lines. They are
kept rather than discarded because they are the only place a readiness stall is
recorded. Job 12303653 is diagnosable solely because its log shows
`Loading safetensors checkpoint shards: 0%` and then nothing for two hours.

Never compressed, because scripts and auditors read them directly and a
diffable history is worth more than the bytes: `policies-rate*.json`,
`instruments.txt`, `telemetry.txt`, `calibration.txt`, the clock-skew files and
the energy sample JSONL.

Decompress one with `gunzip -k file.log.gz`, or read in place with `zcat`.

## Completeness

The first snapshot (2026-10-07, early morning) caught two jobs mid-run. Both
were re-fetched after finishing and are now complete, 5 of 5 rate files each:

- `results/stage2het-12319685` - heterogeneous replication, seed 11
- `results/stage2-12319815` - matched 8-GPU homogeneous control on frnt155

Still running at the time of this update, so not yet here:

- `results/stage2het-12321476` - heterogeneous replication, seed 13
- `results/stage2-12321478` - capacity-matched homogeneous control, 100-300 req/s

Re-fetch only named directories with `bash fr-fetchall.sh <dir> [dir...]`. A
full re-fetch re-downloads every log already gzipped here.

## What is deliberately absent

The cluster `$HOME` also holds ~13 GiB of software: `opt/` (DCGM and Nsight
packages), `images/` (apptainer layers), `.hf` (the model cache), `bin/`, and a
`llm-d-router` checkout. All are re-fetchable from upstream. The measurements
are not, which is the whole reason this directory exists.

## Provenance caveat

A result here is only as good as the run that produced it. Several of these
directories are from jobs that were **discarded**, not published: job 12303327
completed cleanly and every cell was client-limited (112.5 req/s offered, 26.7
achieved). See `docs/plan/FINAL-PLAN-2026-10.md` section 13 for which job ids
are load-bearing and which are kept only as evidence of a failure mode.
