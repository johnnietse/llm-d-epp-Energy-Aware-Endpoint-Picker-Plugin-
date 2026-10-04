#!/usr/bin/env python3
"""Stage 2, measured: drive real vLLM endpoints under different placement
policies and measure the energy each policy actually costs.

This replaces the modelled gate. Nothing about queueing, batching or contention
is simulated here - requests go to real servers on real GPUs and the joules come
from NVML's hardware energy counter per device.

WHY THE POLICY LIVES IN THE CLIENT
----------------------------------
The research artifact is eventually an llm-d scorer plugin, but you do not need
the plugin to find out whether a placement rule helps. Putting the rule in the
load generator gives the same measurement for ~100 lines instead of a Go plugin
against an upstream API that churns. Only a rule that wins here is worth
building for real.

WHAT IS MEASURED VERSUS COMPUTED
--------------------------------
Measured: per-GPU energy (NVML counter deltas), per-request latency, completed
requests, token counts from each server's own metrics.
Computed: the lower bound, which is a bound by definition - but computed from
the measured per-endpoint curves, not from modelled physics.

Usage (inside the Slurm job, after the servers are up):
  python policy_harness.py \
      --endpoints 127.0.0.1:8100,127.0.0.1:8101,... \
      --gpus 0,1,2,3,4,5,6,7 \
      --curves /path/h1-a30.csv=a30 \
      --endpoint-types a30,a30,a30,a30,a30,a30,a30,a30 \
      --policy round_robin --rate 40 --requests 600 --slo 1.4 \
      --out /path/result.json
"""
from __future__ import annotations

import argparse
import asyncio
import csv
import json
import math
import random
import statistics as st
import time
from collections import defaultdict

try:
    import pynvml
except ImportError:  # the container python has it; fail loudly if not
    raise SystemExit("pynvml missing - run inside the vLLM image or module python")

import urllib.request
import urllib.error

OUTPUT_TOKENS = 128


# ----------------------------------------------------------------- NVML energy

class EnergyMeter:
    """Per-GPU energy via the hardware counter, with a parallel power poll as a
    cross-check (the two agreed to 25.94 vs 25.96 W in our first validation)."""

    def __init__(self, gpu_indices, poll_interval=0.25):
        # poll_interval = 0 disables the power-poll thread entirely, leaving
        # only two counter reads per window. Used by the perturbation control:
        # if full telemetry cost anything measurable, the control would differ.
        self.poll_interval = poll_interval
        pynvml.nvmlInit()
        self.idx = list(gpu_indices)
        self.handles = [pynvml.nvmlDeviceGetHandleByIndex(i) for i in self.idx]
        self.uuids = [pynvml.nvmlDeviceGetUUID(h) for h in self.handles]
        self.start_mj = None
        self.t0 = None
        self._poll = defaultdict(list)
        self._stop = False

    def _read_mj(self):
        out = []
        for h in self.handles:
            try:
                out.append(pynvml.nvmlDeviceGetTotalEnergyConsumption(h))
            except pynvml.NVMLError:
                out.append(None)
        return out

    def begin(self):
        self.start_mj = self._read_mj()
        self.t0 = time.time()
        self._stop = False

    async def poll_forever(self, interval=None):
        interval = self.poll_interval if interval is None else interval
        if interval <= 0:
            return          # counter-only mode: no sampling overhead at all
        while not self._stop:
            for i, h in enumerate(self.handles):
                try:
                    self._poll[i].append(pynvml.nvmlDeviceGetPowerUsage(h) / 1000.0)
                except pynvml.NVMLError:
                    pass
            await asyncio.sleep(interval)

    def end(self):
        self._stop = True
        end_mj = self._read_mj()
        dt = time.time() - self.t0
        per_gpu = []
        for i in range(len(self.handles)):
            a, b = self.start_mj[i], end_mj[i]
            counter_j = (b - a) / 1000.0 if (a is not None and b is not None) else None
            polled = self._poll.get(i, [])
            polled_j = st.mean(polled) * dt if polled else None
            per_gpu.append({
                "gpu_index": self.idx[i],
                "uuid": self.uuids[i],
                "energy_j_counter": counter_j,
                "mean_power_w_counter": (counter_j / dt) if counter_j is not None else None,
                "mean_power_w_polled": st.mean(polled) if polled else None,
                "energy_j_polled": polled_j,
                "samples": len(polled),
            })
        total = sum(g["energy_j_counter"] or 0.0 for g in per_gpu)
        return {"window_s": dt, "total_energy_j": total, "per_gpu": per_gpu}


