#!/bin/bash
#SBATCH --job-name=lib-probe
#SBATCH --time=00:05:00
#SBATCH --cpus-per-task=2
#SBATCH --mem=8G
#SBATCH --gres=gpu:1
#SBATCH --output=%x-%j.out

# Three-minute job whose only purpose is to answer one question that cannot be
# answered from the login node: does the vLLM container image contain httpx?
#
# The login node refuses to start containers ("maximum number of user
# namespaces exceeded"), so the CVMFS python there is the only interpreter
# reachable interactively - and it is NOT the interpreter the harness runs
# under. Guessing would be exactly the kind of unverified package claim that
# wastes a 20-minute 8-GPU job.
set -u
# Deliberately no "source .../profile/bash.sh" fallback. That profile execs a
# replacement login shell; in a batch script the replacement has nothing left
# to run and exits 1 immediately, producing a zero-byte log. Job 12303347 died
# exactly that way. Jobs submitted with --export=ALL never notice, because
# "module" is already defined in the inherited environment - which is why
# stage2_real.sbatch gets away with the same block. Absolute path instead.
module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null || true
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"
ROOT="$HOME/energy-epp"
IMG="$ROOT/images/vllm-v0.30.0.sif"

echo "node: $(hostname)"
echo "apptainer: $APPTAINER"
echo
echo "=== python libraries inside the container ==="
env -u SSL_CERT_FILE "$APPTAINER" exec "$IMG" python3 - <<'PY'
import sys
print(" python", sys.version.split()[0])
missing = []
for m in ("httpx", "pynvml", "aiohttp", "h11", "httpcore", "anyio", "openai"):
    try:
        mod = __import__(m)
        print("  %-9s %s" % (m, getattr(mod, "__version__", "present")))
    except ImportError:
        print("  %-9s ABSENT" % m)
        missing.append(m)

# httpx is the one that decides whether the rewritten harness can run at all.
if "httpx" in missing:
    print("\nHTTPX ABSENT - the harness cannot run in this image.")
    print("Options, in order of preference:")
    print("  1. pip install --user httpx into a venv bound into the container")
    print("  2. hand-roll HTTP/1.1 + chunked SSE on asyncio.open_connection")
    print("  3. shard the generator across processes to lift the 32 ceiling")
    sys.exit(1)

# Prove async streaming actually works here, not just that the import resolves.
import asyncio, httpx


async def _check():
    limits = httpx.Limits(max_connections=256, max_keepalive_connections=256)
    async with httpx.AsyncClient(limits=limits) as c:
        # No server to talk to in this job; a refused connection still proves
        # the async transport is wired up, whereas an AttributeError would not.
        try:
            async with c.stream("GET", "http://127.0.0.1:1/", timeout=2):
                pass
        except httpx.HTTPError as e:
            print("\nasync stream path reached the transport:", type(e).__name__)
            return True
    return True


print("\nasync streaming usable:", asyncio.run(_check()))
PY
rc=$?
echo
echo "exit $rc"
exit $rc
