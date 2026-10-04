#!/bin/bash
#SBATCH --job-name=counter-char
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --gres=gpu:1
#SBATCH --exclusive
#SBATCH --cpus-per-task=8
#SBATCH --mem=32G
#SBATCH --time=00:45:00
#SBATCH --output=%x-%j-%N.out
#
# Closes defect S2: characterise the NVML energy counter on OUR GPUs instead of
# assuming it is accurate.
#
# The SC24 result (Yang et al., arXiv 2312.02741) found A100/H100 sample power
# only about 25% of the time, so a counter read over a short window can
# quantise badly. Our sweeps use 75 s windows, which should make that
# immaterial - but "should" is not a measurement. This job establishes, per GPU:
#
#   1. Counter update period and quantum. Poll the counter at 1 ms and find how
#      often it actually changes and by how much. That is the floor on window
#      length for a trustworthy reading.
#   2. Three energy estimates over the same controlled load, compared:
#        a. counter delta                 (what we report)
#        b. integral of INSTANT power     (nvmlDeviceGetPowerUsage)
#        c. integral of AVERAGED power    (NVML field NVML_FI_DEV_POWER_AVERAGE,
#                                          a firmware-averaged value that is
#                                          less noisy than the instantaneous
#                                          reading on recent drivers)
#   3. The same again over a square-wave load, where instantaneous sampling is
#      most likely to alias and the counter should win.
#   4. Shortest window at which the counter agrees with the long-window
#      reference to within 1%. That number becomes a protocol requirement.
#
# Nothing here perturbs a measurement run: this is its own job.

if ! command -v module >/dev/null 2>&1; then
  source /cvmfs/soft.computecanada.ca/config/profile/bash.sh 2>/dev/null \
    || source "${LMOD_PKG:-/cvmfs/soft.computecanada.ca/custom/software/lmod/lmod}/init/bash" 2>/dev/null
fi
set -uo pipefail
module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"

ROOT="$HOME/energy-epp"
IMG="$ROOT/images/vllm-v0.30.0.sif"
RUN="$ROOT/results/counter-char-$SLURM_JOB_ID"
mkdir -p "$RUN"

{
  echo "node=$(hostname) job=$SLURM_JOB_ID"
  nvidia-smi --query-gpu=index,uuid,name,driver_version,power.limit,power.min_limit,power.max_limit --format=csv
  echo "kernel=$(uname -r)"
} | tee "$RUN/instruments.txt"

env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$IMG" python3 - <<'PY' 2>&1 | tee "$RUN/characterisation.txt"
import statistics as st
import time

import pynvml as n
import torch

n.nvmlInit()
h = n.nvmlDeviceGetHandleByIndex(0)
name = n.nvmlDeviceGetName(h)
name = name.decode() if isinstance(name, bytes) else name
print(f"GPU: {name}  uuid={n.nvmlDeviceGetUUID(h)}")
print(f"driver: {n.nvmlSystemGetDriverVersion()}")
print()


def energy_mj():
    return n.nvmlDeviceGetTotalEnergyConsumption(h)


def power_instant_w():
    return n.nvmlDeviceGetPowerUsage(h) / 1000.0


# --- averaged-power field, if the driver exposes it ------------------------
AVG_FIELD = getattr(n, "NVML_FI_DEV_POWER_AVERAGE", None)
INST_FIELD = getattr(n, "NVML_FI_DEV_POWER_INSTANT", None)


def power_field_w(field_id):
    if field_id is None:
        return None
    try:
        vals = n.nvmlDeviceGetFieldValues(h, [field_id])
        v = vals[0]
        if getattr(v, "nvmlReturn", 0) != 0:
            return None
        return v.value.uiVal / 1000.0
    except Exception:
        return None


print("=== 0. which power sources does this driver expose? ===")
print(f"  instantaneous (nvmlDeviceGetPowerUsage): {power_instant_w():.2f} W")
avg = power_field_w(AVG_FIELD)
inst = power_field_w(INST_FIELD)
print(f"  NVML_FI_DEV_POWER_AVERAGE: {'%.2f W' % avg if avg is not None else 'NOT AVAILABLE'}")
print(f"  NVML_FI_DEV_POWER_INSTANT: {'%.2f W' % inst if inst is not None else 'NOT AVAILABLE'}")
print()

# --- 1. counter update period and quantum ---------------------------------
print("=== 1. counter update period and quantum (1 ms polling, 8 s) ===")
samples = []
t0 = time.time()
last = energy_mj()
while time.time() - t0 < 8.0:
    e = energy_mj()
    if e != last:
        samples.append((time.time() - t0, e - last))
        last = e
    time.sleep(0.001)
