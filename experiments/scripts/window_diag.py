#!/usr/bin/env python3
"""Compare the sampler files' time span against the windows the harness asked
for, to explain 'window not covered by samples'."""
import glob, importlib.util, json, os, sys, time

J = sys.argv[1]
R = os.path.expanduser("~/energy-epp/results/stage2het-%s" % J)
spec = importlib.util.spec_from_file_location(
    "mne", os.path.expanduser("~/energy-epp/scripts/multinode_energy.py"))
mne = importlib.util.module_from_spec(spec); spec.loader.exec_module(mne)

print("=== sampler file spans ===")
spans = []
for p in sorted(glob.glob(os.path.join(R, "samples", "energy-*.jsonl"))):
    hdr, s = mne.load(p)
    if not s:
        print("  %-42s NO SAMPLES" % os.path.basename(p)); continue
    t0, t1 = s[0]["t"], s[-1]["t"]
    spans.append((t0, t1))
    print("  %-42s %d samples" % (os.path.basename(p), len(s)))
    print("      first %s  last %s  span %.1f s"
          % (time.strftime('%H:%M:%S', time.localtime(t0)),
             time.strftime('%H:%M:%S', time.localtime(t1)), t1 - t0))
    print("      mean interval %.3f s" % ((t1 - t0) / max(1, len(s) - 1)))
    print("      header gpus: %s" % len(hdr.get("gpus", [])) if hdr else "no header")

print()
print("=== what windows did the cells ask for? ===")
for f in sorted(glob.glob(os.path.join(R, "policies-rate*.json"))):
    print("  %s exists" % os.path.basename(f))
if not glob.glob(os.path.join(R, "policies-rate*.json")):
    print("  none written - every cell aborted before writing output")

if spans:
    lo = max(s[0] for s in spans); hi = min(s[1] for s in spans)
    print()
    print("=== overlap all nodes genuinely cover ===")
    print("  %s .. %s  (%.1f s)"
          % (time.strftime('%H:%M:%S', time.localtime(lo)),
             time.strftime('%H:%M:%S', time.localtime(hi)), hi - lo))
    if hi > lo:
        agg = mne.aggregate(os.path.join(R, "samples"), lo + 1, hi - 1, 0.06)
        print("  aggregate over that overlap: complete=%s total=%.1f J nodes_ok=%d"
              % (agg["complete"], agg["total_energy_j"], agg["nodes_ok"]))
