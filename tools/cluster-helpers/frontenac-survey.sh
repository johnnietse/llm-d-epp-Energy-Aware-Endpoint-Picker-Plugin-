#!/bin/bash
echo "=== WHOAMI ==="
id
hostname
echo
echo "=== SLURM ASSOCIATIONS ==="
sacctmgr -p show assoc user=$USER format=Account,Partition,QOS,MaxWall,GrpTRES 2>&1 | head -30
echo
echo "=== PARTITIONS ==="
sinfo -o "%20P %10l %6D %24G %N" 2>&1 | head -30
echo
echo "=== frnt201 ==="
scontrol show node frnt201 2>&1 | head -20
echo
echo "=== GPU NODES ==="
sinfo -N -o "%N|%P|%G|%c|%m" 2>&1 | grep -v "null" | sort -u | head -30
echo
echo "=== RESERVATIONS ==="
scontrol show res 2>&1 | head -20
echo
echo "=== STORAGE ==="
ls -ld /global/teaching-project/sg6079000 2>&1
df -h /global/teaching-project/sg6079000 2>&1 | tail -2
quota -s 2>&1 | tail -6
echo
echo "=== MODULES (apptainer/cuda/go/python) ==="
module avail 2>&1 | grep -iE "apptainer|singularity|cuda|^go|python" | head -20
echo
echo "=== MY RECENT JOBS ==="
sacct -X --starttime now-30days --format=JobID,Account,Partition,NodeList,State,Elapsed 2>&1 | head -15