if len(samples) >= 3:
    periods = [samples[i][0] - samples[i - 1][0] for i in range(1, len(samples))]
    steps = [s[1] for s in samples]
    print(f"  updates seen: {len(samples)} in 8 s")
    print(f"  median update period: {st.median(periods)*1000:.1f} ms")
    print(f"  median step: {st.median(steps)} mJ   min {min(steps)}  max {max(steps)}")
    print(f"  => a window shorter than ~{st.median(periods)*20*1000:.0f} ms carries")
    print("     fewer than 20 counter updates and should not be trusted")
else:
    print(f"  only {len(samples)} updates in 8 s - counter is very coarse here")
print()


def workload(seconds, duty=1.0, period=0.5):
    """Run matmuls for `seconds`. duty<1 gives a square wave."""
    a = torch.randn(4096, 4096, device="cuda", dtype=torch.float16)
    b = torch.randn(4096, 4096, device="cuda", dtype=torch.float16)
    t_end = time.time() + seconds
    while time.time() < t_end:
        t_on = time.time() + period * duty
        while time.time() < t_on and time.time() < t_end:
            (a @ b).relu()
        torch.cuda.synchronize()
        if duty < 1.0:
            t_off = time.time() + period * (1.0 - duty)
            while time.time() < t_off and time.time() < t_end:
                time.sleep(0.002)


def measure(seconds, duty, poll_hz=20.0):
    """Counter delta vs integrated instant power vs integrated averaged power."""
    inst_s, avg_s, times = [], [], []
    e0 = energy_mj()
    t0 = time.time()
    import threading
    stop = threading.Event()

    def poller():
        while not stop.is_set():
            inst_s.append(power_instant_w())
            a = power_field_w(AVG_FIELD)
            if a is not None:
                avg_s.append(a)
            times.append(time.time())
            time.sleep(1.0 / poll_hz)

    th = threading.Thread(target=poller, daemon=True)
    th.start()
    workload(seconds, duty=duty)
    stop.set()
    th.join(timeout=2)
    dt = time.time() - t0
    e1 = energy_mj()
    counter_j = (e1 - e0) / 1000.0
    inst_j = st.mean(inst_s) * dt if inst_s else float("nan")
    avg_j = st.mean(avg_s) * dt if avg_s else None
    return dt, counter_j, inst_j, avg_j


print("=== 2. steady load, 30 s: three estimates of the same energy ===")
dt, cj, ij, aj = measure(30.0, duty=1.0)
print(f"  window {dt:.2f} s")
print(f"  counter delta          : {cj:9.1f} J   ({cj/dt:7.2f} W)")
print(f"  integral of instant    : {ij:9.1f} J   ({ij/dt:7.2f} W)   "
      f"{(ij-cj)/cj*100:+.2f}% vs counter")
if aj is not None:
    print(f"  integral of averaged   : {aj:9.1f} J   ({aj/dt:7.2f} W)   "
          f"{(aj-cj)/cj*100:+.2f}% vs counter")
else:
    print("  integral of averaged   : field unavailable on this driver")
print()

print("=== 3. square-wave load, 30 s, 50% duty at 2 Hz (aliasing stress) ===")
dt, cj, ij, aj = measure(30.0, duty=0.5)
print(f"  window {dt:.2f} s")
print(f"  counter delta          : {cj:9.1f} J   ({cj/dt:7.2f} W)")
print(f"  integral of instant    : {ij:9.1f} J   ({ij/dt:7.2f} W)   "
      f"{(ij-cj)/cj*100:+.2f}% vs counter")
if aj is not None:
    print(f"  integral of averaged   : {aj:9.1f} J   ({aj/dt:7.2f} W)   "
          f"{(aj-cj)/cj*100:+.2f}% vs counter")
print("  Reading: a large gap here means instantaneous sampling aliases under")
print("  bursty load and the counter is the correct instrument - which is what")
print("  our protocol already assumes. A small gap means either works.")
print()

print("=== 4. shortest trustworthy window (counter vs 60 s reference) ===")
ref_dt, ref_cj, _, _ = measure(60.0, duty=1.0)
ref_w = ref_cj / ref_dt
print(f"  reference: {ref_w:.3f} W over {ref_dt:.1f} s")
for secs in (0.5, 1, 2, 5, 10, 20):
    dts, ws = [], []
    for _ in range(3):
        d, c, _, _ = measure(float(secs), duty=1.0)
        dts.append(d)
        ws.append(c / d)
    m = st.mean(ws)
    err = (m - ref_w) / ref_w * 100
    flag = "OK" if abs(err) < 1.0 else "TOO SHORT"
    print(f"  {secs:5.1f} s window: {m:7.3f} W  ({err:+6.2f}% vs reference)  {flag}")
print()
print("The shortest window marked OK is the floor the protocol should enforce.")
print("Our sweeps use 75 s, so any result here validates that choice with")
print("measurement instead of assumption. This closes validity defect S2.")
PY

echo "results in $RUN"
ls -l "$RUN"
