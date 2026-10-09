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
import multiprocessing as mp
import os
import resource
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

try:
    import multinode_energy
except ImportError:
    multinode_energy = None   # only needed for --energy-mode multinode

try:
    import httpx
except ImportError:
    # The load generator must not fall back to blocking urllib in a thread
    # pool. The default asyncio executor is capped at min(32, cpu_count+4)
    # workers, which silently turns an open-loop test into a closed-loop one
    # at concurrency 32. Job 12303327 lost its entire 8-GPU sweep that way:
    # 112.5 req/s offered, 26.7 req/s achieved, every cell client-limited.
    raise SystemExit("httpx missing - the harness needs real async HTTP; "
                     "a thread-pool client caps concurrency at 32")

OUTPUT_TOKENS = 128

# Two different things look identical in the achieved request rate, and only
# one of them is a defect:
#
#   * the generator could not get requests out on schedule  -> invalid cell
#   * the servers could not serve them fast enough          -> real overload
#
# Completion rate alone cannot tell them apart, which is why job 12303327 read
# as "all policies saturated" when in fact the client was the bottleneck. The
# dispatch delay is purely client-side, so it is the discriminator: if the
# generator kept to its own Poisson schedule, any shortfall in completions is
# physics. SEND_DELAY_SLO_FRAC is expressed as a fraction of the SLO, floored
# so a tight SLO cannot make the check hypersensitive.
SEND_DELAY_SLO_FRAC = 0.05
SEND_DELAY_FLOOR_S = 0.025

# Sampling period of node_energy_sampler.py, used to size how long to wait for
# the samplers to catch up at a cell boundary and how far a window boundary may
# be clamped onto the sampled span. Keep in step with SAMPLE_INTERVAL in
# stage2_het.sbatch.
SAMPLER_INTERVAL_S = 0.25


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


# -------------------------------------------------- RAPL (CPU + DRAM energy)

def rapl_zones():
    """Readable RAPL energy counters, if the kernel allows it.

    TokenPowerBench pairs NVML/DCGM (GPU) with RAPL (CPU/DRAM) and IPMI (node).
    We were GPU-package only, so this is free coverage - but CVE-2020-8694
    hardening makes energy_uj root-only on many distros, so it may be empty.
    """
    import glob
    zones = []
    for z in sorted(glob.glob("/sys/class/powercap/*-rapl:*")):
        ej = z + "/energy_uj"
        try:
            with open(ej) as fh:
                fh.read()
            name = "unknown"
            try:
                with open(z + "/name") as fh:
                    name = fh.read().strip()
            except OSError:
                pass
            zones.append((z, name))
        except OSError:
            continue
    return zones


def rapl_read(zones):
    out = {}
    for z, name in zones:
        try:
            with open(z + "/energy_uj") as fh:
                out[z] = (name, int(fh.read().strip()))
        except OSError:
            pass
    return out


def rapl_delta(before, after):
    """Joules per zone. RAPL counters wrap, so a negative delta is dropped
    rather than guessed at.

    Keys are zone-id + name, not name alone: on a two-socket node both
    intel-rapl:0:0 and intel-rapl:1:0 are named "dram", so keying by name
    collapsed them and silently discarded one DRAM domain. Caught in the smoke
    run (job 12303326), where only a single "dram" figure appeared.
    """
    res = {}
    for z, (name, a) in before.items():
        if z not in after:
            continue
        _, b = after[z]
        if b >= a:
            zid = z.rsplit("/", 1)[-1]          # e.g. intel-rapl:1:0
            res[zid + ":" + name] = (b - a) / 1e6
    res["_total_j"] = round(sum(v for k, v in res.items() if not k.startswith("_")), 3)
    return res


# ------------------------------------------------- engine-side metrics scrape

# vLLM's own latency histograms. These are measured INSIDE the engine, so they
# contain no client-side scheduling at all, which makes them the independent
# cross-check on our timestamps.
#
# Why that matters. The generator is Python, and its event loop has finite
# scheduling granularity: measured dispatch delay is 0.66-0.78 ms at p50 and
# 2.9-6.0 ms at p99 (job 12304137). Against the 2000 ms SLO that is 0.3% and
# irrelevant. Against an inter-token interval of 13.7-17.4 ms it is 5% to 44%,
# so for ITL and TPOT specifically the client could distort what it reports.
# Rather than argue about it, take the same quantities from a source that has
# no client in the path and compare. If they agree, the Python timestamps are
# fine and the question is closed with a number. If they do not, the server
# histograms become the authoritative figures for per-token latency and the
# client's remain the user-facing view.
# Names verified against the installed package by job 12305248, not guessed.
# The first attempt used "vllm:time_per_output_token_seconds", which does not
# exist in vLLM 0.30.0, so the cross-check read engine 0.0000 and silently
# compared our ITL against nothing. The real name carries a "request_" prefix.
#
# More useful still: vllm:inter_token_latency_seconds is the engine's own
# measure of the gap BETWEEN tokens, which is exactly what our client timestamps
# produce. Request-level TPOT is a per-request mean over output tokens, so it is
# a near relative rather than the same quantity. ITL is the right comparison and
# TPOT is kept beside it.
TTFT_METRIC = "vllm:time_to_first_token_seconds"
ITL_METRIC = "vllm:inter_token_latency_seconds"
TPOT_METRIC = "vllm:request_time_per_output_token_seconds"
E2E_METRIC = "vllm:e2e_request_latency_seconds"
LATENCY_HISTOGRAMS = (TTFT_METRIC, ITL_METRIC, TPOT_METRIC, E2E_METRIC)


