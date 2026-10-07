set -u
J="${1:?jobid}"
R="$HOME/energy-epp/results/stage2het-$J"
echo "=== cells so far ==="
grep -aE "^--- |J/req|offered .* achieved|SLO margin|CLIENT LIMITED|UNGROUNDED|INACTIVE" \
  "$R/harness.log" 2>/dev/null | tail -24
echo
echo "=== did multinode energy resolve? (per-node split of the latest cell) ==="
python3 - "$R" <<'PY'
import glob, json, os, sys
R = sys.argv[1]
fs = sorted(glob.glob(os.path.join(R, "policies-rate*.json")))
if not fs:
    print("  no policies-rate*.json yet")
else:
    for f in fs:
        d = json.load(open(f))
        for r in d["results"]:
            mn = (r.get("energy") or {}).get("multinode") or {}
            nodes = mn.get("nodes") or []
            print("  %-20s %6.1f req/s  fleet %8.1f J  J/req %6.2f  SLO %5.1f%%"
                  % (r["policy"], r["offered_rate_rps"],
                     r["energy"]["total_energy_j"], r.get("j_per_request") or 0,
                     r["slo_rate"]*100))
            for n in nodes:
                print("      %-14s %8.1f J  %6.1f W  clamp_end=%ss"
                      % (n.get("host","?"), n.get("total_energy_j") or 0,
                         n.get("mean_power_w") or 0,
                         n.get("window_clamped_end_s")))
            if mn:
                print("      skew %ss -> uncertainty %s J (%s%%)"
                      % (mn.get("clock_skew_s"),
                         mn.get("skew_energy_uncertainty_j"),
                         mn.get("skew_energy_uncertainty_pct")))
PY
