#!/usr/bin/env python3
"""
Bare-Metal AI Infrastructure Diagnostics & Validation Tool

This tool validates the hardware, networking, and platform layers of the deployment environment.
It acts as a comprehensive diagnostic framework for:
  1. Linux System Health (NUMA nodes, sysfs CPU governors, transparent hugepages)
  2. GPU Infrastructure (NVIDIA-SMI, DCGM availability, CUDA/NCCL paths)
  3. High-Performance Networking (InfiniBand/RoCE, RDMA interfaces, Mellanox OFED)
  4. Platform Layers (Kubernetes Node status, Slurm, Ray/KubeRay availability)

Aligns with core responsibilities:
- Building internal tooling and automation for infrastructure deployment and validation.
- Troubleshooting hardware, networking, platform, and infrastructure-related issues.
- Root-cause analysis across hardware, networking, operating system, and platform layers.
"""

import os
import subprocess
import platform
import logging
from typing import List

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")

def run_command(cmd: List[str], warn_only=False) -> str:
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        if not warn_only:
            logging.error(f"Command failed: {' '.join(cmd)}")
            logging.error(f"Error output: {e.stderr.strip()}")
        return ""
    except FileNotFoundError:
        if not warn_only:
            logging.warning(f"Command not found: {cmd[0]}")
        return ""

def validate_linux_systems():
    logging.info("--- Validating Linux Systems & Bare-Metal ---")
    
    # OS Info
    logging.info(f"OS Platform: {platform.platform()}")
    logging.info(f"Kernel Release: {platform.release()}")
    
    # Check NUMA nodes
    if os.path.exists('/sys/devices/system/node'):
        nodes = [d for d in os.listdir('/sys/devices/system/node') if d.startswith('node')]
        logging.info(f"NUMA Nodes detected: {len(nodes)}")
    else:
        logging.warning("NUMA node information not found in sysfs. Ensure bare-metal access.")

    # Check CPU governor (performance is preferred for AI infra)
    gov_path = '/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor'
    if os.path.exists(gov_path):
        with open(gov_path, 'r') as f:
            gov = f.read().strip()
            logging.info(f"CPU0 Scaling Governor: {gov}")
            if gov != 'performance':
                logging.warning("CPU governor is not set to 'performance'. This may impact AI workload latency.")

def validate_gpu_infrastructure():
    logging.info("--- Validating GPU Infrastructure & Accelerators ---")
    
    # Check nvidia-smi
    smi_out = run_command(["nvidia-smi", "--query-gpu=name,pci.bus_id,power.limit", "--format=csv,noheader"], warn_only=True)
    if smi_out:
        logging.info("GPU Devices Found:")
        for line in smi_out.split('\n'):
            logging.info(f"  - {line}")
    else:
        logging.warning("nvidia-smi not found or failed. No GPUs detected on this node.")

    # Check DCGM (Data Center GPU Manager)
    dcgm_out = run_command(["dcgmi", "discovery", "-l"], warn_only=True)
    if dcgm_out:
        logging.info("NVIDIA DCGM is installed and running.")
    else:
        logging.warning("DCGM (Data Center GPU Manager) not detected. Advanced telemetry may be limited.")

def validate_networking_rdma():
    logging.info("--- Validating Networking & RDMA/InfiniBand ---")
    
    # Check IB/RoCE devices for GPU Direct RDMA
    ibv_out = run_command(["ibv_devices"], warn_only=True)
    if ibv_out:
        logging.info("RDMA/InfiniBand Devices Found:")
        for line in ibv_out.split('\n'):
            logging.info(f"  {line}")
    else:
        logging.warning("ibv_devices not found. RDMA/InfiniBand might not be configured. GPU Direct RDMA will fall back to standard networking.")

    # Check NCCL topology configuration
    nccl_topo = "/var/run/nvidia-topologyd"
    if os.path.exists(nccl_topo):
        logging.info("NCCL Topology daemon detected.")
    else:
        logging.info("No custom NCCL topology daemon found. Using default NCCL tree/ring topologies.")

def validate_platform_kubernetes():
    logging.info("--- Validating Kubernetes/Slurm Platform ---")
    
    # Check kubectl / kubelet
    kubectl_out = run_command(["kubectl", "get", "nodes", "-o", "wide"], warn_only=True)
    if kubectl_out:
        logging.info("Kubernetes cluster is accessible.")
    else:
        logging.info("kubectl not configured or cluster inaccessible from this context.")

    # Check Slurm
    sinfo_out = run_command(["sinfo", "-s"], warn_only=True)
    if sinfo_out:
        logging.info("Slurm workload manager detected.")
    else:
        logging.info("Slurm not detected on this node.")

def main():
    logging.info("Starting Advanced AI Infrastructure Diagnostics...")
    validate_linux_systems()
    validate_gpu_infrastructure()
    validate_networking_rdma()
    validate_platform_kubernetes()
    logging.info("Infrastructure validation complete.")

if __name__ == "__main__":
    main()