def _parse_histogram(lines, name):
    """Sum and count for a Prometheus histogram, across all label sets.

    Only _sum and _count are needed: their ratio is the mean, which is what a
    cross-check against our own mean requires. Bucket boundaries would give
    percentiles but vLLM's defaults are too coarse to compare against a p50 we
    measured directly.
    """
    total, count = 0.0, 0.0
    for line in lines:
        if not line.startswith(name):
            continue
        head, _, val = line.rpartition(" ")
        try:
            v = float(val)
        except ValueError:
            continue
        metric = head.split("{", 1)[0].strip()
        if metric == name + "_sum":
            total += v
        elif metric == name + "_count":
            count += v
    if count <= 0:
        return None
    return {"sum": total, "count": count, "mean": total / count}


def scrape_engine_metrics(endpoints):
    """Cache hit rate, queue depth, and the engine's own latency histograms.

    Flagged in plan 5.1 as cheap and unmeasured. These are vLLM's counters, not
    ours, and they answer two reporting-set items (cache hit rate, utilisation)
    that no GPU tool can provide. The histograms additionally let the client's
    latency numbers be checked against a measurement the client did not make.
    """
    wanted = ("gpu_prefix_cache_hit_rate", "gpu_cache_usage_perc",
              "num_requests_running", "num_requests_waiting",
              "prompt_tokens_total", "generation_tokens_total")
    out = {}
    for ep in endpoints:
        vals = {}
        try:
            with urllib.request.urlopen("http://" + ep + "/metrics", timeout=10) as r:
                lines = r.read().decode("utf-8", "replace").splitlines()
            for line in lines:
                if line.startswith("#") or not line.strip():
                    continue
                for w in wanted:
                    if w in line:
                        try:
                            vals.setdefault(w, []).append(float(line.rsplit(" ", 1)[1]))
                        except (ValueError, IndexError):
                            pass
            hist = {}
            for h in LATENCY_HISTOGRAMS:
                got = _parse_histogram(lines, h)
                if got:
                    hist[h] = got
            if hist:
                vals["_histograms"] = hist
        except Exception as exc:
            vals["error"] = str(exc)[:80]
        out[ep] = {k: (sum(v) / len(v) if isinstance(v, list) and v else v)
                   for k, v in vals.items()}
    return out


def server_vs_client_latency(before, after, client_ttft_mean, client_itl_mean):
    """Per-cell comparison of the engine's latency means against ours.

    Deltas are taken across the cell (after minus before) so only this cell's
    requests contribute, rather than the server's lifetime totals.
    """
    def delta(name):
        tot, cnt = 0.0, 0.0
        for ep, aft in (after or {}).items():
            bh = ((before or {}).get(ep) or {}).get("_histograms") or {}
            ah = (aft or {}).get("_histograms") or {}
            if name not in ah:
                continue
            b = bh.get(name, {"sum": 0.0, "count": 0.0})
            tot += ah[name]["sum"] - b.get("sum", 0.0)
            cnt += ah[name]["count"] - b.get("count", 0.0)
        if cnt <= 0:
            return None
        return tot / cnt

    s_ttft = delta(TTFT_METRIC)
    s_itl = delta(ITL_METRIC)
    s_tpot = delta(TPOT_METRIC)
    s_e2e = delta(E2E_METRIC)

    def rel(client, server):
        if client is None or server is None or server <= 0:
            return None
        return round((client - server) / server * 100, 2)

    return {
        "server_ttft_mean_s": s_ttft,
        "server_itl_mean_s": s_itl,
        "server_tpot_mean_s": s_tpot,
        "server_e2e_mean_s": s_e2e,
        "client_ttft_mean_s": client_ttft_mean,
        "client_itl_mean_s": client_itl_mean,
        # Our inter-token intervals against the engine's own. This is the
        # comparison that decides whether a Python generator is accurate enough
        # for per-token metrics: the client's event loop has ~0.7 ms median
        # scheduling granularity against an ITL of 13-17 ms.
        "itl_client_excess_pct": rel(client_itl_mean, s_itl),
        # Positive means the client reports MORE latency than the engine saw,
        # which is the expected direction: the client adds its own scheduling
        # and the network hop. The size is what decides whether the Python
        # generator is good enough for per-token metrics.
        "ttft_client_excess_pct": rel(client_ttft_mean, s_ttft),
        "tpot_client_excess_pct": rel(client_itl_mean, s_tpot),
        # Non-null means at least one engine histogram was found. If this is
        # false the cross-check is not evidence of anything, which is the state
        # the wrong TPOT name silently produced.
        "cross_check_usable": any(x is not None
                                  for x in (s_ttft, s_itl, s_tpot, s_e2e)),
    }


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
    """Interpolate a measured curve. Returns None ABOVE the measured range.

    This used to clamp: any concurrency above the top measured level returned
    that level's value. That is not a small approximation, it silently turned
    the router's energy model into a constant and its latency model into a
    serious underprediction, because the operating range is nowhere near the
    measured one. The Stage 1 curves stop at concurrency 32; job 12303355 ran
    at 271 req/s with ~1.95 s service time, so roughly 528 requests were in
    flight across 8 endpoints, about 66 each - twice the measured domain.

    Two concrete failures followed, and both read as policy results:

      * _jtok returned power(32)/tok_s(32) for EVERY endpoint at c >= 32, so
        all candidates tied and min() fell through to index order.
        energy_greedy was bin-packing by endpoint index with no energy signal
        at all.
      * _proj_latency predicted 128*c/tok_s(32), i.e. 1.99 s at c=42, and
        declared that SLO-feasible. The measured p95 at that concurrency was
        31 s.

    Returning None forces every caller to decide explicitly what to do without
    data, instead of being handed a confident wrong number. Below the measured
    range clamping is kept: c < levels[0] means fewer in flight than the
    lightest measured point, where the curve is flat and the extrapolation is
    not load-bearing.
    """
    levels = curve["levels"]
    if c <= levels[0]:
        return curve[key][levels[0]]
    if c > levels[-1]:
        return None
    if c == levels[-1]:
        return curve[key][levels[-1]]
    for lo, hi in zip(levels, levels[1:]):
        if lo <= c <= hi:
            f = (c - lo) / (hi - lo)
            return curve[key][lo] + f * (curve[key][hi] - curve[key][lo])
    return None


