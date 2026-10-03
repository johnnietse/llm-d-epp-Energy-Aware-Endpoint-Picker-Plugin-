#!/usr/bin/env python3
"""H1 measurement: per-endpoint power and energy per token as a function of load.

Hypothesis under test: P(b, t) ~ P_idle + k_b*b + k_t*t, fitted per
(GPU, model, precision, TP) configuration.

Method notes:
  - Energy comes from the NVML hardware counter (nvmlDeviceGetTotalEnergyConsumption),
    not integrated power polls: on recent GPUs the on-board sensor is sampled only
    part of the time, so averaging polls misestimates energy (Yang et al., SC24).
  - Token counts come from vLLM's own Prometheus counters, so J/token uses the
    engine's accounting rather than our estimate of it.
  - Each load level runs to steady state, with warm-up discarded, and the whole
    sweep is repeated for `--trials` so variance is visible.

Stdlib only: the cluster python has pynvml but not requests/aiohttp.
"""
import argparse, csv, json, os, random, statistics, sys, threading, time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

try:
    import pynvml as nvml
except ImportError:
    sys.exit("needs nvidia-ml-py (pynvml)")

PROMPT_BANK = [
    "Explain how GPU power capping affects inference throughput.",
    "Summarise the tradeoff between batch size and latency in LLM serving.",
    "Describe why decode is memory-bandwidth bound.",
    "What is prefix caching and when does it help?",
    "How does tensor parallelism change energy per token?",
]
SHARED_PREFIX = (
    "You are a careful systems engineer. Answer precisely and briefly. "
    "Context: we operate a GPU inference cluster and care about energy per token. "
) * 8  # ~hundreds of tokens, identical across requests -> high prefix-cache hit


def http_post(url, payload, timeout=300):
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def scrape_metrics(base):
    """Return vLLM counters we need: generated tokens, prompt tokens, running reqs."""
    out = {}
    try:
        with urllib.request.urlopen(base + "/metrics", timeout=10) as r:
            for line in r.read().decode().splitlines():
                if line.startswith("#"):
                    continue
                for key, name in (("vllm:generation_tokens_total", "gen_tokens"),
                                  ("vllm:prompt_tokens_total", "prompt_tokens"),
                                  ("vllm:num_requests_running", "running"),
                                  ("vllm:num_requests_waiting", "waiting")):
                    if line.startswith(key):
                        try:
                            out[name] = float(line.rsplit(" ", 1)[1])
                        except (ValueError, IndexError):
                            pass
    except Exception:
        pass
    return out


class EnergyWindow:
    """Energy counter delta across a measurement window, with a power trace."""

    def __init__(self, handle, sample_s=0.5):
        self.h, self.sample_s = handle, sample_s
        self._stop = threading.Event()
        self.powers = []

    def _poll(self):
        while not self._stop.is_set():
            try:
                self.powers.append(nvml.nvmlDeviceGetPowerUsage(self.h) / 1000.0)
            except nvml.NVMLError:
                pass
            self._stop.wait(self.sample_s)

    def __enter__(self):
        self.e0 = nvml.nvmlDeviceGetTotalEnergyConsumption(self.h)
        self.t0 = time.time()
        self.thread = threading.Thread(target=self._poll, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *exc):
        self.t1 = time.time()
        self.e1 = nvml.nvmlDeviceGetTotalEnergyConsumption(self.h)
        self._stop.set()
        self.thread.join(timeout=2)

    @property
    def seconds(self):
        return self.t1 - self.t0

    @property
    def joules(self):
        return (self.e1 - self.e0) / 1000.0

    @property
    def watts(self):
        return self.joules / self.seconds if self.seconds else 0.0

    @property
    def polled_watts(self):
        return statistics.fmean(self.powers) if self.powers else 0.0


def closed_loop(base, model, concurrency, seconds, max_tokens, shared_prefix, stop_after=None):
    """Keep `concurrency` requests in flight for `seconds`. Returns latencies."""
    url = base + "/v1/completions"
    deadline = time.time() + seconds
    lat, errors = [], 0
    lock = threading.Lock()

    def worker(wid):
        nonlocal errors
        rng = random.Random(wid)
        while time.time() < deadline:
            prompt = rng.choice(PROMPT_BANK)
            if shared_prefix:
                prompt = SHARED_PREFIX + prompt
            else:
                prompt = f"[session {wid}-{rng.random()}] " + prompt
            t = time.time()
            try:
                http_post(url, {"model": model, "prompt": prompt,
                                "max_tokens": max_tokens, "temperature": 0.0})
                with lock:
                    lat.append(time.time() - t)
            except Exception:
                with lock:
                    errors += 1

    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        for i in range(concurrency):
            pool.submit(worker, i)
    return lat, errors


