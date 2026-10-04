#!/usr/bin/env python3
"""Fixed matmul load on one GPU, reporting achieved clock, power and throughput.

Used by verify_clock_effect.sbatch to test whether a clock lever that nvidia-smi
accepted actually changes anything. The workload is deliberately simple and
identical across invocations so the only variable is the GPU's own state.

Energy comes from the NVML hardware counter rather than polled power, for the
same reason the rest of this project does: the counter is accumulated in
firmware and does not alias under a load that starts and stops.
"""
from __future__ import annotations

import sys
import time

import pynvml
import torch

GPU = int(sys.argv[1])
LABEL = sys.argv[2] if len(sys.argv) > 2 else "run"
SIZE = 8192
SECONDS = 12.0


def main():
    pynvml.nvmlInit()
    h = pynvml.nvmlDeviceGetHandleByIndex(GPU)
    torch.cuda.set_device(GPU)

    a = torch.randn(SIZE, SIZE, device="cuda", dtype=torch.float16)
    b = torch.randn(SIZE, SIZE, device="cuda", dtype=torch.float16)
    for _ in range(5):                     # warm up, build cuBLAS plans
        a @ b
    torch.cuda.synchronize()

    e0 = pynvml.nvmlDeviceGetTotalEnergyConsumption(h)
    t0 = time.time()
    clocks, iters = [], 0
    while time.time() - t0 < SECONDS:
        for _ in range(8):
            a @ b
        torch.cuda.synchronize()
        iters += 8
        try:
            clocks.append(pynvml.nvmlDeviceGetClockInfo(h, pynvml.NVML_CLOCK_SM))
        except pynvml.NVMLError:
            pass
    t1 = time.time()
    e1 = pynvml.nvmlDeviceGetTotalEnergyConsumption(h)

    window = t1 - t0
    joules = (e1 - e0) / 1000.0
    # 2*n^3 flops per matmul, fp16
    tflops = iters * 2.0 * SIZE ** 3 / window / 1e12
    sm = sorted(clocks)
    med_sm = sm[len(sm) // 2] if sm else -1

    print("  %-16s sm_clock_med=%5d MHz  power=%6.1f W  "
          "TFLOP/s=%6.1f  J/TFLOP=%6.2f"
          % (LABEL, med_sm, joules / window, tflops,
             joules / (tflops * window) if tflops > 0 else float("nan")))


if __name__ == "__main__":
    main()