# -------------------------------------------------------------------- policies

class Router:
    """Routing state. Every policy except round_robin depends on the GLOBAL
    in-flight count per endpoint, so when the generator is sharded across
    processes this state has to be genuinely shared. Giving each worker its own
    copy would leave every worker routing on 1/W of the picture - the policies
    would still run and still produce numbers, but they would not be the
    policies being claimed. That is the same silent-substitution failure as the
    thread-pool ceiling, so the shared path is the default once W > 1.

    With `shared=True` the counters live in multiprocessing.Array and pick() /
    release() take a lock. Contention is two acquisitions per request, so a few
    hundred per second: irrelevant next to a ~1 s service time.
    """

    def __init__(self, n, types, curves, slo_s, shared=False, headroom=0.0):
        self.n = n
        self.types = types
        self.curves = curves
        self.slo = slo_s
        # The packing policies admit an endpoint while its projected latency is
        # at most pack_limit. With headroom 0 that is the SLO itself, and the
        # policies pack until latency sits ON the boundary: job 12321478 ran
        # every packer at p50 1.98-2.01 s against a 2.0 s SLO, so 17-70% of
        # requests missed it even at 12.5 req/s per GPU. The projection was
        # accurate (within 0.02 s of measured latency up to c=96); aiming at the
        # line was the defect. Headroom h packs to (1 - h) * SLO, applied
        # identically to every packing policy. Default 0 reproduces Stage 2.
        if not 0.0 <= headroom < 1.0:
            raise SystemExit("headroom must be in [0, 1): %r" % headroom)
        self.headroom = headroom
        self.pack_limit = slo_s * (1.0 - headroom)
        self.shared = shared
        if shared:
            ctx = mp.get_context("fork")
            self.lock = ctx.Lock()
            self._inflight = ctx.Array("i", n, lock=False)
            self._activations = ctx.Array("i", n, lock=False)
            self._was_idle = ctx.Array("i", [1] * n, lock=False)
            self._rr = ctx.Value("i", 0, lock=False)
        else:
            self.lock = None
            self._inflight = [0] * n
            self._activations = [0] * n
            self._was_idle = [1] * n
            self._rr = None
            self.rr = 0
        # How many curve lookups fell outside the measured range. If this is
        # not ~0, the routing decisions were not grounded in measurement and
        # the cell cannot support a policy claim.
        self._oor = (mp.get_context("fork").Value("l", 0, lock=False)
                     if shared else None)
        self._oor_local = 0
        # Picks where EVERY endpoint was outside the measured curve, so the
        # policy had no grounded option and fell through to its fallback.
        # This, not the raw out-of-range lookup count, is the number that can
        # invalidate a policy claim: a lookup above the range that correctly
        # excludes an endpoint is the curve doing its job, and a consolidating
        # policy probes above the ceiling constantly by design.
        self._ung = (mp.get_context("fork").Value("l", 0, lock=False)
                     if shared else None)
        self._ung_local = 0
        # Picks where the curve answered for every endpoint but NONE was
        # SLO-feasible, so the policy fell back. This is not a defect: it is
        # the policy correctly reporting that the fleet is saturated, and it is
        # the expected behaviour past the knee. It is counted separately
        # because a cell where most picks land here is a cell in which the
        # policy was INACTIVE - the data is sound, but no comparison between
        # policies can rest on it, since they all ran the same fallback.
        self._sat = (mp.get_context("fork").Value("l", 0, lock=False)
                     if shared else None)
        self._sat_local = 0
        # Per-pick tally of endpoints whose curve lookup had no data. Reset at
        # the top of every pick.
        self._nodata = 0

    def _note_out_of_range(self):
        if self._oor is not None:
            self._oor.value += 1
        else:
            self._oor_local += 1

    def _note_ungrounded(self):
        if self._ung is not None:
            self._ung.value += 1
        else:
            self._ung_local += 1

    @property
    def out_of_range(self):
        return self._oor.value if self._oor is not None else self._oor_local

    def _note_saturated(self):
        if self._sat is not None:
            self._sat.value += 1
        else:
            self._sat_local += 1

    def _no_feasible(self):
        """Record an empty feasible set, attributing it to the right cause.

        Distinguishing these two took three attempts. Counting raw
        out-of-range lookups refused clean runs, because a consolidating policy
        probes above the ceiling by design. Counting every empty feasible set
        as ungrounded then refused runs where the curve had answered perfectly
        and simply said that nothing fits the SLO - jobs 12304137/8 showed
        out_of_range=0 with 96.9% of picks flagged, at a measured p50 of 2.20 s
        against a 2.0 s SLO. The model was right; the counter was wrong.
        """
        if self._nodata >= self.n:
            self._note_ungrounded()
        else:
            self._note_saturated()

    @property
    def ungrounded_picks(self):
        return self._ung.value if self._ung is not None else self._ung_local

    @property
    def saturated_picks(self):
        return self._sat.value if self._sat is not None else self._sat_local

    # The policy bodies below index these as plain sequences, so the shared and
    # unshared cases read identically and cannot drift apart.
    @property
    def inflight(self):
        return self._inflight

    @property
    def activations(self):
        return list(self._activations)

    @property
    def was_idle(self):
        return self._was_idle

    def _proj_latency(self, i):
        """Projected latency, or +inf when the curve cannot answer.

        +inf means "no measurement covers this concurrency", which makes the
        endpoint SLO-infeasible and pushes the policy onto its documented
        fallback. The alternative - guessing - is what produced a 31 s p95
        while the model predicted 1.99 s.
        """
        c = self.inflight[i] + 1
        cur = self.curves.get(self.types[i])
        if not cur:
            return 0.0
        thr = interp(cur, c, "tok_s")
        if thr is None:
            self._note_out_of_range()
            self._nodata += 1
            return math.inf
        per = thr / c if c else 0.0
        return OUTPUT_TOKENS / per if per > 0 else math.inf

    def _jtok(self, i):
        """Energy per token, or +inf when the curve cannot answer."""
        c = self.inflight[i] + 1
        cur = self.curves.get(self.types[i])
        if not cur:
            return 0.0
        thr = interp(cur, c, "tok_s")
        pwr = interp(cur, c, "power")
        if thr is None or pwr is None:
            self._note_out_of_range()
            self._nodata += 1
            return math.inf
        return pwr / thr if thr > 0 else math.inf

    def pick(self, policy):
        if self.lock is not None:
            with self.lock:
                return self._pick_locked(policy)
        return self._pick_locked(policy)

    def release(self, i):
        if self.lock is not None:
            with self.lock:
                self._release_locked(i)
        else:
            self._release_locked(i)

    def _pick_locked(self, policy):
        self._nodata = 0
        if policy == "round_robin":
            if self._rr is not None:
                i = self._rr.value % self.n
                self._rr.value += 1
            else:
                i = self.rr % self.n
                self.rr += 1
        elif policy == "least_loaded":
            i = min(range(self.n), key=lambda k: self.inflight[k])
        elif policy == "slo_packing":
            feas = [k for k in range(self.n) if self._proj_latency(k) <= self.pack_limit]
            if feas:
                i = max(feas, key=lambda k: self._inflight[k])
            else:
                # This fallback was already sound - balance load when the curve
                # cannot say which endpoint is safe - but it is still a pick
                # made without grounded information, so it is counted.
                self._no_feasible()
                i = min(range(self.n), key=lambda k: self._inflight[k])
        elif policy == "energy_greedy":
            feas = [k for k in range(self.n) if self._proj_latency(k) <= self.pack_limit]
            if feas:
                i = min(feas, key=self._jtok)
            else:
                # No endpoint has curve data for its current concurrency. The
                # old code did `or list(range(self.n))` and then min() by
                # _jtok, which is +inf for every out-of-range endpoint - so
                # min() returned the FIRST index and the policy silently
                # degraded to "always endpoint 0" while still being reported
                # as energy-aware. Without energy information the defensible
                # action is to balance load, which is what least_loaded does.
                self._no_feasible()
                i = min(range(self.n), key=lambda k: self._inflight[k])
        elif policy == "energy_consolidate":
            # prefer an already-busy endpoint of the most efficient type, and
            # only wake an idle one when no busy endpoint is SLO-feasible
            feas = [k for k in range(self.n) if self._proj_latency(k) <= self.pack_limit]
            busy = [k for k in feas if self._inflight[k] > 0]
            pool = busy or feas
            if pool:
                i = min(pool, key=lambda k: (self._jtok(k), -self._inflight[k]))
            else:
                # Same defect as energy_greedy: the old `or list(range(self.n))`
                # made every candidate's key (+inf, ...) so the tuple compare
                # fell through to index order.
                self._no_feasible()
                i = min(range(self.n), key=lambda k: self._inflight[k])
        else:
            raise SystemExit("unknown policy " + policy)
        if self._was_idle[i]:
            self._activations[i] += 1
            self._was_idle[i] = 0
        self._inflight[i] += 1
        return i

    def _release_locked(self, i):
        self._inflight[i] -= 1
        if self._inflight[i] == 0:
            self._was_idle[i] = 1