# ------------------------------------------------------------- measured curves

def load_curve(path):
    """Mean power and throughput per concurrency from a sweep CSV (trials 2+)."""
    pw, tk, idle = defaultdict(list), defaultdict(list), []
    with open(path, newline="") as fh:
        for r in csv.DictReader(fh):
            if r["note"] == "idle_model_loaded":
                idle.append(float(r["mean_power_w"]))
                continue
            if r["note"] != "unique_prompts" or int(float(r["trial"])) == 1:
                continue
            c = int(float(r["concurrency"]))
            pw[c].append(float(r["mean_power_w"]))
            tk[c].append(float(r["gen_tok_per_s"]))
    levels = sorted(pw)
    return {
        "levels": levels,
        "power": {c: st.mean(pw[c]) for c in levels},
        "tok_s": {c: st.mean(tk[c]) for c in levels},
        "idle_resident": st.mean(idle) if idle else min(st.mean(pw[c]) for c in levels),
    }


def interp(curve, c, key):
    levels = curve["levels"]
    if c <= levels[0]:
        return curve[key][levels[0]]
    if c >= levels[-1]:
        return curve[key][levels[-1]]
    for lo, hi in zip(levels, levels[1:]):
        if lo <= c <= hi:
            f = (c - lo) / (hi - lo)
            return curve[key][lo] + f * (curve[key][hi] - curve[key][lo])
    return curve[key][levels[-1]]


# -------------------------------------------------------------------- policies

class Router:
    def __init__(self, n, types, curves, slo_s):
        self.n = n
        self.types = types
        self.curves = curves
        self.slo = slo_s
        self.inflight = [0] * n
        self.rr = 0
        self.activations = [0] * n
        self.was_idle = [True] * n

    def _proj_latency(self, i):
        c = self.inflight[i] + 1
        cur = self.curves.get(self.types[i])
        if not cur:
            return 0.0
        thr = interp(cur, c, "tok_s")
        per = thr / c if c else 0.0
        return OUTPUT_TOKENS / per if per > 0 else math.inf

    def _jtok(self, i):
        c = self.inflight[i] + 1
        cur = self.curves.get(self.types[i])
        if not cur:
            return 0.0
        thr = interp(cur, c, "tok_s")
        return interp(cur, c, "power") / thr if thr > 0 else math.inf

    def pick(self, policy):
        if policy == "round_robin":
            i = self.rr % self.n
            self.rr += 1
        elif policy == "least_loaded":
            i = min(range(self.n), key=lambda k: self.inflight[k])
        elif policy == "slo_packing":
            feas = [k for k in range(self.n) if self._proj_latency(k) <= self.slo]
            i = (max(feas, key=lambda k: self.inflight[k]) if feas
                 else min(range(self.n), key=lambda k: self.inflight[k]))
        elif policy == "energy_greedy":
            feas = [k for k in range(self.n) if self._proj_latency(k) <= self.slo] \
                   or list(range(self.n))
            i = min(feas, key=self._jtok)
        elif policy == "energy_consolidate":
            # prefer an already-busy endpoint of the most efficient type, and
            # only wake an idle one when no busy endpoint is SLO-feasible
            feas = [k for k in range(self.n) if self._proj_latency(k) <= self.slo]
            busy = [k for k in feas if self.inflight[k] > 0]
            pool = busy or feas or list(range(self.n))
            i = min(pool, key=lambda k: (self._jtok(k), -self.inflight[k]))
        else:
            raise SystemExit("unknown policy " + policy)
        if self.was_idle[i]:
            self.activations[i] += 1
            self.was_idle[i] = False
        self.inflight[i] += 1
        return i

    def release(self, i):
        self.inflight[i] -= 1
        if self.inflight[i] == 0:
            self.was_idle[i] = True


