#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# setup-benchmark-cluster.sh — Bootstrap a real GPU cluster for
# energy-aware EPP benchmarking
#
# Modes:
#   multi-node  — Full heterogeneous cluster (2+ GPU nodes)
#   single-node — Power-cap emulation on a single GPU node
#
# Prerequisites:
#   - Linux (Ubuntu 22.04+ recommended)
#   - NVIDIA GPU with driver 535+ installed
#   - nvidia-smi accessible
#   - Root/sudo access
#
# Usage:
#   # Multi-node: run on control plane first, then workers
#   ./setup-benchmark-cluster.sh --mode multi-node --role control-plane
#   ./setup-benchmark-cluster.sh --mode multi-node --role worker \
#       --join-token <TOKEN> --control-plane-ip <IP> \
#       --hardware-class GPU_HIGH_PERF --tdp 700 --node-role prefill
#
#   # Single-node: everything on one machine
#   ./setup-benchmark-cluster.sh --mode single-node
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Defaults
MODE="single-node"
ROLE="control-plane"
JOIN_TOKEN=""
CONTROL_PLANE_IP=""
HARDWARE_CLASS="GPU_HIGH_PERF"
TDP_WATTS=250
NODE_ROLE="prefill"
SKIP_K3S=false
SKIP_GPU_OPERATOR=false
INSTALL_MONITORING=true
VLLM_MODEL="meta-llama/Llama-3.2-3B-Instruct"
HF_TOKEN=""

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()    { echo -e "${GREEN}[BENCH]${NC} $*"; }
info()   { echo -e "${BLUE}[INFO]${NC} $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()    { echo -e "${RED}[ERR]${NC} $*" >&2; }
header() { echo -e "\n${BLUE}═══════════════════════════════════════════════════════${NC}"; echo -e "${BLUE}  $*${NC}"; echo -e "${BLUE}═══════════════════════════════════════════════════════${NC}"; }

# ─── Parse Arguments ─────────────────────────────────────────────────

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)             MODE="$2"; shift 2 ;;
            --role)             ROLE="$2"; shift 2 ;;
            --join-token)       JOIN_TOKEN="$2"; shift 2 ;;
            --control-plane-ip) CONTROL_PLANE_IP="$2"; shift 2 ;;
            --hardware-class)   HARDWARE_CLASS="$2"; shift 2 ;;
            --tdp)              TDP_WATTS="$2"; shift 2 ;;
            --node-role)        NODE_ROLE="$2"; shift 2 ;;
            --skip-k3s)         SKIP_K3S=true; shift ;;
            --skip-gpu-operator) SKIP_GPU_OPERATOR=true; shift ;;
            --no-monitoring)    INSTALL_MONITORING=false; shift ;;
            --model)            VLLM_MODEL="$2"; shift 2 ;;
            --hf-token)         HF_TOKEN="$2"; shift 2 ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Modes:"
                echo "  --mode single-node    One GPU, power-cap emulation (default)"
                echo "  --mode multi-node     Multi-GPU heterogeneous cluster"
                echo ""
                echo "Multi-node options:"
                echo "  --role control-plane|worker    Node role"
                echo "  --join-token TOKEN             K3s join token (workers only)"
                echo "  --control-plane-ip IP          Control plane IP (workers only)"
                echo "  --hardware-class CLASS         GPU_HIGH_PERF|GPU_MED_PERF|ASIC_LOW_POWER"
                echo "  --tdp WATTS                    TDP watts label for this node"
                echo "  --node-role ROLE               prefill|decode"
                echo ""
                echo "Common options:"
                echo "  --model MODEL         HuggingFace model (default: Llama-3.2-3B-Instruct)"
                echo "  --hf-token TOKEN      HuggingFace token for gated models"
                echo "  --skip-k3s            Don't install k3s (already installed)"
                echo "  --skip-gpu-operator   Don't install GPU operator"
                echo "  --no-monitoring       Don't install Prometheus/Grafana"
                exit 0
                ;;
            *) err "Unknown option: $1"; exit 1 ;;
        esac
    done
}

# ─── Prerequisite Checks ────────────────────────────────────────────

