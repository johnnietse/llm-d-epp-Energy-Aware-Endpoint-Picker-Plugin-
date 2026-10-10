#!/usr/bin/env bash
# Who is on our pinned nodes, and the LATEST their jobs can end.
#
# squeue's %e "END_TIME" for a running job is start + time limit: an upper
# bound, not a forecast. On 2026-10-10 a column of 05:11 end times was quoted
# as "our jobs start about 05:15"; those jobs ran for minutes and ours started
# at 02:30. The column is relabelled here so it cannot be read that way again.
# Our own jobs' --start estimate has the same limit: it is a latest-start
# bound computed from other jobs' limits.
SOCK="$HOME/.ssh/cm-frontenac-hpc6081"; HOST="hpc6081@login.cac.queensu.ca"
timeout 60 ssh -S "$SOCK" -o BatchMode=yes "$HOST" '
printf "%10s %9s %8s %10s %10s %22s %12s %s\n" JOBID USER STATE RAN LIMIT "ENDS_NO_LATER_THAN" NODES GRES
squeue -h -w frnt149,frnt154,frnt155 -o "%.10i %.9u %.8T %.10M %.10l %.22e %.12N %b"
echo "--- our pending jobs: Slurm latest-start bound (they can start any time sooner)"
squeue -h -u hpc6081 -t PENDING --start -o "%.10i %.22j %.22S" | head -20'
