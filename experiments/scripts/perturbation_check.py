#!/usr/bin/env python3
"""Does the mandatory telemetry cost anything measurable?

Compares the Pass A cell for slo_packing (full telemetry: NVML counter reads
plus a 4 Hz power poll, with a DCGM host engine alive) against the Pass
A-control cell for the same policy at the same offered load with the power poll
disabled (two counter reads per window, nothing else).

If the two agree, the instrumentation is free and every number in Pass A stands
unqualified. If they disagree by more than 1%, the telemetry is perturbing the
measurement and must be trimmed - the result is NOT accepted with a caveat.

Usage: perturbation_check.py <pass-a.json> <control.json>
"""
import json
import sys


def pick(path, policy="slo_packing"):
    with open(path) as fh:
        rows = json.load(fh)["results"]
    for r in rows:
        if r["policy"] == policy:
            return r
    return rows[0] if rows else None


def main():
    if len(sys.argv) < 3:
        raise SystemExit("usage: perturbation_check.py <pass-a.json> <control.json>")
    full, ctrl = pick(sys.argv[1]), pick(sys.argv[2])
    if not full or not ctrl:
        print("  cannot compare: a required cell is missing")
        return

    a, b = full.get("j_per_request"), ctrl.get("j_per_request")
    print(f"  full telemetry : {a:.3f} J/req   poll={full.get('poll_interval_s')}s "
          f"SLO={full['slo_rate']*100:.1f}%  p95={full['latency_p95']:.3f}s")
    print(f"  counter only   : {b:.3f} J/req   poll={ctrl.get('poll_interval_s')}s "
          f"SLO={ctrl['slo_rate']*100:.1f}%  p95={ctrl['latency_p95']:.3f}s")

    if not (a and b):
        print("  cannot compare: missing J/req")
        return

    d_energy = (a - b) / b * 100.0
    print(f"  energy difference    : {d_energy:+.2f}%")

    pa, pb = full.get("latency_p95"), ctrl.get("latency_p95")
    if pa and pb:
        print(f"  p95 difference       : {(pa - pb) / pb * 100.0:+.2f}%")

    # throughput proxy: completed requests over the same offered load
    ca, cb = full.get("completed"), ctrl.get("completed")
    if ca and cb:
        print(f"  completed difference : {(ca - cb) / cb * 100.0:+.2f}%")

    if abs(d_energy) < 1.0:
        print("  VERDICT: telemetry overhead is not measurable (<1%). Pass A")
        print("  numbers stand unqualified.")
    else:
        print("  VERDICT: CHECK. The telemetry may be perturbing the measurement.")
        print("  Trim it (drop the power poll, or stop the DCGM host engine during")
        print("  Pass A) and re-run. Do not accept Pass A with a caveat.")


if __name__ == "__main__":
    main()
