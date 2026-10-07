#!/usr/bin/env bash
# Verifies, with evidence rather than assertion, that each defect found in this
# session is actually fixed in the files on the cluster. Cheap enough to re-run
# any time; it touches nothing and submits nothing.
set -u
cd "$HOME/energy-epp/scripts" || exit 1
PASS=0; FAIL=0
ok()  { echo "  [OK]   $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo "=== 1. node-local staging present, GPFS out of the serving path ==="
# Checks the CURRENT design: one uniform staging path on every node. The
# earlier version discovered a writable directory per step, which was right in
# itself but incompatible with exporting a single HF_HOME to every node, and
# that mismatch killed half the servers in job 12304926. This check kept the
# pre-rewrite patterns, so it reported FAIL against working code. A
# verification script that lags the thing it verifies is worse than none: it
# spends attention on a false alarm and teaches you to distrust real ones.
if grep -q 'STAGE_DIR="/tmp/hfstage-\$SLURM_JOB_ID"' stage2_het.sbatch \
   && grep -q 'export HF_HOME="\$STAGE_DIR"' stage2_het.sbatch \
   && grep -q 'HF_HUB_OFFLINE=1' stage2_het.sbatch; then
  ok "stages to one uniform node-local path, HF_HOME repointed offline"
else
  bad "staging block missing or incomplete"
fi
if grep -q 'cannot read the model at \$HF_HOME' stage2_het.sbatch; then
  ok "every node verified able to read the model at the final HF_HOME"
else
  bad "no per-node verification of the staged path"
fi
if grep -q 'Refusing to fall back to GPFS reads' stage2_het.sbatch; then
  ok "staging failure is fatal, no silent GPFS fallback"
else
  bad "staging failure may fall back to GPFS"
fi

echo
echo "=== 2. the pre-warm defect (globbed the 7B model too) is gone ==="
if grep -q 'warm the checkpoint' stage2_het.sbatch; then
  bad "old pre-warm block still present"
else
  ok "pre-warm removed, replaced by staging"
fi
if grep -q 'MODEL_DIR_NAME=' stage2_het.sbatch; then
  ok "stages only the served model, by derived directory name"
else
  bad "no per-model scoping"
fi

echo
echo "=== 3. model weights resolve through the symlinks (the 12 MB red herring) ==="
HF="$HOME/energy-epp/.hf"
MDN="models--Qwen--Qwen2.5-1.5B-Instruct"
APPARENT="$(du -sm "$HF/hub/$MDN" 2>/dev/null | cut -f1)"
RESOLVED="$(find "$HF/hub/$MDN" -name '*.safetensors' -exec stat -Lc %s {} + 2>/dev/null \
            | awk '{s+=$1} END{printf "%d", s/1048576}')"
echo "       du says ${APPARENT:-?} MiB, resolved weights are ${RESOLVED:-?} MiB"
if [ "${RESOLVED:-0}" -gt 2000 ]; then
  ok "weights found and over 2 GiB; staging will copy something real"
else
  bad "weights do not resolve; staging would abort"
fi

echo
echo "=== 4. known-bad shell patterns absent from the het scripts ==="
for pat_label in \
  "source /cvmfs/soft.computecanada.ca/config/profile|profile source (execs a replacement shell)" \
  "pkill -f|pkill by pattern (self-match under srun)"; do
  pat="${pat_label%%|*}"; label="${pat_label##*|}"
  hits="$(grep -n -- "$pat" stage2_het.sbatch het_submit.sh het_watch.sh 2>/dev/null \
          | grep -v ':[[:space:]]*#' | wc -l)"
  if [ "$hits" -eq 0 ]; then ok "$label absent"; else bad "$label present ($hits)"; fi
done

echo
echo "=== 5. submit refuses duplicates and pre-flights ==="
for needle_label in \
  "REFUSING: stage2-het already queued|duplicate guard" \
  "generator ceiling|load level vs generator ceiling check" \
  "resolves to|weights resolved before submit" \
  "bash -n stage2_het.sbatch|syntax pre-flight"; do
  n="${needle_label%%|*}"; l="${needle_label##*|}"
  if grep -q -- "$n" het_submit.sh; then ok "$l"; else bad "$l missing"; fi
done

echo
echo "=== 6. watch is separate and bounded (the exit-143 cause) ==="
if [ -f het_watch.sh ] && grep -q 'MAXMIN' het_watch.sh; then
  ok "het_watch.sh exists with a bounded window"
else
  bad "watch not separated or unbounded"
fi
if grep -q 'sbatch --parsable' het_submit.sh && ! grep -q 'seq 1 100' het_submit.sh; then
  ok "submit returns promptly, no long internal loop"
else
  bad "submit still contains a long wait loop"
fi

echo
echo "=== 7. the gate separates saturation from missing curve data ==="
if grep -q 'router_saturated_frac' policy_harness.py \
   && grep -q '_no_feasible' policy_harness.py; then
  ok "harness records saturated vs ungrounded separately"
else
  bad "harness still conflates them"
fi
if grep -q 'policy INACTIVE' stage2_analyse.py \
   && grep -q 'reclassify_legacy' stage2_analyse.py; then
  ok "analyser excludes inactive cells and can read legacy runs"
else
  bad "analyser missing the three-state logic"
fi

echo
echo "=== 9. latency cross-check uses VERIFIED metric names ==="
for nm in vllm:time_to_first_token_seconds vllm:inter_token_latency_seconds           vllm:request_time_per_output_token_seconds vllm:e2e_request_latency_seconds; do
  grep -q "$nm" policy_harness.py && ok "$nm" || bad "$nm missing"
done
# The wrong name may remain in a comment explaining the bug; it must not be in
# a string the code actually uses.
if grep -n 'vllm:time_per_output_token_seconds' policy_harness.py 2>/dev/null      | grep -qv '^[0-9]*:#'; then
  bad "the non-existent TPOT name is still used in code"
else
  ok "non-existent TPOT name appears only in commentary"
fi
grep -q 'cross_check_usable' policy_harness.py   && ok "cross-check reports whether it found any engine histogram"   || bad "no cross_check_usable flag"

echo
echo "=== 10. a finished het run reports COMPLETED, not CANCELLED ==="
grep -q 'wait 2>/dev/null' stage2_het.sbatch   && ok "cleanup waits for srun steps before the script exits"   || bad "cleanup does not wait; Slurm will record CANCELLED"
tail -3 stage2_het.sbatch | grep -q '^exit 0'   && ok "explicit exit 0 at the end of the sweep"   || bad "no explicit success exit"

echo
echo "=== 11. BOTH arms of the comparison share a read path (threat N15) ==="
# The headline claim contrasts a heterogeneous fleet against a homogeneous one.
# Until 2026-10-07 only stage2_het.sbatch staged the checkpoint node-locally,
# so stage2_real.sbatch served from GPFS and the two arms differed in read path
# as well as fleet composition. A reviewer is entitled to ask which variable
# moved. This check exists so that cannot drift apart again silently.
for f in stage2_het.sbatch stage2_real.sbatch; do
  miss=""
  grep -q 'STAGE_DIR="/tmp/hfstage-\$SLURM_JOB_ID"' "$f" || miss="$miss staging"
  grep -q 'export HF_HOME="\$STAGE_DIR"' "$f"            || miss="$miss hf_home"
  grep -q 'HF_HUB_OFFLINE=1' "$f"                        || miss="$miss offline"
  grep -q 'Refusing to fall back to GPFS reads' "$f"     || miss="$miss no_fallback"
  grep -q 'wait 2>/dev/null' "$f"                        || miss="$miss wait"
  tail -4 "$f" | grep -q '^exit 0' || miss="$miss exit0"
  if [ -z "$miss" ]; then
    ok "$f: staging, offline, fatal-on-failure, wait, exit 0"
  else
    bad "$f missing:$miss"
  fi
done

echo
echo "=== 12. the homogeneous control is pinned and GPU-count matched ==="
if [ -f real_submit.sh ]; then
  # -w, not -C. Driver version, profiling permission and idle power were each
  # measured to vary between nodes of the same GPU model, so a control run on
  # an unspecified node of the right type is not a control.
  grep -q -- '-w "\$NODE"' real_submit.sh \
    && ok "pins the node explicitly rather than selecting by feature" \
    || bad "does not pin the node with -w"
  grep -q 'rtx6000:8' real_submit.sh \
    && ok "asserts 8 GPUs, matching the 4+4 heterogeneous fleet" \
    || bad "no 8-GPU assertion"
  grep -q 'RATES:-200,300,400,500,600' real_submit.sh \
    && ok "offered load pinned to the heterogeneous ladder, not derived" \
    || bad "rates not pinned to the het ladder; arms would be incomparable"
  grep -q 'COMPLETING' real_submit.sh \
    && ok "refuses to submit onto a node in the wedge state" \
    || bad "does not check for COMPLETING"
else
  bad "real_submit.sh absent; the matched control cannot be submitted"
fi

echo
echo "=== 8. every script parses ==="
for f in stage2_het.sbatch stage2_real.sbatch het_submit.sh het_watch.sh \
         real_submit.sh het_status.sh het_final.sh; do
  [ -f "$f" ] || { bad "bash: $f absent"; continue; }
  bash -n "$f" 2>/dev/null && ok "bash: $f" || bad "bash: $f"
done
for f in policy_harness.py multinode_energy.py node_energy_sampler.py \
         stage2_analyse.py curve_report.py provisional_report.py; do
  python3 -c "import ast;ast.parse(open('$f').read())" 2>/dev/null \
    && ok "python: $f" || bad "python: $f"
done

echo
echo "=================================================="
echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "ALL VERIFIED" || echo "SOMETHING IS STILL BROKEN"
exit "$FAIL"
