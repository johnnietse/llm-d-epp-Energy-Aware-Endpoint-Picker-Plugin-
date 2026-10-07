#!/usr/bin/env bash
# Submits router_overhead.sbatch after cheap pre-flight. SUBMIT ONLY.
set -u
cd "$HOME/energy-epp/scripts" || exit 1
EXISTING="$(squeue -h -u "$(id -un)" -n router-overhead -o '%i' 2>/dev/null | tr '\n' ' ')"
[ -z "${EXISTING// /}" ] || { echo "REFUSING: router-overhead already queued: $EXISTING"; exit 1; }
bash -n router_overhead.sbatch || { echo "FATAL: syntax"; exit 1; }
[ -x "$HOME/energy-epp/bin/epp-energy-v0.11.0" ] || { echo "FATAL: EPP binary missing"; exit 1; }
T="$(git -C "$HOME/energy-epp/llm-d-router" describe --tags --exact-match 2>/dev/null)"
[ "$T" = "v0.11.0" ] || { echo "FATAL: router clone at '${T:-untagged}', not v0.11.0"; exit 1; }
echo "pre-flight: syntax ok, binary present, router clone at $T"
J="$(sbatch --parsable --export=ALL router_overhead.sbatch 2>&1)" || { echo "SUBMIT FAILED: $J"; exit 1; }
echo "SUBMITTED $J"; sleep 3
squeue -h -j "$J" -o '%.12i %.16j %.9T %.9M %R'