POLICIES = ["round_robin", "least_loaded", "slo_packing",
            "energy_greedy", "energy_consolidate"]


# ------------------------------------------------------------------ the driver

async def one_request(client, base_url, prompt, timeout=300):
    """Stream the completion so TTFT and inter-token latency are measurable.

    This used to send stream=False, which made TTFT and TPOT impossible to
    collect - only end-to-end latency. For an SLO-based study that is
    disqualifying: TTFT (prefill-dominated) and TPOT/ITL (decode-dominated) are
    the two standard SLO dimensions in LLM serving, and the field reports them
    separately because a policy can trade one for the other.

    It then used blocking urllib inside loop.run_in_executor(None, ...), which
    capped in-flight requests at the default executor width - 32 on a 32-core
    node. Above ~27 req/s the generator stopped being open-loop and the offered
    rate became fiction, while TTFT (timed from dispatch, after the queue wait)
    still looked healthy. Real async HTTP removes the ceiling; the caller now
    also records the dispatch delay so the remaining backlog is visible.

    Returns (ttft_s, itls, n_tokens).
    """
    body = json.dumps({
        "model": "served",
        "prompt": prompt,
        "max_tokens": OUTPUT_TOKENS,
        "temperature": 0.0,
        "stream": True,
    }).encode()
    t0 = time.time()
    ttft = None
    stamps = []
    async with client.stream(
            "POST", base_url + "/v1/completions", content=body,
            headers={"Content-Type": "application/json"},
            timeout=timeout) as r:
        r.raise_for_status()
        async for raw in r.aiter_lines():
            line = raw.strip()
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


