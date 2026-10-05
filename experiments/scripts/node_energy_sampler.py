#!/usr/bin/env python3
"""Per-node GPU energy sampler for the multi-node heterogeneous experiment.

Why this exists. NVML is node-local: a process can only read the energy
counters of GPUs on its own machine. Every measurement so far has been
single-node, so the harness read its own GPUs directly. A heterogeneous fleet
needs two GPU types, each node has exactly one type, and in-node clock control
is denied (job 12304132 measured the clock levers as inert), so the only route
to heterogeneity is a multi-node allocation. That forces energy to be collected
on each node and stitched together afterwards.

What it writes. One JSON object per line, flushed immediately so the harness
can read the file while the run is still going:

    {"t": <wall clock, time.time()>,
     "mono": <time.monotonic(), for interval sanity>,
     "mj":  [cumulative mJ per GPU, from the hardware counter],
     "w":   [instantaneous W per GPU]}

The cumulative counter is what the energy figure is computed from; the power
readings are the same cross-check the single-node meter keeps.

Energy over a window is counter(t1) - counter(t0), with the boundaries linearly
interpolated between bracketing samples. That is sound because the quantity is
a monotonically increasing accumulation, not a rate being averaged - which is
the whole reason this project reads the counter rather than integrating polled
power.

Deliberately NOT doing any aggregation here. This process records; the harness
decides what window to attribute. Mixing those would make the sampler's own
timing part of the measurement.
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import sys
import time

try:
    import pynvml
except ImportError:
    raise SystemExit("pynvml missing - run inside the vLLM image")


class Stop:
    """SIGTERM is how the batch script ends the sampler, so exit cleanly and
    leave a complete final line rather than a truncated one."""

    def __init__(self):
        self.now = False
        signal.signal(signal.SIGTERM, self._set)
        signal.signal(signal.SIGINT, self._set)

    def _set(self, *_):
        self.now = True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True,
                    help="JSONL path; one file per node, on shared storage")
    ap.add_argument("--interval", type=float, default=0.25,
                    help="sampling period in seconds; 0.25 matches the "
                         "single-node meter so the perturbation control "
                         "remains comparable")
    ap.add_argument("--gpus", default="",
                    help="comma-separated NVML indices; default is all local")
    args = ap.parse_args()

    pynvml.nvmlInit()
    n = pynvml.nvmlDeviceGetCount()
    idx = ([int(x) for x in args.gpus.split(",") if x != ""]
           if args.gpus else list(range(n)))
    handles = [pynvml.nvmlDeviceGetHandleByIndex(i) for i in idx]

    header = {
        "kind": "header",
        "host": socket.gethostname(),
        "pid": os.getpid(),
        "t_start": time.time(),
        "mono_start": time.monotonic(),
        "interval": args.interval,
        "gpus": [],
    }
    for i, h in enumerate(handles):
        try:
            name = pynvml.nvmlDeviceGetName(h)
            name = name.decode() if isinstance(name, bytes) else name
        except pynvml.NVMLError:
            name = "unknown"
        try:
            uuid = pynvml.nvmlDeviceGetUUID(h)
            uuid = uuid.decode() if isinstance(uuid, bytes) else uuid
        except pynvml.NVMLError:
            uuid = "unknown"
        header["gpus"].append({"index": idx[i], "name": name, "uuid": uuid})
    try:
        drv = pynvml.nvmlSystemGetDriverVersion()
        header["driver"] = drv.decode() if isinstance(drv, bytes) else drv
    except pynvml.NVMLError:
        header["driver"] = "unknown"

    stop = Stop()
    with open(args.out, "w") as fh:
        fh.write(json.dumps(header) + "\n")
        fh.flush()
        while not stop.now:
            mj, w = [], []
            for h in handles:
                try:
                    mj.append(pynvml.nvmlDeviceGetTotalEnergyConsumption(h))
                except pynvml.NVMLError:
                    mj.append(None)
                try:
                    w.append(pynvml.nvmlDeviceGetPowerUsage(h) / 1000.0)
                except pynvml.NVMLError:
                    w.append(None)
            fh.write(json.dumps({"t": time.time(),
                                 "mono": time.monotonic(),
                                 "mj": mj, "w": w}) + "\n")
            fh.flush()
            # Sleep the remainder of the period rather than a fixed amount, so
            # the sample rate does not drift with read latency.
            time.sleep(max(0.0, args.interval - 0.002))
    return 0


if __name__ == "__main__":
    sys.exit(main())
