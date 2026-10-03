#!/usr/bin/env python3
"""Per-GPU energy/power exporter.

Reads the NVML hardware energy counter (not power polling: on recent GPUs the
on-board sensor is sampled only part of the time, so integrating polled power
misestimates energy -- Yang et al., SC24).

Writes one JSON line per sample per GPU, and optionally serves the same values
in Prometheus text format using DCGM-compatible metric names so the same
downstream config works here and on Kubernetes.
"""
import argparse, json, os, socket, sys, time

try:
    import pynvml as nvml
except ImportError:
    sys.exit("need nvidia-ml-py: pip install --user nvidia-ml-py")


def gpu_handles():
    nvml.nvmlInit()
    return [nvml.nvmlDeviceGetHandleByIndex(i)
            for i in range(nvml.nvmlDeviceGetCount())]


def name_of(h):
    n = nvml.nvmlDeviceGetName(h)
    return n.decode() if isinstance(n, bytes) else n


def sample(h):
    """One reading. energy_mj is a monotonic counter; take deltas."""
    out = {
        "power_w": nvml.nvmlDeviceGetPowerUsage(h) / 1000.0,
        "power_limit_w": nvml.nvmlDeviceGetEnforcedPowerLimit(h) / 1000.0,
    }
    try:
        out["energy_mj"] = nvml.nvmlDeviceGetTotalEnergyConsumption(h)
    except nvml.NVMLError:
        out["energy_mj"] = None
    try:
        u = nvml.nvmlDeviceGetUtilizationRates(h)
        out["util_gpu_pct"], out["util_mem_pct"] = u.gpu, u.memory
    except nvml.NVMLError:
        pass
    try:
        out["temp_c"] = nvml.nvmlDeviceGetTemperature(h, nvml.NVML_TEMPERATURE_GPU)
    except nvml.NVMLError:
        pass
    try:
        m = nvml.nvmlDeviceGetMemoryInfo(h)
        out["mem_used_mb"] = m.used // (1024 * 1024)
    except nvml.NVMLError:
        pass
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--out", default=None, help="JSONL output path")
    ap.add_argument("--duration", type=float, default=0, help="0 = run until killed")
    args = ap.parse_args()

    handles = gpu_handles()
    host = socket.gethostname()
    names = [name_of(h) for h in handles]
    job = os.environ.get("SLURM_JOB_ID", "none")

    out = open(args.out, "a", buffering=1) if args.out else sys.stdout
    print(json.dumps({"event": "start", "host": host, "job": job,
                      "gpus": names, "interval_s": args.interval}), file=out)

    start = time.time()
    while True:
        now = time.time()
        for i, h in enumerate(handles):
            rec = {"ts": now, "host": host, "job": job, "gpu": i, "name": names[i]}
            rec.update(sample(h))
            print(json.dumps(rec), file=out)
        if args.duration and (time.time() - start) >= args.duration:
            break
        time.sleep(args.interval)


if __name__ == "__main__":
    main()
