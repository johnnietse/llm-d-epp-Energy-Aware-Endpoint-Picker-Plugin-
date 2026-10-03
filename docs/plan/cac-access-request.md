# Draft: CAC access request (account sa6079052)

Send to `cac.help@queensu.ca`, referencing ticket #17312. CC the QHPC
co-presidents and Curtis Shorts (PI) since the group membership is theirs to
approve.

Evidence below was collected on 2026-10-02 from the Frontenac login node.

---

**Subject:** sa6079052 lost group/account access on sg6079000 (ref #17312)

Hello CAC team,

I am a member of the QHPC club and use account `sa6079052` on Frontenac. I
can log in, but I can no longer submit jobs, and I think my Unix group
membership was dropped during the teaching-account cleanup mentioned in
ticket #17312.

What I see from the login node:

```
$ id
uid=6079052(sa6079052) gid=6079052(sa6079052) \
groups=6079052(sa6079052),612200022(slurm_workers),612200059(frnt_user),612200158(login_nodes)

$ srun -p cpubase_6hrs -c 1 --mem=1G -t 00:01:00 hostname
srun: error: Unable to allocate resources: User's group not permitted to use this partition

$ srun -A sg6079000_cpu -p gpu-L4 --gres=gpu:1 -t 00:02:00 nvidia-smi
srun: error: You are not a member of the specified account sg6079000.

$ ls /global/teaching-project/sg6079000
ls: cannot open directory '/global/teaching-project/sg6079000': Permission denied
```

The Slurm association still exists (`sacctmgr show assoc user=sa6079052`
returns `sg6079000_cpu|frontenac|normal`, with prior usage recorded), so it
looks like only the Unix group membership is missing.

Could you please:

1. **Restore `sa6079052` to the `sg6079000` group**, so partition access and
   the shared project directory work again.
2. **Add `sa6079052` to the `sg6079000_gpu` association.** It currently lists
   `hpc6079, sa6079001, sa6079009, sa6079011, sa6079019, sa6079049,
   sa6079053`, and I am not on it. Ticket #17312 says teaching accounts now
   get both CPU and GPU allocations by default.

Two related questions, for planning research runs on the club's node:

3. **Job length on frnt201.** Ticket #17312 mentions QHPC jobs can run up to
   14 days, but `scontrol show partition gpu-L4` reports
   `MaxTime=06:00:00`, and I do not see a `gpu-rgrant` partition. Which
   partition or QOS carries the longer limit for QHPC members?
4. **Reservations for measurement runs.** My project measures GPU energy per
   inference request, so results are only valid when no other job shares the
   GPUs. Beyond the club's weekly meeting reservation, would it be possible
   to book occasional short exclusive windows on frnt201 (and sometimes
   frnt206, the L40S node) for benchmarking? I am happy to schedule these at
   low-usage times and to keep them short.

5. **Per-job energy accounting on frnt140-147.** `scontrol show config` reports
   `AcctGatherEnergyType = (null)`, and `sacct` duly returns
   `ConsumedEnergy=0` for my jobs. The hardware path looks to be in place
   already: on a compute node, `/dev/ipmi0` exists as
   `crw------- 1 root root 243, 0`, and frnt140-147 advertise a `power_ipmi`
   feature. Since `slurmd` runs as root, enabling
   `AcctGatherEnergyType=acct_gather_energy/ipmi` on those nodes would expose
   per-job node energy through `sacct` without granting any user direct access
   to the BMC. That would give me an independent check on the GPU energy
   counters, which is the single most useful thing for the validity of my
   measurements. I am not asking for access to `/dev/ipmi0` itself.
6. **GPU power limit on a reserved node.** The Quadro RTX 6000 reports
   `power.min_limit 150.00 W` and `power.max_limit 250.00 W`, but
   `nvidia-smi -pl` returns "Insufficient Permissions". If you could either
   allow this on a reserved node or pre-apply a lowered limit for a booked
   window, I could compare identical GPUs at two power envelopes, a 1.67x
   range. That is a considerably cleaner experiment than comparing different
   GPU models, since it holds everything except the power budget constant.
7. **A question rather than a request: GPU profiling permission differs
   between nodes.** On frnt148, `/proc/driver/nvidia/params` reports
   `RmProfilingAdminOnly: 0` and DCGM's profiling counters are readable by an
   ordinary user. On frnt149 the same parameter is `1` and the same reads are
   refused. Both are Quadro RTX 6000 nodes on driver 610.43.02; frnt148 is
   running an older kernel (4.18.0-553.45.1 against 4.18.0-553.148.1), which
   makes me suspect frnt148 is simply behind rather than deliberately
   permissive.

   I do not need these counters: my measurements use NVML, which works
   everywhere. I am flagging it for two reasons. It may be an inconsistency you
   would want to know about, and if the intended cluster-wide setting is the
   restrictive one, I would rather know now than build anything that quietly
   depends on a node being an exception. If anything, a uniform setting would
   make my results more comparable across nodes. Please treat this as
   information, not a change request.

For context, the work is an energy-aware routing plugin for the open-source
llm-d inference router: it measures GPU energy per generated token and routes
requests to the most energy-efficient server that still meets latency
targets. The L4 and L40S nodes are useful precisely because their power
envelopes differ so much.

Thank you,
Johnnie Tse