check_prerequisites() {
    header "Checking Prerequisites"

    # Check for NVIDIA GPU
    if ! command -v nvidia-smi &>/dev/null; then
        err "nvidia-smi not found. Install NVIDIA drivers first."
        err "  Ubuntu: sudo apt install nvidia-driver-535"
        exit 1
    fi

    local gpu_info
    gpu_info=$(nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null || true)
    if [[ -z "$gpu_info" ]]; then
        err "No NVIDIA GPU detected."
        exit 1
    fi
    log "GPU detected: $gpu_info"

    # Check for Docker or containerd
    if command -v docker &>/dev/null; then
        log "Docker: $(docker --version 2>/dev/null | head -1)"
    else
        warn "Docker not found — k3s will use containerd (fine for benchmarks)"
    fi

    # Check nvidia-container-toolkit
    if command -v nvidia-container-runtime &>/dev/null || \
       dpkg -l 2>/dev/null | grep -q nvidia-container-toolkit; then
        log "NVIDIA Container Toolkit: installed"
    else
        warn "NVIDIA Container Toolkit not found — installing..."
        install_nvidia_container_toolkit
    fi
}

install_nvidia_container_toolkit() {
    distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L "https://nvidia.github.io/libnvidia-container/${distribution}/libnvidia-container.list" \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list
    sudo apt-get update
    sudo apt-get install -y nvidia-container-toolkit
    sudo nvidia-ctk runtime configure --runtime=containerd
    log "NVIDIA Container Toolkit installed"
}

# ─── K3s Installation ────────────────────────────────────────────────

install_k3s_control_plane() {
    header "Installing K3s (Control Plane)"

    if [[ "$SKIP_K3S" == "true" ]]; then
        log "Skipping k3s install (--skip-k3s)"
        return
    fi

    if command -v k3s &>/dev/null; then
        log "K3s already installed: $(k3s --version 2>/dev/null | head -1)"
        return
    fi

    curl -sfL https://get.k3s.io | sh -s - \
        --write-kubeconfig-mode 644 \
        --disable traefik \
        --kube-apiserver-arg="--allow-privileged=true"

    # Set up kubeconfig
    mkdir -p "$HOME/.kube"
    sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
    sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
    export KUBECONFIG="$HOME/.kube/config"

    # Wait for node
    log "Waiting for control plane to be ready..."
    kubectl wait --for=condition=Ready nodes --all --timeout=120s

    # Get join token for workers
    local token
    token=$(sudo cat /var/lib/rancher/k3s/server/node-token)
    local ip
    ip=$(hostname -I | awk '{print $1}')

    log "Control plane ready!"
    echo ""
    info "═══════════════════════════════════════════════════════"
    info "  JOIN COMMAND FOR WORKER NODES:"
    info "  $0 --mode multi-node --role worker \\"
    info "      --join-token $token \\"
    info "      --control-plane-ip $ip \\"
    info "      --hardware-class <CLASS> --tdp <WATTS> --node-role <ROLE>"
    info "═══════════════════════════════════════════════════════"
}

install_k3s_worker() {
    header "Installing K3s (Worker Node)"

    if [[ -z "$JOIN_TOKEN" || -z "$CONTROL_PLANE_IP" ]]; then
        err "Worker mode requires --join-token and --control-plane-ip"
        exit 1
    fi

    curl -sfL https://get.k3s.io | K3S_URL="https://${CONTROL_PLANE_IP}:6443" \
        K3S_TOKEN="$JOIN_TOKEN" sh -

    log "Worker node joined cluster at $CONTROL_PLANE_IP"
}

# ─── GPU Operator / DCGM ────────────────────────────────────────────

install_gpu_operator() {
    header "Installing GPU Operator + DCGM Exporter"

    if [[ "$SKIP_GPU_OPERATOR" == "true" ]]; then
        log "Skipping GPU operator (--skip-gpu-operator)"
        log "Installing standalone DCGM exporter + device plugin instead..."
        install_standalone_gpu_support
        return
    fi

    # Install Helm if needed
    if ! command -v helm &>/dev/null; then
        log "Installing Helm..."
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    fi

    helm repo add nvidia https://helm.ngc.nvidia.com/nvidia 2>/dev/null || true
    helm repo update

    # Install GPU Operator (handles driver, device plugin, DCGM)
    helm install gpu-operator nvidia/gpu-operator \
        --namespace gpu-operator --create-namespace \
        --set driver.enabled=false \
        --set dcgmExporter.enabled=true \
        --set toolkit.enabled=true \
        --wait --timeout 5m || {
            warn "GPU Operator install failed — falling back to standalone"
            install_standalone_gpu_support
        }

    log "GPU Operator installed with DCGM exporter"
}