def measure(handle, base, model, concurrency, seconds, max_tokens, shared_prefix, warmup):
    """One load level: warm up, then measure energy + tokens over the window."""
    if warmup:
        closed_loop(base, model, concurrency, warmup, max_tokens, shared_prefix)
    m0 = scrape_metrics(base)
    with EnergyWindow(handle) as w:
        lat, errors = closed_loop(base, model, concurrency, seconds, max_tokens, shared_prefix)
    m1 = scrape_metrics(base)

    gen = m1.get("gen_tokens", 0) - m0.get("gen_tokens", 0)
    prompt_toks = m1.get("prompt_tokens", 0) - m0.get("prompt_tokens", 0)
    lat_sorted = sorted(lat)

    def pct(p):
        return lat_sorted[min(int(len(lat_sorted) * p), len(lat_sorted) - 1)] if lat_sorted else 0.0

    return {
        "concurrency": concurrency,
        "shared_prefix": int(bool(shared_prefix)),
        "window_s": round(w.seconds, 2),
        "energy_j": round(w.joules, 1),
        "mean_power_w": round(w.watts, 2),
        "polled_power_w": round(w.polled_watts, 2),
        "gen_tokens": int(gen),
        "prompt_tokens": int(prompt_toks),
        "j_per_gen_token": round(w.joules / gen, 4) if gen else None,
        "requests": len(lat),
        "errors": errors,
        "throughput_rps": round(len(lat) / w.seconds, 2) if w.seconds else 0,
        "gen_tok_per_s": round(gen / w.seconds, 1) if w.seconds else 0,
        "lat_p50_s": round(pct(0.50), 3),
        "lat_p95_s": round(pct(0.95), 3),
        "running_end": m1.get("running"),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://127.0.0.1:8100")
    ap.add_argument("--model", required=True)
    ap.add_argument("--gpu", type=int, default=0)
    ap.add_argument("--levels", default="1,2,4,8,16,32")
    ap.add_argument("--seconds", type=float, default=75)
    ap.add_argument("--warmup", type=float, default=15)
    ap.add_argument("--max-tokens", type=int, default=128)
    ap.add_argument("--trials", type=int, default=1)
    ap.add_argument("--prefix-levels", default="8",
                    help="concurrency levels to also run with a shared prefix")
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    nvml.nvmlInit()
    h = nvml.nvmlDeviceGetHandleByIndex(args.gpu)
    gpu_name = nvml.nvmlDeviceGetName(h)
    gpu_name = gpu_name.decode() if isinstance(gpu_name, bytes) else gpu_name

    levels = [int(x) for x in args.levels.split(",") if x]
    prefix_levels = {int(x) for x in args.prefix_levels.split(",") if x}

    rows = []
    # idle with model resident: the baseline the marginal model needs
    with EnergyWindow(h) as w:
        time.sleep(30)
    rows.append({"concurrency": 0, "shared_prefix": 0, "window_s": round(w.seconds, 2),
                 "energy_j": round(w.joules, 1), "mean_power_w": round(w.watts, 2),
                 "polled_power_w": round(w.polled_watts, 2), "gen_tokens": 0,
                 "prompt_tokens": 0, "j_per_gen_token": None, "requests": 0, "errors": 0,
                 "throughput_rps": 0, "gen_tok_per_s": 0, "lat_p50_s": 0, "lat_p95_s": 0,
                 "running_end": 0, "trial": 0, "note": "idle_model_loaded"})
    print(f"idle(model loaded): {rows[-1]['mean_power_w']} W", flush=True)

    for trial in range(1, args.trials + 1):
        for c in levels:
            for shared in ([False, True] if c in prefix_levels else [False]):
                r = measure(h, args.base, args.model, c, args.seconds,
                            args.max_tokens, shared, args.warmup)
                r["trial"] = trial
                r["note"] = "shared_prefix" if shared else "unique_prompts"
                rows.append(r)
                print(f"trial{trial} c={c:<3} prefix={int(shared)} "
                      f"{r['mean_power_w']:>6} W  {r['gen_tok_per_s']:>7} tok/s  "
                      f"J/tok={r['j_per_gen_token']}  p95={r['lat_p95_s']}s "
                      f"err={r['errors']}", flush=True)

    fields = ["trial", "note", "concurrency", "shared_prefix", "window_s", "energy_j",
              "mean_power_w", "polled_power_w", "gen_tokens", "prompt_tokens",
              "j_per_gen_token", "requests", "errors", "throughput_rps",
              "gen_tok_per_s", "lat_p50_s", "lat_p95_s", "running_end"]
    with open(args.out, "w", newline="") as f:
        wri = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        wri.writeheader()
        for r in rows:
            wri.writerow(r)
    print(f"\nwrote {args.out} ({len(rows)} rows) gpu={gpu_name}", flush=True)


if __name__ == "__main__":
    main()