POLICIES = ["round_robin", "least_loaded", "slo_packing",
            "energy_greedy", "energy_consolidate"]


# ------------------------------------------------------------------ the driver

async def one_request(base_url, prompt, timeout=300):
    """Stream the completion so TTFT and inter-token latency are measurable.

    This used to send stream=False, which made TTFT and TPOT impossible to
    collect - only end-to-end latency. For an SLO-based study that is
    disqualifying: TTFT (prefill-dominated) and TPOT/ITL (decode-dominated) are
    the two standard SLO dimensions in LLM serving, and the field reports them
    separately because a policy can trade one for the other. Returns
    (ttft_s, itls, n_tokens).
    """
    body = json.dumps({
        "model": "served",
        "prompt": prompt,
        "max_tokens": OUTPUT_TOKENS,
        "temperature": 0.0,
        "stream": True,
    }).encode()
    req = urllib.request.Request(
        base_url + "/v1/completions", data=body,
        headers={"Content-Type": "application/json"})
    loop = asyncio.get_running_loop()

    def _do():
        t0 = time.time()
        ttft = None
        stamps = []
        with urllib.request.urlopen(req, timeout=timeout) as r:
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data:"):
                    continue
                payload = line[5:].strip()
                if payload == "[DONE]":
                    break
                try:
                    chunk = json.loads(payload)
                except json.JSONDecodeError:
                    continue
                text = ""
                for ch in chunk.get("choices", []):
                    text += ch.get("text") or ""
                if not text:
                    continue
                now = time.time()
                if ttft is None:
                    ttft = now - t0
                stamps.append(now)
        itls = [stamps[i] - stamps[i - 1] for i in range(1, len(stamps))]
        return ttft, itls, len(stamps)

    return await loop.run_in_executor(None, _do)


