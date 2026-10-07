import glob
import json
import os

h = os.path.expanduser("~/energy-epp/results/stage2het-12319685")
r = os.path.expanduser("~/energy-epp/results/stage2-12319815")
for d in (h, r):
    fs = sorted(glob.glob(os.path.join(d, "policies-rate*.json")))
    print("dir:", d)
    print("  files:", len(fs))
    if not fs:
        continue
    top = json.load(open(fs[0]))
    print("  top-level keys:", sorted(top.keys()))
    res = top.get("results") or []
    print("  results len:", len(res))
    if res:
        print("  cell keys:", sorted(res[0].keys()))
