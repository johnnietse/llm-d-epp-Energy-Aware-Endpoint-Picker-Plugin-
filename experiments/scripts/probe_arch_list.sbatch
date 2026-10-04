#!/bin/bash
#SBATCH --job-name=arch-probe
#SBATCH --account=def-hpcg1971_gpu
#SBATCH --time=00:05:00
#SBATCH --mem=0
#SBATCH --gres=gpu:rtx6000:1
#SBATCH --output=%x-%j.out

# Which GPU architectures can the container's torch actually target?
#
# The V100 curve sweep (job 12304130) died with
#   torch.AcceleratorError: CUDA error: no kernel image is available for
#   execution on the device   (cudaErrorNoKernelImageForDevice)
# on a Tesla V100-PCIE-32GB, compute capability 7.0. The plausible explanation
# is that CUDA 13 dropped Volta, so torch 2.13.0+cu130 ships no sm_70 kernels.
#
# Rather than assert that from memory, ask the build: get_arch_list() is a
# property of how torch was compiled and needs no GPU of that architecture to
# query. Whatever it returns is the authoritative answer for OUR stack, which
# is what matters - a general claim about CUDA 13 would not tell us what this
# specific image contains.
set -uo pipefail
module load apptainer/1.4.5 2>/dev/null || module load apptainer 2>/dev/null || true
APPTAINER="$(command -v apptainer \
  || echo /cvmfs/soft.computecanada.ca/easybuild/software/2023/x86-64-v3/Core/apptainer/1.4.5/bin/apptainer)"
ROOT="$HOME/energy-epp"

echo "node=$(hostname)"
env -u SSL_CERT_FILE "$APPTAINER" exec --nv "$ROOT/images/vllm-v0.30.0.sif" python3 - <<'PY'
import torch
print("torch           :", torch.__version__)
print("cuda runtime    :", torch.version.cuda)
print("compiled arches :", torch.cuda.get_arch_list())
caps = {"V100": (7, 0), "RTX 6000 / RTX 8000": (7, 5), "A100 / A30": (8, 0),
        "L4 / L40S": (8, 9)}
print()
for name, (maj, minor) in sorted(caps.items(), key=lambda kv: kv[1]):
    tag = "sm_%d%d" % (maj, minor)
    ok = any(a.startswith(tag) for a in torch.cuda.get_arch_list())
    print("  %-22s cc %d.%-2d  %-7s %s"
          % (name, maj, minor, tag, "PRESENT" if ok else "ABSENT"))
PY
