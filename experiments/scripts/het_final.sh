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

# ITL is the comparison that matters: the engine's own gap BETWEEN tokens
# against our client-side inter-token timestamps, the same quantity measured
# two ways. Request-level TPOT is a per-request mean over output tokens, so it
# is a near relative, kept beside it rather than instead of it.
#
# This block used to read server_tpot_mean_s alone, under the name
# vllm:time_per_output_token_seconds, which does not exist in vLLM 0.30.0. The
# field was therefore always None and printed as "engine 0.0000", i.e. a
# cross-check that silently compared our numbers against nothing and reported
# agreement. cross_check_usable is printed first so that state can never be
# mistaken for a result again.
rows = 0
flagged = 0
itl_absent = 0
for f in sorted(glob.glob(os.path.join(sys.argv[1], "policies-rate*.json"))):
    for r in json.load(open(f))["results"]:
        c = r.get("latency_cross_check") or {}
        if c.get("cross_check_usable") is False:
            flagged += 1
            continue
        if not c.get("server_ttft_mean_s"):
            continue
        rows += 1
        # Counted from the value itself, not from cross_check_usable, which is
        # absent in runs collected before the flag existed. Trusting the flag
        # alone reported "0 unusable" for job 12305232, every one of whose 25
        # cells is in fact missing the engine ITL histogram.
        if not c.get("server_itl_mean_s"):
            itl_absent += 1
        if rows > 6:
            continue

        def pair(ours, theirs, pct):
            if theirs:
                return "ours %.4f vs engine %.4f (%+.1f%%)" % (
                    ours or 0, theirs, pct or 0)
            return "ours %.4f vs engine ABSENT" % (ours or 0)

        print("  %-18s %4.0f req/s" % (r["policy"], r["offered_rate_rps"]))
        print("      TTFT %s" % pair(c.get("client_ttft_mean_s"),
                                     c.get("server_ttft_mean_s"),
                                     c.get("ttft_client_excess_pct")))
        print("      ITL  %s" % pair(c.get("client_itl_mean_s"),
                                     c.get("server_itl_mean_s"),
                                     c.get("itl_client_excess_pct")))
        print("      TPOT %s" % pair(c.get("client_itl_mean_s"),
                                     c.get("server_tpot_mean_s"),
                                     c.get("tpot_client_excess_pct")))

print()
print("  cells with a TTFT cross-check: %d" % rows)
print("  cells flagged cross_check_usable=false: %d" % flagged)
print("  cells missing the engine ITL histogram: %d" % itl_absent)
if itl_absent or flagged:
    print("  WARNING: a cell with no engine ITL histogram proves nothing about")
    print("  client inter-token accuracy. Do not quote agreement from it. If")
    print("  this is a run collected after 2026-10-07, the metric name is")
    print("  wrong again or the engine stopped exporting the histogram.")
else:
    print("  ITL cross-check populated for every cell.")
PY