def make_prompt(idx, seed):
    """Deterministic per-request prompt.

    The prompt length used to come from an rng shared by every coroutine in the
    cell, so the sequence of draws depended on asyncio scheduling order: the
    seed did not actually reproduce a workload, and it would certainly not
    survive sharding across processes. Deriving the length from (seed, idx)
    makes the workload identical regardless of worker count or interleaving.
    """
    # A string seed, not a tuple: Python 3.11 removed tuple support from
    # random.seed ("The only supported seed types are: None, int, float, str,
    # bytes, bytearray"), and the container runs 3.12, so a tuple would raise
    # on every single request.
    n = random.Random("%d:%d" % (seed, idx)).randint(4, 12)
    return "Request %d: " % idx + "explain distributed systems. " * n


async def drive_slice(router, policy, endpoints, idxs, arrivals, t_start, seed,
                      pool):
    """Issue one worker's share of the arrival schedule.

    `arrivals` are absolute offsets from the common t_start, so every worker
    schedules against the same origin and the aggregate arrival process is the
    one that was generated, not W independent ones.
    """
    out = {"latencies": [], "ttfts": [], "ttfts_from_send": [],
           "send_delays": [], "itls": [], "completed": 0, "errors": 0}
    limits = httpx.Limits(max_connections=pool, max_keepalive_connections=pool)

    async def fire(client, idx, delay):
        await asyncio.sleep(max(0.0, (t_start + delay) - time.time()))
        i = router.pick(policy)
        url = "http://" + endpoints[i]
        # Two clocks. t_sched is when the Poisson schedule said this request
        # should arrive; t_send is when the client actually got it out. Latency
        # and TTFT are reported from t_sched, because that is what a user
        # experiences and it cannot hide client backlog. ttft_from_send keeps
        # the server-side view, and the gap between them is send_delay.
        t_sched = t_start + delay
        t_send = time.time()
        out["send_delays"].append(t_send - t_sched)
        try:
            ttft, itls, _ntok = await one_request(client, url,
                                                 make_prompt(idx, seed))
            out["latencies"].append(time.time() - t_sched)
            if ttft is not None:
                out["ttfts"].append(ttft + (t_send - t_sched))
                out["ttfts_from_send"].append(ttft)
            out["itls"].extend(itls)
            out["completed"] += 1
        except Exception:
            out["errors"] += 1
        finally:
            router.release(i)

    async with httpx.AsyncClient(limits=limits, http2=False) as client:
        await asyncio.gather(*(fire(client, idx, arrivals[k])
                               for k, idx in enumerate(idxs)))
    return out


def worker_entry(wid, router, policy, endpoints, idxs, arrivals, t_start, seed,
                 pool, out_path):
    """Child-process entry point. Writes its aggregate to a file rather than a
    Queue: a worker returning tens of thousands of inter-token samples through
    a pipe can block on the pipe buffer while the parent is still waiting to
    join it, which deadlocks."""
    res = asyncio.run(drive_slice(router, policy, endpoints, idxs, arrivals,
                                  t_start, seed, pool))
    with open(out_path, "w") as fh:
        json.dump(res, fh)