install_standalone_gpu_support() {
    # Lightweight alternative: just device plugin + DCGM exporter
    kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml

    # Deploy DCGM exporter as DaemonSet
    kubectl apply -f - <<'DCGM_EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: dcgm-exporter
  namespace: monitoring
spec:
  selector:
    matchLabels:
      app: dcgm-exporter
  template:
    metadata:
      labels:
        app: dcgm-exporter
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "9400"
    spec:
      containers:
        - name: dcgm-exporter
          image: nvcr.io/nvidia/k8s/dcgm-exporter:3.3.8-3.6.1-ubuntu22.04
          ports:
            - containerPort: 9400
              name: metrics
          securityContext:
            privileged: true
          volumeMounts:
            - name: device-plugin
              mountPath: /var/lib/kubelet/device-plugins
      volumes:
        - name: device-plugin
          hostPath:
            path: /var/lib/kubelet/device-plugins
DCGM_EOF

    log "Standalone GPU device plugin + DCGM exporter installed"
}

# ─── Monitoring Stack ────────────────────────────────────────────────

install_monitoring() {
    header "Installing Prometheus + Grafana"

    if [[ "$INSTALL_MONITORING" != "true" ]]; then
        log "Skipping monitoring (--no-monitoring)"
        return
    fi

    kubectl create namespace monitoring 2>/dev/null || true

    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
    helm repo update

    helm install monitoring prometheus-community/kube-prometheus-stack \
        --namespace monitoring \
        --set grafana.adminPassword=energy-epp \
        --set grafana.service.type=NodePort \
        --set grafana.service.nodePort=30300 \
        --set prometheus.service.type=NodePort \
        --set prometheus.service.nodePort=30900 \
        --wait --timeout 5m

    # Import our Grafana dashboard
    if [[ -f "$PROJECT_ROOT/deploy/grafana/energy-epp-dashboard.json" ]]; then
        log "Importing Grafana dashboard..."
        kubectl -n monitoring create configmap energy-epp-dashboard \
            --from-file=energy-epp-dashboard.json="$PROJECT_ROOT/deploy/grafana/energy-epp-dashboard.json" \
            --dry-run=client -o yaml | kubectl apply -f -

        kubectl -n monitoring label configmap energy-epp-dashboard \
            grafana_dashboard=1 --overwrite
    fi

    local node_ip
    node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
    info "Grafana:    http://${node_ip}:30300 (admin / energy-epp)"
    info "Prometheus: http://${node_ip}:30900"
}

# ─── Node Labeling ───────────────────────────────────────────────────

label_current_node() {
    header "Labeling Node for Hardware Class"

    local node_name
    node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')

    kubectl label node "$node_name" \
        llm-d.ai/hardware-class="$HARDWARE_CLASS" \
        llm-d.ai/tdp-watts="$TDP_WATTS" \
        llm-d.ai/role="$NODE_ROLE" \
        --overwrite

    log "Node $node_name labeled: class=$HARDWARE_CLASS tdp=${TDP_WATTS}W role=$NODE_ROLE"
}

# ─── Deploy vLLM ─────────────────────────────────────────────────────

deploy_vllm() {
    header "Deploying vLLM Model Server"

    kubectl create namespace inference 2>/dev/null || true

    # Create HF token secret if provided
    if [[ -n "$HF_TOKEN" ]]; then
        kubectl -n inference create secret generic hf-token \
            --from-literal=token="$HF_TOKEN" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi

    kubectl apply -f - <<VLLM_EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vllm-server
  namespace: inference
  labels:
    app: vllm-server
    pool: heterogeneous
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vllm-server
  template:
    metadata:
      labels:
        app: vllm-server
        pool: heterogeneous
        llm-d.ai/role: ${NODE_ROLE}
        llm-d.ai/hardware-class: ${HARDWARE_CLASS}
        llm-d.ai/tdp-watts: "${TDP_WATTS}"
      annotations:
        prometheus.io/scrape: "true"
        prometheus.io/port: "8000"
        prometheus.io/path: "/metrics"
    spec:
      containers:
        - name: vllm
          image: vllm/vllm-openai:v0.8.0
          args:
            - "--model"
            - "${VLLM_MODEL}"
            - "--max-model-len"
            - "2048"
            - "--dtype"
            - "float16"
            - "--gpu-memory-utilization"
            - "0.85"
          ports:
            - containerPort: 8000
              name: http
          resources:
            limits:
              nvidia.com/gpu: 1
          env:
            - name: HUGGING_FACE_HUB_TOKEN
              valueFrom:
                secretKeyRef:
                  name: hf-token
                  key: token
                  optional: true
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 120
            periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: vllm-server
  namespace: inference
spec:
  selector:
    app: vllm-server
  ports:
    - name: http
      port: 8000
      targetPort: 8000
  type: NodePort
VLLM_EOF

    log "vLLM deployment created with model: $VLLM_MODEL"
    log "Waiting for vLLM pod to be ready (this may take 2-5 minutes for model download)..."
    kubectl -n inference wait --for=condition=Available deployment/vllm-server --timeout=600s || {
        warn "vLLM not ready yet. Check status with:"
        warn "  kubectl -n inference get pods"
        warn "  kubectl -n inference logs deployment/vllm-server"
    }
}

