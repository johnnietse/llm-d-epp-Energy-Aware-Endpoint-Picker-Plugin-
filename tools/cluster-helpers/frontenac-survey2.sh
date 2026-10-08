#!/bin/bash
echo "=== ACCOUNTS UNDER sg6079000 ==="
sacctmgr -p show assoc account=sg6079000_cpu format=Account,User,Partition,QOS 2>&1 | head -10
sacctmgr -p show assoc account=sg6079000_gpu format=Account,User,Partition,QOS 2>&1 | head -10
echo
echo "=== MY SHARE / ALL MY ASSOCS ==="
sshare -U 2>&1 | head -10
sacctmgr -p show user $USER withassoc format=User,Account,Partition,QOS,DefaultAccount 2>&1 | head -10
echo
echo "=== PARTITION ACCESS RULES ==="
for p in gpu-L4 gpu-rgrant gpubase_6hrs gpubase_interac teaching cpubase_6hrs; do
  echo "--- $p ---"
  scontrol show partition $p 2>&1 | grep -E "PartitionName|AllowGroups|AllowAccounts|AllowQos|MaxTime|Nodes=|State=" | head -6
done
echo
echo "=== L4 / L40S / A30 NODE FEATURES ==="
sinfo -N -o "%N|%P|%G|%f" 2>&1 | grep -iE "L4|L40S|a30|a100" | sort -u | head -20
echo
echo "=== PROJECT DIR ACCESS TEST ==="
ls /global/teaching-project/sg6079000 2>&1 | head -5
echo "--- my home ---"
ls -ld $HOME; df -h $HOME 2>&1 | tail -1
du -sh $HOME 2>/dev/null | tail -1