async def run_policy(policy, endpoints, gpus, types, curves, rate, n_requests,
                     slo_s, seed, poll_interval=0.25, workers=1,
                     scratch="/tmp", energy_mode="local", sample_dir=None,
                     clock_skew=0.0, headroom=0.0):
    router = Router(len(endpoints), types, curves, slo_s, shared=(workers > 1),
                    headroom=headroom)
    meter = EnergyMeter(gpus, poll_interval=poll_interval)

    # The arrival process is generated once, in the parent, from the seed. It
    # is then dealt round-robin to the workers, so the union of the slices is
    # exactly this schedule.
    rng = random.Random(seed)
    arrivals = []
    t = 0.0
    for _ in range(n_requests):
        t += rng.expovariate(rate)
        arrivals.append(t)

    # Connection pool per worker. It must exceed any concurrency that worker's
    # slice can reach, or it reintroduces the ceiling one layer down - which is
    # the bug this whole path exists to remove.
    pool = max(1024, (4 * n_requests) // max(1, workers))

    # In multinode mode the local NVML meter is NOT used. It can only see
    # this node's GPUs, so on a two-node heterogeneous fleet it would silently
    # report a subset of the fleet's energy as if it were the whole thing -
    # a smaller number, not a wrong-looking one, which is the dangerous kind.
    # Energy comes instead from a sampler running on every node, stitched by
    # window afterwards.
    use_local_meter = (energy_mode == "local")

    zones = rapl_zones()
    rapl_before = rapl_read(zones)
    engine_before = scrape_engine_metrics(endpoints)
    # The load generator runs on the SAME node as the servers, so its own CPU
    # time is inside the RAPL package energy for this cell. GPU-package energy,
    # the primary metric, is untouched; the CPU/DRAM figure is not, and a
    # multi-process generator makes that term larger. Recording the
    # generator's CPU seconds turns an unknown contamination into a measured
    # and reportable one. Children are counted because the workers are forks.
    ru_self0 = resource.getrusage(resource.RUSAGE_SELF)
    ru_kids0 = resource.getrusage(resource.RUSAGE_CHILDREN)
    if use_local_meter:
        meter.begin()
        poll_task = asyncio.create_task(meter.poll_forever())
    else:
        poll_task = None

    # Lead time so that every worker is forked and sitting in its sleep loop
    # before the schedule origin passes. Without it the first requests all fire
    # at once during startup and appear as dispatch delay the generator did not
    # actually cause.
    lead = 1.0 if workers > 1 else 0.0
    t_start = time.time() + lead

    if workers <= 1:
        agg = [await drive_slice(router, policy, endpoints,
                                 list(range(n_requests)), arrivals, t_start,
                                 seed, pool)]
    else:
        ctx = mp.get_context("fork")
        procs, paths = [], []
        for w in range(workers):
            idxs = list(range(w, n_requests, workers))
            slice_arrivals = [arrivals[i] for i in idxs]
            path = os.path.join(scratch,
                                "harness-w%d-%d.json" % (w, os.getpid()))
            paths.append(path)
            proc = ctx.Process(target=worker_entry,
                               args=(w, router, policy, endpoints, idxs,
                                     slice_arrivals, t_start, seed, pool,
                                     path))
            proc.start()
            procs.append(proc)
        loop = asyncio.get_running_loop()

        def _join():
            for proc in procs:
                proc.join()
            return [proc.exitcode for proc in procs]

        codes = await loop.run_in_executor(None, _join)
        bad = [c for c in codes if c != 0]
        if bad:
            raise SystemExit("load generator worker(s) exited %s - refusing to "
                             "report a cell with a dead worker" % bad)
        agg = []
        for path in paths:
            with open(path) as fh:
                agg.append(json.load(fh))
            os.unlink(path)

    t_end = time.time()
    latencies = [x for a in agg for x in a["latencies"]]
    ttfts = [x for a in agg for x in a["ttfts"]]
    ttfts_from_send = [x for a in agg for x in a["ttfts_from_send"]]
    send_delays = [x for a in agg for x in a["send_delays"]]
    all_itls = [x for a in agg for x in a["itls"]]
    completed = sum(a["completed"] for a in agg)
    errors = sum(a["errors"] for a in agg)
    t_energy_end = time.time()
    ru_self1 = resource.getrusage(resource.RUSAGE_SELF)
    ru_kids1 = resource.getrusage(resource.RUSAGE_CHILDREN)
    gen_cpu_s = ((ru_self1.ru_utime - ru_self0.ru_utime)
                 + (ru_self1.ru_stime - ru_self0.ru_stime)
                 + (ru_kids1.ru_utime - ru_kids0.ru_utime)
                 + (ru_kids1.ru_stime - ru_kids0.ru_stime))
    if use_local_meter:
        energy = meter.end()
    else:
        if multinode_energy is None:
            raise SystemExit("--energy-mode multinode needs multinode_energy.py "
                             "importable beside this script")
        # Let the per-node samplers catch up before aggregating. Each writes
        # on its own period, so immediately after a cell the newest sample is
        # up to one interval old and the window's end would sit beyond the
        # data. Waiting two intervals costs under a second per cell and makes
        # the clamp below a rare correction rather than the normal path.
        time.sleep(2.0 * SAMPLER_INTERVAL_S)
        agg = multinode_energy.aggregate(sample_dir, t_start, t_energy_end,
                                         clock_skew,
                                         tolerance_s=3.0 * SAMPLER_INTERVAL_S)
        if not agg["complete"]:
            # A fleet energy figure missing a node is wrong, not merely
            # smaller. Refuse the cell rather than publish a partial sum.
            raise SystemExit(
                "multinode energy incomplete: %d node(s) ok, %d failed. %s"
                % (agg["nodes_ok"], agg["nodes_failed"],
                   [n.get("error") for n in agg["nodes"] if "error" in n]))
        energy = {
            "window_s": t_energy_end - t_start,
            "total_energy_j": agg["total_energy_j"],
            "per_gpu": [g for n in agg["nodes"] for g in n["per_gpu"]],
            "multinode": {
                "nodes": [{k: v for k, v in n.items() if k != "per_gpu"}
                          for n in agg["nodes"]],
                "clock_skew_s": clock_skew,
                "skew_energy_uncertainty_j": agg["skew_energy_uncertainty_j"],
                "skew_energy_uncertainty_pct":
                    agg["skew_energy_uncertainty_pct"],
            },
        }
    rapl_after = rapl_read(zones)
    engine_after = scrape_engine_metrics(endpoints)
    if poll_task is not None:
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
    # Measured wall clock, not the intended schedule. The old denominator was
    # arrivals[-1] + worst latency, which is what the schedule *asked* for, so
    # goodput looked plausible even when the client never kept up.
    elapsed = max(1e-9, t_end - t_start)
    achieved = (completed + errors) / elapsed
    fidelity = achieved / rate if rate else 0.0
    sd_p99 = pct(send_delays, 0.99)
    sd_budget = max(SEND_DELAY_FLOOR_S, SEND_DELAY_SLO_FRAC * slo_s)
    return {
        "policy": policy,
        "offered_rate_rps": rate,
        "achieved_rate_rps": achieved,
        "rate_fidelity": fidelity,
        # Hard integrity flag, and the only one that invalidates a cell: the
        # generator fell behind its own arrival schedule, so the offered rate
        # is fiction and these energy and SLO numbers describe the client.
        "client_limited": (sd_p99 or 0.0) > sd_budget,
        "send_delay_budget_s": sd_budget,
        # Not a defect. The generator kept up and the servers could not, which
        # is the overload regime this study is about.
        "server_saturated": ((sd_p99 or 0.0) <= sd_budget
                             and fidelity < 0.95),
        "send_delay_p50": pct(send_delays, 0.50),
        "send_delay_p99": sd_p99,
        "send_delay_max": max(send_delays) if send_delays else None,
        "requests": n_requests,
        "completed": completed,
        "errors": errors,
        "slo_s": slo_s,
        "headroom": router.headroom,
        "pack_limit_s": router.pack_limit,
        "slo_met": met,
        "slo_rate": met / completed if completed else 0.0,
        # How close the latency distribution sits to the SLO boundary.
        # With a fixed output length, service time is roughly
        # TTFT + OUTPUT_TOKENS * TPOT, so an end-to-end SLO is really a
        # TPOT threshold and the whole distribution crosses it together:
        # measured 97.1% attainment at 271 req/s and 7.6% at 350, while
        # e2e p99 moved only 2.012 -> 2.225 s (job 12303354). Attainment
        # alone therefore says almost nothing about how much headroom a
        # policy had. These report the margin instead of hiding it.
        "slo_margin_p50": (pct(latencies, 0.50) / slo_s
                           if latencies and slo_s else None),
        "slo_margin_p95": (pct(latencies, 0.95) / slo_s
                           if latencies and slo_s else None),
        "frac_within_10pct_of_slo": (
            sum(1 for l in latencies if 0.9 * slo_s <= l <= 1.1 * slo_s)
            / len(latencies) if latencies else None),
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
        # Server-side TTFT, excluding any client dispatch delay. Reported only
        # as a diagnostic: when it diverges from ttft_p50 the client is behind.
        "ttft_from_send_p50": pct(ttfts_from_send, 0.50),
        "ttft_from_send_p95": pct(ttfts_from_send, 0.95),
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
        # Curve lookups that fell outside the measured concurrency range.
        # Anything materially above zero means the routing decisions in
        # this cell were not grounded in measurement, so the cell cannot
        # support a policy claim however clean its energy numbers look.
        "router_out_of_range": router.out_of_range,
        # Picks where no endpoint had curve data. Unlike the raw lookup
        # count above, this one can invalidate a policy claim.
        "router_ungrounded_picks": router.ungrounded_picks,
        # Policy ran its fallback because nothing met the SLO. Sound data,
        # but the policy was inactive, so no comparison rests on it.
        "router_saturated_picks": router.saturated_picks,
        "router_saturated_frac": (router.saturated_picks / completed
                                  if completed else None),
        "router_ungrounded_frac": (router.ungrounded_picks / completed
                                   if completed else None),
        "router_curve_max_concurrency": {
            t: (c["levels"][-1] if c.get("levels") else None)
            for t, c in curves.items()},
        "seed": seed,
        "poll_interval_s": poll_interval,
        "energy_mode": energy_mode,
        "generator_workers": workers,
        # CPU seconds burned by the generator itself during this cell.
        # Divide by the window to get mean cores occupied; that fraction
        # of the RAPL package figure is the client, not the workload.
        "generator_cpu_s": round(gen_cpu_s, 3),
        "generator_cpu_cores_mean": (round(gen_cpu_s / (t_end - t_start), 3)
                                     if t_end > t_start else None),
        "generator_pool_per_worker": pool,
        "rapl_energy_j": rapl_delta(rapl_before, rapl_after),
        "rapl_available": bool(zones),
        "engine_metrics_before": engine_before,
        "engine_metrics_after": engine_after,
        # Independent check on our own timestamps: same quantities, taken
        # inside the engine where no client scheduling can reach them.
        "latency_cross_check": server_vs_client_latency(
            engine_before, engine_after,
            st.mean(ttfts_from_send) if ttfts_from_send else None,
            st.mean(all_itls) if all_itls else None),
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
    ap.add_argument("--headroom", type=float, default=0.0,
                    help="packing policies admit an endpoint only while its "
                         "projected latency <= (1 - headroom) * SLO; 0 = Stage 2")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--workers", type=int, default=0,
                    help="load-generator processes; 0 = auto. One asyncio "
                         "process tops out near 115 req/s on this hardware "
                         "(measured, job 12303350), because per-token stream "
                         "parsing is CPU-bound in the event loop. Sharding "
                         "multiplies that; routing state stays shared so the "
                         "policies still see global in-flight counts.")
    ap.add_argument("--energy-mode", choices=("local", "multinode"),
                    default="local",
                    help="local reads this node's GPUs directly; multinode "
                         "stitches per-node sampler files, which is required "
                         "once endpoints span more than one machine because "
                         "NVML cannot see another node's counters")
    ap.add_argument("--sample-dir",
                    help="directory of energy-*.jsonl from node_energy_sampler")
    ap.add_argument("--clock-skew", type=float, default=0.0,
                    help="measured max wall-clock skew across nodes, seconds; "
                         "used to report how much energy the skew could "
                         "account for rather than to correct anything")
    ap.add_argument("--scratch", default="/tmp",
                    help="where worker result files are written")
    ap.add_argument("--poll-interval", type=float, default=0.25,
                    help="power-poll period in seconds; 0 = counter only "
                         "(used by the perturbation control arm)")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    if args.energy_mode == "multinode" and not args.sample_dir:
        raise SystemExit("--energy-mode multinode requires --sample-dir")

    endpoints = args.endpoints.split(",")
    gpus = [int(x) for x in args.gpus.split(",")]
    types = args.endpoint_types.split(",")
    if len(types) != len(endpoints):
        raise SystemExit("endpoint-types must match endpoints")

    curves = {}
    for spec in args.curves:
        path, _, name = spec.rpartition("=")
        curves[name] = load_curve(path)

    # Auto worker count. Half the cores, capped: the generator competes with
    # eight vLLM servers on the same node, and oversubscribing the node would
    # perturb the very thing being measured. One worker is kept as an explicit
    # option because the single-process path is the simpler one to reason about
    # when debugging.
    n_workers = args.workers
    if n_workers <= 0:
        cores = os.cpu_count() or 4
        n_workers = max(1, min(8, cores // 4))
    print("load generator: %d worker process(es)" % n_workers, flush=True)

    results = []
    for policy in args.policies.split(","):
        print(f"--- {policy} at {args.rate:.1f} req/s ---", flush=True)
        r = asyncio.run(run_policy(policy, endpoints, gpus, types, curves,
                                   args.rate, args.requests, args.slo, args.seed,
                                   poll_interval=args.poll_interval,
                                   workers=n_workers, scratch=args.scratch,
                                   energy_mode=args.energy_mode,
                                   sample_dir=args.sample_dir,
                                   clock_skew=args.clock_skew,
                                   headroom=args.headroom))
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
        print("    SLO margin p50/p95 " + g("slo_margin_p50", 3) + "/"
              + g("slo_margin_p95", 3) + " x SLO  within 10% of boundary "
              + (format((r["frac_within_10pct_of_slo"] or 0) * 100, ".1f")
                 + "%"), flush=True)
        print("    offered " + format(r["offered_rate_rps"], ".1f")
              + " req/s  achieved " + g("achieved_rate_rps", 1)
              + " req/s  fidelity " + format(r["rate_fidelity"] * 100, ".1f")
              + "%  send delay p99 " + g("send_delay_p99")
              + "s  TTFT from send p50 " + g("ttft_from_send_p50"), flush=True)
        if r.get("router_ungrounded_picks"):
            print("    *** UNGROUNDED ROUTING on %d of %d picks (%.1f%%): no "
                  "endpoint had curve data for its concurrency, so the policy "
                  "fell back to load balancing. Above a few percent this is "
                  "not the policy being measured."
                  % (r["router_ungrounded_picks"], r["completed"],
                     (r.get("router_ungrounded_frac") or 0) * 100), flush=True)
        elif r.get("router_saturated_frac", 0) and r["router_saturated_frac"] > 0.5:
            print("    (policy INACTIVE on %.0f%% of picks: the curve answered "
                  "but no endpoint met the SLO, so every policy ran the same "
                  "load-balancing fallback. Sound overload data; no policy "
                  "comparison can rest on this cell.)"
                  % (r["router_saturated_frac"] * 100), flush=True)
        elif r.get("router_out_of_range"):
            print("    (curve probed above its measured range %d time(s); "
                  "those endpoints were excluded as infeasible, which is the "
                  "intended conservative behaviour, and every pick still had "
                  "a grounded option)" % r["router_out_of_range"], flush=True)
        if r["client_limited"]:
            print("    *** CLIENT LIMITED: dispatch delay p99 "
                  + g("send_delay_p99") + "s exceeds the "
                  + format(r["send_delay_budget_s"], ".3f")
                  + "s budget. The generator fell behind its own schedule, so"
                  " this cell measures the client and must not be reported.",
                  flush=True)
        elif r["server_saturated"]:
            print("    (server-saturated: generator kept schedule, servers did"
                  " not keep up. Valid overload data point.)", flush=True)
        results.append(r)
        time.sleep(20)   # let the GPUs settle between policies

    bad = [r["policy"] for r in results if r["client_limited"]]
    with open(args.out, "w") as fh:
        json.dump({"results": results,
                   "endpoints": endpoints,
                   "types": types,
                   "gpus": gpus,
                   "client_limited_policies": bad}, fh, indent=2)
    print("wrote", args.out)
    if bad:
        # Exit nonzero so the batch script stops instead of writing a results
        # table that looks like a policy comparison but is a client benchmark.
        raise SystemExit("client-limited cells at " + format(args.rate, ".1f")
                         + " req/s: " + ",".join(bad)
                         + " - lower the offered rate or widen the generator")


if __name__ == "__main__":
    main()
