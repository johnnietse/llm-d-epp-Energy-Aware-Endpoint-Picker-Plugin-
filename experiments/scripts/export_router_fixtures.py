#!/usr/bin/env python3
"""Exports what the Go router plugin needs from the Python harness, so the two
cannot drift apart: the Stage 5 curves, and the fidelity fixtures.

    python3 experiments/scripts/export_router_fixtures.py

Why an exporter and not a Go reimplementation. The curve reduction (drop trial
1, stop at the first rate any trial could not keep up with, keep only rising
in-flight levels) took several rounds to get right in Python (plan 12.14d).
Writing it a second time in Go would create a second place for it to be wrong.
Instead the Go plugin reads the curves exactly as `load_openloop_curve`
reduced them, and is tested against decisions the Python `Router` made.

Outputs, both committed:
  router-plugin/curves/<type>.json
      levels, power, tok_s and lat_p95 of the Stage 5 curves (amendment B2),
      with the source curve.csv path and its sha256.
  router-plugin/pkg/energypolicy/testdata/fixtures.json
      For many fleet states, every policy's TIED SET: all endpoints the Python
      Router would choose between before its tie-break (amendment B5), and
      whether the pick was feasible, saturated or ungrounded. The Go scorer
      must give 1.0 to exactly that set (amendment B11).

The fixtures come from the real Router class with only `_best` overridden to
record the tied set, so the policy bodies under test are the measured ones,
not a copy. State generation is seeded: a re-run gives identical files.

pynvml and httpx are stubbed before the import. The harness requires them for
measurement, and neither is touched by curve loading or routing. The stubs
exist only in this offline exporter.
"""
import hashlib
import json
import os
import random
import sys
import types

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
for mod in ("pynvml", "httpx"):
    sys.modules.setdefault(mod, types.ModuleType(mod))
sys.path.insert(0, HERE)
import policy_harness as ph  # noqa: E402

# Amendment B2. Fixed; never selected by result.
CURVES = {
    "a100": "experiments/cluster-records/results/olc-12325349/curve.csv",
    "rtx6000": "experiments/cluster-records/results/olc-12325350/curve.csv",
}
FLEETS = {
    "mixed": ["a100"] * 4 + ["rtx6000"] * 4,
    "homog": ["rtx6000"] * 8,
}
POLICIES = ["least_loaded", "slo_packing", "energy_greedy", "energy_consolidate"]
SLO_S = 2.0
HEADROOMS = [0.0, 0.1]        # Stage 5 runs h = 0; 0.1 exercises the parameter
CAPS = [256, 64]              # Stage 5 runs 256; 64 makes the cap bind often
STATES_PER_FLEET = 300
SEED = 20261010

CURVE_DIR = os.path.join(REPO, "router-plugin", "curves")
FIXTURE = os.path.join(REPO, "router-plugin", "pkg", "energypolicy",
                       "testdata", "fixtures.json")


class RecordingRouter(ph.Router):
    """The measured Router, recording the set _best chooses between."""

    def _best(self, cands, key, maximize=False):
        cands = list(cands)
        keys = [key(k) for k in cands]
        best = max(keys) if maximize else min(keys)
        self.tied = sorted(k for k, v in zip(cands, keys) if v == best)
        return self.tied[0]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def export_curves():
    curves = {}
    os.makedirs(CURVE_DIR, exist_ok=True)
    for gpu, rel in CURVES.items():
        src = os.path.join(REPO, rel)
        cur = ph.load_curve(src)
        if not cur.get("openloop"):
            raise SystemExit("%s is not an open-loop curve" % rel)
        curves[gpu] = cur
        lv = cur["levels"]
        out = {
            "gpu_type": gpu,
            "source": rel,
            "source_sha256": sha256(src),
            "reduced_by": "policy_harness.load_openloop_curve",
            "levels": lv,
            "power": [cur["power"][L] for L in lv],
            "tok_s": [cur["tok_s"][L] for L in lv],
            "lat_p95": [cur["lat_p95"][L] for L in lv],
        }
        with open(os.path.join(CURVE_DIR, gpu + ".json"), "w") as fh:
            json.dump(out, fh, indent=1)
            fh.write("\n")
        print("%-8s %2d levels, in-flight %.2f to %.2f, p95 %.3f to %.3f s"
              % (gpu, len(lv), lv[0], lv[-1], out["lat_p95"][0], out["lat_p95"][-1]))
    return curves


def states(fleet, curves, rng):
    """In-flight vectors that reach every branch: idle, light, near each
    curve's end (in and out of range), at and over the cap, and ties."""
    n = len(fleet)
    last = {g: int(curves[g]["levels"][-1]) for g in set(fleet)}
    out = [[0] * n, [1] * n, [50] * n, [last[fleet[0]]] * n,
           [last[fleet[0]] + 5] * n, [256] * n, [63] * n, [64] * n]
    for _ in range(STATES_PER_FLEET):
        v = []
        for g in fleet:
            r = rng.random()
            if r < 0.2:
                v.append(0)
            elif r < 0.5:
                v.append(rng.randint(1, last[g]))
            elif r < 0.75:
                v.append(max(0, last[g] + rng.randint(-3, 3)))
            elif r < 0.85:
                v.append(rng.randint(250, 260))
            else:
                v.append(rng.choice([1, 2, 10, 20, 40]))   # repeats make ties
        out.append(v)
    return out


def main():
    curves = export_curves()
    rng = random.Random(SEED)
    cases = []
    tally = {}
    for fname, fleet in FLEETS.items():
        for state in states(fleet, curves, rng):
            for h in HEADROOMS:
                for cap in CAPS:
                    for pol in POLICIES:
                        r = RecordingRouter(len(fleet), fleet, curves, SLO_S,
                                            headroom=h, max_inflight=cap,
                                            tiebreak="random", seed=0)
                        r._inflight = list(state)
                        sat0, ung0 = r.saturated_picks, r.ungrounded_picks
                        r.pick(pol)
                        outcome = ("ungrounded" if r.ungrounded_picks > ung0 else
                                   "saturated" if r.saturated_picks > sat0 else
                                   "feasible")
                        cases.append({"fleet": fname, "headroom": h,
                                      "max_inflight": cap, "policy": pol,
                                      "inflight": state, "tied": r.tied,
                                      "outcome": outcome})
                        k = (pol, outcome)
                        tally[k] = tally.get(k, 0) + 1
    rr = RecordingRouter(8, FLEETS["mixed"], curves, SLO_S, tiebreak="random")
    rr_seq = [rr.pick("round_robin") for _ in range(20)]
    os.makedirs(os.path.dirname(FIXTURE), exist_ok=True)
    with open(FIXTURE, "w") as fh:
        json.dump({"generated_by": "experiments/scripts/export_router_fixtures.py",
                   "seed": SEED, "slo_s": SLO_S, "fleets": FLEETS,
                   "curves": {g: "router-plugin/curves/%s.json" % g for g in CURVES},
                   "round_robin_sequence": rr_seq, "cases": cases}, fh)
        fh.write("\n")
    print("%d cases" % len(cases))
    for (pol, oc), c in sorted(tally.items()):
        print("  %-20s %-10s %5d" % (pol, oc, c))
    multi = sum(1 for c in cases if len(c["tied"]) > 1)
    print("cases with a tie (more than one endpoint in the set): %d" % multi)


if __name__ == "__main__":
    main()