async def run_policy(policy, endpoints, gpus, types, curves, rate, n_requests,
                     slo_s, seed, poll_interval=0.25):
    rng = random.Random(seed)
    router = Router(len(endpoints), types, curves, slo_s)
    meter = EnergyMeter(gpus, poll_interval=poll_interval)

    arrivals = []
    t = 0.0
    for _ in range(n_requests):
        t += rng.expovariate(rate)
        arrivals.append(t)

    latencies = []
    ttfts = []
    all_itls = []
    errors = 0
    completed = 0

    meter.begin()
    poll_task = asyncio.create_task(meter.poll_forever())
    t_start = time.time()

    async def fire(delay, idx):
        nonlocal errors, completed
        await asyncio.sleep(max(0.0, delay - (time.time() - t_start)))
        i = router.pick(policy)
        url = "http://" + endpoints[i]
        prompt = f"Request {idx}: " + "explain distributed systems. " * rng.randint(4, 12)
        t0 = time.time()
        try:
            ttft, itls, _ntok = await one_request(url, prompt)
            latencies.append(time.time() - t0)
            if ttft is not None:
                ttfts.append(ttft)
            all_itls.extend(itls)
            completed += 1
        except Exception:
            errors += 1
        finally:
            router.release(i)

    await asyncio.gather(*(fire(a, k) for k, a in enumerate(arrivals)))
    energy = meter.end()
    poll_task.cancel()
    try:
        await poll_task
    except asyncio.CancelledError:
        pass

    def pct(xs, q):
        if not xs:
            return None
        xs = sorted(xs)
        return xs[min(len(xs) - 1, int(q * len(xs)))]

    lat_sorted = sorted(latencies)
    met = sum(1 for l in latencies if l <= slo_s)
    elapsed = max(1e-9, (arrivals[-1] if arrivals else 0.0) + (lat_sorted[-1] if lat_sorted else 0.0))
    return {
        "policy": policy,
        "offered_rate_rps": rate,
        "requests": n_requests,
        "completed": completed,
        "errors": errors,
        "slo_s": slo_s,
        "slo_met": met,
        "slo_rate": met / completed if completed else 0.0,
        "energy": energy,
        "j_per_request": energy["total_energy_j"] / completed if completed else None,
        "j_per_slo_request": energy["total_energy_j"] / met if met else None,
        "latency_p50": pct(latencies, 0.50),
        "latency_p95": pct(latencies, 0.95),
        "latency_p99": pct(latencies, 0.99),
        "ttft_p50": pct(ttfts, 0.50),
        "ttft_p95": pct(ttfts, 0.95),
        "ttft_p99": pct(ttfts, 0.99),
        "ttft_mean": st.mean(ttfts) if ttfts else None,
        "tpot_mean": st.mean(all_itls) if all_itls else None,
        "itl_p50": pct(all_itls, 0.50),
        "itl_p95": pct(all_itls, 0.95),
        "itl_p99": pct(all_itls, 0.99),
        "itl_max": max(all_itls) if all_itls else None,
        "itl_samples": len(all_itls),
        "goodput_rps": met / elapsed if elapsed else None,
        "goodput_per_joule": (met / energy["total_energy_j"]
                              if energy["total_energy_j"] else None),
        "activations": router.activations,
        "seed": seed,
        "poll_interval_s": poll_interval,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoints", required=True, help="host:port,host:port,...")
    ap.add_argument("--gpus", required=True, help="NVML indices, comma separated")
    ap.add_argument("--endpoint-types", required=True,
                    help="type name per endpoint, comma separated")
    ap.add_argument("--curves", nargs="*", default=[],
                    help="path=typename pairs from the h1 sweeps")
    ap.add_argument("--policies", default=",".join(POLICIES))
    ap.add_argument("--rate", type=float, required=True)
    ap.add_argument("--requests", type=int, default=600)
    ap.add_argument("--slo", type=float, required=True)
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--poll-interval", type=float, default=0.25,
                    help="power-poll period in seconds; 0 = counter only "
                         "(used by the perturbation control arm)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    endpoints = args.endpoints.split(",")
    gpus = [int(x) for x in args.gpus.split(",")]
    types = args.endpoint_types.split(",")
    if len(types) != len(endpoints):
        raise SystemExit("endpoint-types must match endpoints")

    curves = {}
    for spec in args.curves:
        path, _, name = spec.rpartition("=")
        curves[name] = load_curve(path)

    results = []
    for policy in args.policies.split(","):
        print(f"--- {policy} at {args.rate:.1f} req/s ---", flush=True)
        r = asyncio.run(run_policy(policy, endpoints, gpus, types, curves,
                                   args.rate, args.requests, args.slo, args.seed,
                                   poll_interval=args.poll_interval))
        def g(key, nd=3):
            v = r.get(key)
            return "n/a" if v is None else format(v, "." + str(nd) + "f")
        print("    J/req " + g("j_per_request", 2)
              + "  goodput/J " + g("goodput_per_joule", 4)
              + "  SLO " + format(r["slo_rate"] * 100, ".1f") + "%", flush=True)
        print("    TTFT p50/p95 " + g("ttft_p50") + "/" + g("ttft_p95")
              + "s  TPOT " + g("tpot_mean", 4)
              + "s  ITL p99/max " + g("itl_p99", 4) + "/" + g("itl_max", 4)
              + "s  e2e p99 " + g("latency_p99")
              + "s  errors " + str(r["errors"]), flush=True)
        results.append(r)
        time.sleep(20)   # let the GPUs settle between policies

    with open(args.out, "w") as fh:
        json.dump({"results": results,
                   "endpoints": endpoints,
                   "types": types,
                   "gpus": gpus}, fh, indent=2)
    print("wrote", args.out)


if __name__ == "__main__":
    main()