# ─── Deploy EPP ──────────────────────────────────────────────────────

build_and_deploy_epp() {
    header "Building & Deploying Energy-Aware EPP"

    cd "$PROJECT_ROOT"

    # Build for Linux
    log "Cross-compiling EPP for linux/amd64..."
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build \
        -ldflags="-s -w" -o bin/energy-epp-linux ./cmd/energy-epp/
    log "Binary built: $(ls -lh bin/energy-epp-linux | awk '{print $5}')"

    # Build container image
    log "Building container image..."
    docker build -t energy-epp:bench .

    # If k3s, import directly
    if command -v k3s &>/dev/null; then
        log "Importing image into k3s..."
        docker save energy-epp:bench | sudo k3s ctr images import -
    fi

    # Deploy
    kubectl create namespace energy-epp 2>/dev/null || true
    kubectl apply -f "$PROJECT_ROOT/deploy/manifests/energy-epp-deployment.yaml"

    log "Waiting for EPP pods..."
    kubectl -n energy-epp wait --for=condition=Available \
        deployment/epp-gpu-h100 deployment/epp-gpu-a100 deployment/epp-asic-qc100 \
        --timeout=120s 2>/dev/null || {
            warn "Some EPP pods not ready — this is normal for single-node"
            kubectl -n energy-epp get pods
        }
}

# ─── Single-Node Setup ──────────────────────────────────────────────

setup_single_node() {
    header "Single-Node Power-Cap Emulation Setup"

    check_prerequisites
    install_k3s_control_plane

    # Get current GPU TDP
    local max_tdp
    max_tdp=$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits 2>/dev/null | head -1 | xargs)
    log "GPU max TDP: ${max_tdp}W"

    # Label this node as high-perf (we'll change power caps per-experiment)
    HARDWARE_CLASS="GPU_HIGH_PERF"
    TDP_WATTS="${max_tdp%.*}"
    NODE_ROLE="prefill"
    label_current_node

    install_gpu_operator
    install_monitoring
    deploy_vllm
    build_and_deploy_epp

    print_single_node_summary
}

print_single_node_summary() {
    local node_ip
    node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || hostname -I | awk '{print $1}')
    local max_tdp
    max_tdp=$(nvidia-smi --query-gpu=power.max_limit --format=csv,noheader,nounits 2>/dev/null | head -1 | xargs)

    header "SETUP COMPLETE — Single-Node Power-Cap Mode"

    echo ""
    log "Services:"
    log "  vLLM:       http://${node_ip}:$(kubectl -n inference get svc vllm-server -o jsonpath='{.spec.ports[0].nodePort}' 2>/dev/null || echo '?')"
    log "  Grafana:    http://${node_ip}:30300"
    log "  Prometheus: http://${node_ip}:30900"
    echo ""
    log "GPU Max TDP: ${max_tdp}W"
    echo ""
    log "Next steps — Run the benchmark:"
    log "  cd $PROJECT_ROOT"
    log "  bash benchmarks/scripts/run-cluster-benchmark.sh"
    echo ""
    log "Or run individual power-cap experiments:"
    log "  sudo nvidia-smi -pl 250    # Full power (prefill test)"
    log "  sudo nvidia-smi -pl 150    # Mid power (decode test)"
    log "  sudo nvidia-smi -pl 100    # Low power (ASIC emulation)"
}

# ─── Multi-Node Setup ───────────────────────────────────────────────

setup_multi_node() {
    check_prerequisites

    case "$ROLE" in
        control-plane)
            install_k3s_control_plane
            install_gpu_operator
            install_monitoring
            label_current_node
            build_and_deploy_epp

            header "Control Plane Ready"
            log "Now run the worker join command on each GPU node."
            ;;
        worker)
            install_k3s_worker
            log "Worker joined. Labels will be applied from control plane."
            ;;
        *)
            err "Unknown role: $ROLE (use control-plane or worker)"
            exit 1
            ;;
    esac
}

# ─── Main ────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    header "Energy-Aware EPP — Benchmark Cluster Setup"
    log "Mode: $MODE"
    log "Project: $PROJECT_ROOT"

    case "$MODE" in
        single-node)
            setup_single_node
            ;;
        multi-node)
            setup_multi_node
            ;;
        *)
            err "Unknown mode: $MODE (use single-node or multi-node)"
            exit 1
            ;;
    esac
}

main "$@"
