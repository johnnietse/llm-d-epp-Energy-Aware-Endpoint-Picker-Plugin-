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
| `fr-fetchall.sh [dir...]` | Pulls records. Name directories to avoid re-downloading logs already gzipped locally. Then run `experiments/scripts/prepare_records.sh <dir>` before committing. |
| `fr-check.sh` | Checks the shared connection without ever prompting (`ssh -O check`, then a `BatchMode` command). |
| `fr-wait.sh <max-s> <id>...` | Waits until `sacct` shows every job in a terminal state, then prints the states. A short or empty reply counts as a failed poll, never as done. Run it in the background. |
| `fr-wait-start.sh <id> <max-s>` | Reports when a job leaves PENDING, reading `sacct`, so a job that started or finished before the watcher was armed is still reported (and flagged as such). |
| `fr-node-users.sh` | Who is on frnt149/154/155. The end column is `ENDS_NO_LATER_THAN` (start + limit), and our pending jobs' `--start` is a latest-start bound. Neither is a forecast. |
| `fr-ls-results.sh` | Lists the cluster's result directories, so you can confirm that every one is in the repository. |

Cluster-side submit scripts live in `experiments/scripts/` and run through
`fr-sync.sh run <script>`: `het_submit.sh`, `real_submit.sh`,
`curves256_submit.sh`, `curves6_submit.sh` and `calib_submit.sh`.

**Calling these from Git Bash on Windows.** Prefix the call with
`MSYS_NO_PATHCONV=1`, as in
`MSYS_NO_PATHCONV=1 wsl.exe -- bash /mnt/c/Users/Johnnie/fr-sync.sh run verify_fixes.sh`.
Without it, Git Bash rewrites Unix paths such as `/home/...` or `/mnt/...`
into Windows paths before WSL sees them. ssh then finds no control socket and
hangs at a password prompt (2026-10-09).

## Superseded or one-off

All other scripts here are kept as history, including the one-off
`fr-hold-calib-2026-10-09.sh`, `fr-cancel-calib-2026-10-09.sh` and
`fr-date-check-2026-10-09.sh`, which name specific job ids. Several of them, `fr-cmd.sh`,
`fr-cmd2.sh`, `fr-exec*.sh` and `fr-run-remote.sh` among them, build remote
commands inline through `wsl.exe` and `ssh`. That pattern corrupted five runs:
newlines turned into quote pairs, and `$USER` was expanded on the local WSL
side, where the username is `ohnnie`, instead of on the cluster (plan section
3.4). Do not copy that pattern. Put the remote command in a script file under
`experiments/scripts/` and run it with `fr-sync.sh run`.
