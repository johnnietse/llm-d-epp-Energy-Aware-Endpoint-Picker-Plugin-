set -u
J="${1:?jobid}"
R="$HOME/energy-epp/results/stage2het-$J"
L="$HOME/energy-epp/scripts/stage2-het-$J.out"

echo "waiting for het job $J"
for i in $(seq 1 180); do
  [ -z "$(squeue -h -j "$J" 2>/dev/null)" ] && { echo "finished"; break; }
  sleep 30
done
echo
sacct -n -X -j "$J" --format=JobID,State,Elapsed,ExitCode,NodeList -P 2>/dev/null

echo
echo "=== setup ==="
grep -aE "component [0-9]:|fleet:|MiB of weights staged|verified on all|skew bound|ready: |SLO =|PEAK_RPS|load levels" "$L" 2>/dev/null | sed 's/^/  /' | head -14

echo
echo "=== integrity ==="
printf '  cells:            %s\n' "$(grep -ac 'J/req' "$R/harness.log" 2>/dev/null || echo 0)"
printf '  client_limited:   %s\n' "$(grep -a 'CLIENT LIMITED' "$R/harness.log" 2>/dev/null | wc -l)"
printf '  ungrounded:       %s\n' "$(grep -a 'UNGROUNDED ROUTING' "$R/harness.log" 2>/dev/null | wc -l)"
printf '  energy incomplete:%s\n' "$(grep -a 'multinode energy incomplete' "$R/harness.log" 2>/dev/null | wc -l)"

echo
echo "=== per-cell, with the per-node energy split ==="
python3 - "$R" <<'PY'
import glob, json, os, sys
R = sys.argv[1]
rows = {}
for f in sorted(glob.glob(os.path.join(R, "policies-rate*.json"))):
    for r in json.load(open(f))["results"]:
        rows.setdefault(r["offered_rate_rps"], {})[r["policy"]] = r
order = ("round_robin","least_loaded","slo_packing","energy_greedy","energy_consolidate")
for rate in sorted(rows):
    print("\n### offered %.0f req/s" % rate)
    print("%-20s %7s %7s %9s %8s %9s %9s" % ("policy","J/req","SLO%","gp/J","margp95","A100 J","RTX6000 J"))
    for n in order:
        r = rows[rate].get(n)
        if not r: continue
        nd = ((r.get("energy") or {}).get("multinode") or {}).get("nodes") or []
        per = {}
        for x in nd:
            per[x.get("host","?").split(".")[0]] = x.get("total_energy_j") or 0
        a100 = next((v for k,v in per.items() if k in ("frnt154","frnt190","frnt191")), 0)
        rtx  = next((v for k,v in per.items() if k not in ("frnt154","frnt190","frnt191")), 0)
        print("%-20s %7.2f %7.1f %9.4f %8.3f %9.0f %9.0f" % (
            n, r.get("j_per_request") or 0, r["slo_rate"]*100,
            r.get("goodput_per_joule") or 0, r.get("slo_margin_p95") or 0, a100, rtx))
PY

echo
echo "=== latency cross-check: our timestamps vs the engine's own ==="
python3 - "$R" <<'PY'
import glob, json, os, sys
for f in sorted(glob.glob(os.path.join(sys.argv[1], "policies-rate*.json")))[:2]:
    for r in json.load(open(f))["results"][:2]:
        c = r.get("latency_cross_check") or {}
        if c.get("server_ttft_mean_s"):
            print("  %-18s %4.0f req/s  TTFT ours %.4f vs engine %.4f (%+.1f%%)  "
                  "TPOT ours %.4f vs engine %.4f (%+.1f%%)" % (
                r["policy"], r["offered_rate_rps"],
                c["client_ttft_mean_s"] or 0, c["server_ttft_mean_s"],
                c.get("ttft_client_excess_pct") or 0,
                c["client_itl_mean_s"] or 0, c["server_tpot_mean_s"] or 0,
                c.get("tpot_client_excess_pct") or 0))
PY
