# Cluster helpers

The local-side scripts that drive Frontenac from a Windows machine through WSL:
they open the shared SSH connection, push scripts, submit jobs, wait on them and
fetch results. Until 2026-10-08 they existed only in `C:\Users\Johnnie\`,
outside git, so losing that machine would have lost the only record of how
every job in `experiments/cluster-records/` was launched. They are copied here
as they were, including superseded ones, so history stays readable.

They run from `C:\Users\Johnnie\` (paths such as
`/mnt/c/Users/Johnnie/llm-d-epp-energy` are hard-coded) and share one SSH
control socket, `~/.ssh/cm-frontenac-hpc6081`. No credentials are stored in any
of them. You type the password and OTP into `frontenac-connect-hpc6081.sh`
yourself.

## Current

| Script | Purpose |
|---|---|
| `frontenac-connect-hpc6081.sh` | Opens and holds the shared SSH connection. You type the password, then the OTP. |
| `fr-sync.sh` | Pushes `experiments/scripts/*` to the cluster; `run <script> [args]` also runs one there. |
| `fr-hetsubmit.sh [seed]` | Heterogeneous Stage 2 trial. **Never pass a dependency**: het jobs record CANCELLED, so `afterok` never releases. |
| `fr-realsubmit.sh [seed] [node] [rates]` | Homogeneous control on frnt155. |
| `fr-smokesubmit.sh` | Ships the EPP binary with its sha256 and submits the router smoke test. |
| `fr-hetwait.sh <max-s> het:<id> real:<id>` | Waits on named jobs by `QUEUED_COUNT`, then reports each with the right tool. |
| `fr-jobwait.sh <max-s> "<ids>" <script> [args]` | Generic wait-then-run. |
| `fr-fetchall.sh [dir...]` | Pulls records. Name directories to avoid re-downloading logs already gzipped locally. |

## Superseded or one-off

All other scripts here are kept as history. Several of them, `fr-cmd.sh`,
`fr-cmd2.sh`, `fr-exec*.sh` and `fr-run-remote.sh` among them, build remote
commands inline through `wsl.exe` and `ssh`. That pattern corrupted five runs:
newlines turned into quote pairs, and `$USER` arrived as `ohnnie` (plan section
3.4). Do not copy that pattern. Put the remote command in a script file under
`experiments/scripts/` and run it with `fr-sync.sh run`.
