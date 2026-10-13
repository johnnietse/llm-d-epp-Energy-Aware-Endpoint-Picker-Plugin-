#!/usr/bin/env python3
"""Offline check of the harness's traffic window (2026-10-13). No GPU, no vLLM.

    python3 experiments/scripts/test_traffic_window.py     # needs httpx

What it does. It runs one real `policy_harness` cell against a mock streaming
completions server, with two stand-ins:
  * a stub `pynvml` whose energy counter runs at exactly POWER_W per GPU, so
    the energy of any window is known in advance;
  * a wrapper round `worker_entry` that sleeps TEARDOWN_S after the worker's
    traffic is done. That reproduces, on purpose, the artefact found in jobs
    12330596/8: the parent's clock stops only after the workers exit.

What must hold. The join-window fields absorb the teardown; the traffic-window
fields do not:
  * teardown_s is about TEARDOWN_S;
  * keepup_traffic is above 0.9 while keepup is visibly lower;
  * energy_traffic_j equals POWER_W x GPUs x traffic_window_s within one poll
    interval at each edge, and the join-window energy is larger by about
    POWER_W x GPUs x (teardown + lead).
It exits non-zero on any failure.
"""
import asyncio
import json
import os
import sys
import tempfile
import time
import types

HERE = os.path.dirname(os.path.abspath(__file__))
POWER_W = 100.0
TEARDOWN_S = 3.0
N_GPU = 2

# ---------------------------------------------------------------- stub NVML
_T0 = time.time()
nv = types.ModuleType("pynvml")


class NVMLError(Exception):
    pass


nv.NVMLError = NVMLError
nv.nvmlInit = lambda: None
nv.nvmlDeviceGetHandleByIndex = lambda i: i
nv.nvmlDeviceGetUUID = lambda h: "GPU-stub-%d" % h
# millijoules since an origin: POWER_W watts, exactly
nv.nvmlDeviceGetTotalEnergyConsumption = lambda h: int((time.time() - _T0) * POWER_W * 1000)
nv.nvmlDeviceGetPowerUsage = lambda h: int(POWER_W * 1000)
sys.modules["pynvml"] = nv
sys.path.insert(0, HERE)
import policy_harness as ph  # noqa: E402

# ------------------------------------------------------- mock vLLM server
TOKENS, TOKEN_GAP_S = 8, 0.01


async def handle(reader, writer):
    head = await reader.readuntil(b"\r\n\r\n")
    length = 0
    for line in head.split(b"\r\n"):
        if line.lower().startswith(b"content-length:"):
            length = int(line.split(b":")[1])
    if length:
        await reader.readexactly(length)
    if head.startswith(b"GET /metrics"):
        writer.write(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
    else:
        writer.write(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n"
                     b"Connection: close\r\n\r\n")
        for _ in range(TOKENS):
            await asyncio.sleep(TOKEN_GAP_S)
            writer.write(b'data: {"choices":[{"text":"x"}]}\n\n')
            await writer.drain()
        writer.write(b"data: [DONE]\n\n")
    await writer.drain()
    writer.close()


# --------------------------------------------------- slow worker teardown
_orig_worker = ph.worker_entry


def slow_teardown_worker(*a, **kw):
    _orig_worker(*a, **kw)
    time.sleep(TEARDOWN_S)


ph.worker_entry = slow_teardown_worker


def start_server_process():
    """The mock server runs in its own process. In-process (a thread of the
    generator) it competed with the generator for the interpreter and its
    socket was inherited by the forked workers; that first version produced
    negative latencies and a pass that meant nothing."""
    import multiprocessing as mp
    import socket
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    p = mp.get_context("spawn").Process(target=_serve_on, args=(port,), daemon=True)
    p.start()
    deadline = time.time() + 10
    while time.time() < deadline:
        try:
            socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
            return p, port
        except OSError:
            time.sleep(0.05)
    raise SystemExit("mock server did not start")


def _serve_on(port):
    async def go():
        srv = await asyncio.start_server(handle, "127.0.0.1", port)
        async with srv:
            await srv.serve_forever()
    asyncio.run(go())


def main():
    _proc, port = start_server_process()
    ep = "127.0.0.1:%d" % port
    out = os.path.join(tempfile.mkdtemp(), "cell.json")
    sys.argv = ["policy_harness.py", "--endpoints", ep + "," + ep,
                "--gpus", ",".join(str(i) for i in range(N_GPU)),
                "--endpoint-types", "a,a", "--policies", "round_robin",
                "--rate", "20", "--requests", "200", "--slo", "2.0",
                "--workers", "2", "--poll-interval", "0.1", "--out", out]
    ph.main()
    r = json.load(open(out))
    r = r[0] if isinstance(r, list) else r
    r = r["results"][0] if "results" in r else r
    show = ["completed", "errors", "traffic_window_s", "join_window_s", "teardown_s",
            "keepup", "keepup_traffic", "energy_traffic_j", "j_per_request",
            "j_per_request_traffic"]
    print({k: r.get(k) for k in show})
    e_join = r["energy"]["total_energy_j"]
    fails = []
    if r["completed"] != 200 or r["errors"]:
        fails.append("not every request completed")
    if not TEARDOWN_S - 0.5 <= r["teardown_s"] <= TEARDOWN_S + 1.5:
        fails.append("teardown_s %.2f, expected about %.1f" % (r["teardown_s"], TEARDOWN_S))
    if not (r["keepup_traffic"] > 0.9 and r["keepup"] < r["keepup_traffic"] - 0.05):
        fails.append("keep-up: join %.3f, traffic %.3f" % (r["keepup"], r["keepup_traffic"]))
    expect = POWER_W * N_GPU * r["traffic_window_s"]
    edge = 2 * POWER_W * N_GPU * 0.1          # one poll interval at each edge
    if r["energy_traffic_j"] is None or abs(r["energy_traffic_j"] - expect) > edge:
        fails.append("traffic energy %s, expected %.1f +- %.1f" % (r["energy_traffic_j"], expect, edge))
    if not e_join - r["energy_traffic_j"] >= POWER_W * N_GPU * (TEARDOWN_S - 0.5):
        fails.append("join-window energy %.1f does not include the teardown" % e_join)
    if fails:
        print("FAIL:\n  " + "\n  ".join(fails))
        sys.exit(1)
    print("PASS: teardown is in the join window only; traffic-window keep-up "
          "and energy are clean")


if __name__ == "__main__":
    main()
