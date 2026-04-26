#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────
# setup-cluster.sh — Bootstrap a Kind cluster for energy-aware EPP dev
#
# Creates a multi-node Kind cluster with heterogeneous hardware labels,
# deploys the EPP as a standalone pod, and optionally deploys simulated
# vLLM inference pods.
#
# Usage:
#   ./deploy/kind/setup-cluster.sh              # create cluster
#   ./deploy/kind/setup-cluster.sh --teardown   # destroy cluster
#   ./deploy/kind/setup-cluster.sh --demo       # create + run demo
# ─────────────────────────────────────────────────────────────────────
set -euo pipefail

CLUSTER_NAME="energy-epp-dev"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
KIND_CONFIG="$SCRIPT_DIR/kind-config.yaml"
EPP_IMAGE="energy-epp:dev"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[EPP]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERR]${NC} $*" >&2; }

# ─── Prerequisite Checks ────────────────────────────────────────────

check_deps() {
    local missing=()
    for cmd in kind kubectl docker; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing dependencies: ${missing[*]}"
        err "Install them first:"
        err "  kind:    go install sigs.k8s.io/kind@latest"
        err "  kubectl: https://kubernetes.io/docs/tasks/tools/"
        err "  docker:  https://docs.docker.com/get-docker/"
        exit 1
    fi
    log "All dependencies found"
}

# ─── Cluster Lifecycle ───────────────────────────────────────────────

create_cluster() {
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
        log "Cluster '${CLUSTER_NAME}' already exists"
        return 0
    fi

    log "Creating Kind cluster '${CLUSTER_NAME}'..."
    kind create cluster --config "$KIND_CONFIG" --name "$CLUSTER_NAME"

    # Wait for nodes to be ready
    log "Waiting for nodes..."
    kubectl wait --for=condition=Ready nodes --all --timeout=120s

    # Label worker nodes with hardware classes
    label_nodes

    log "Cluster created and configured!"
    kubectl get nodes -o wide
}

label_nodes() {
    log "Applying hardware class labels to worker nodes..."

    local workers
    workers=$(kubectl get nodes --no-headers -o custom-columns=":metadata.name" | grep worker || true)

    local idx=0
    for node in $workers; do
        case $idx in
            0)
                kubectl label node "$node" \
                    llm-d.ai/hardware-class=GPU_HIGH_PERF \
                    llm-d.ai/tdp-watts=700 \
                    llm-d.ai/role=prefill \
                    --overwrite 2>/dev/null
                log "  $node -> GPU_HIGH_PERF (700W, prefill)"
                ;;
            1)
                kubectl label node "$node" \
                    llm-d.ai/hardware-class=GPU_MED_PERF \
                    llm-d.ai/tdp-watts=200 \
                    llm-d.ai/role=decode \
                    --overwrite 2>/dev/null
                log "  $node -> GPU_MED_PERF (200W, decode)"
                ;;
            2)
                kubectl label node "$node" \
                    llm-d.ai/hardware-class=ASIC_LOW_POWER \
                    llm-d.ai/tdp-watts=75 \
                    llm-d.ai/role=decode \
                    --overwrite 2>/dev/null
                log "  $node -> ASIC_LOW_POWER (75W, decode)"
                ;;
        esac
        ((idx++))
    done
}

teardown_cluster() {
    log "Deleting Kind cluster '${CLUSTER_NAME}'..."
    kind delete cluster --name "$CLUSTER_NAME" 2>/dev/null || true
    log "Cluster deleted"
}

# ─── Build and Load EPP Image ───────────────────────────────────────

build_epp_image() {
    log "Building EPP Docker image '${EPP_IMAGE}'..."
    cd "$PROJECT_ROOT"
    docker build -t "$EPP_IMAGE" .
    log "Image built: $(docker image ls "$EPP_IMAGE" --format '{{.Size}}')"
}

load_image_to_kind() {
    log "Loading image into Kind cluster..."
    kind load docker-image "$EPP_IMAGE" --name "$CLUSTER_NAME"
    log "Image loaded into cluster"
}

# ─── Deploy EPP ──────────────────────────────────────────────────────

deploy_epp() {
    log "Deploying EPP to cluster..."

    kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: llm-inference
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: energy-epp
  namespace: llm-inference
  labels:
    app: energy-epp
    component: endpoint-picker
spec:
  replicas: 1
  selector:
    matchLabels:
      app: energy-epp
  template:
    metadata:
      labels:
        app: energy-epp
        component: endpoint-picker
    spec:
      containers:
        - name: energy-epp
          image: energy-epp:dev
          imagePullPolicy: Never
          args:
            - "--mode"
            - "sidecar"
            - "--health-port"
            - "8080"
            - "--region"
            - "US-CAL-CISO"
            - "--max-cluster-power"
            - "2000"
          ports:
            - containerPort: 8080
              name: health
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /readyz
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 5
          resources:
            requests:
              cpu: 100m
              memory: 64Mi
            limits:
              cpu: 500m
              memory: 128Mi
---
apiVersion: v1
kind: Service
metadata:
  name: energy-epp
  namespace: llm-inference
spec:
  selector:
    app: energy-epp
  ports:
    - name: health
      port: 8080
      targetPort: 8080
EOF

    log "Waiting for EPP to be ready..."
    kubectl -n llm-inference wait --for=condition=Available deployment/energy-epp --timeout=60s || {
        warn "EPP deployment not ready yet — check logs:"
        warn "  kubectl -n llm-inference logs deployment/energy-epp"
    }

    log "EPP deployed!"
    kubectl -n llm-inference get pods -o wide
}

# ─── Deploy Simulated Inference Pods ─────────────────────────────────

deploy_sim_pods() {
    log "Deploying simulated inference pods..."

    kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: vllm-sim-metrics
  namespace: llm-inference
data:
  # Simulated Prometheus metrics for different hardware types
  metrics-gpu-h100.txt: |
    # HELP DCGM_FI_DEV_POWER_USAGE Power draw (watts).
    # TYPE DCGM_FI_DEV_POWER_USAGE gauge
    DCGM_FI_DEV_POWER_USAGE{gpu="0"} 550
    # HELP DCGM_FI_DEV_GPU_UTIL GPU utilization (%).
    # TYPE DCGM_FI_DEV_GPU_UTIL gauge
    DCGM_FI_DEV_GPU_UTIL{gpu="0"} 78
    # HELP vllm:num_requests_running Current active requests.
    # TYPE vllm:num_requests_running gauge
    vllm:num_requests_running 5
    # HELP vllm:generation_tokens_total Cumulative tokens.
    # TYPE vllm:generation_tokens_total counter
    vllm:generation_tokens_total 500000
  metrics-asic-qc.txt: |
    # HELP DCGM_FI_DEV_POWER_USAGE Power draw (watts).
    # TYPE DCGM_FI_DEV_POWER_USAGE gauge
    DCGM_FI_DEV_POWER_USAGE{gpu="0"} 55
    # HELP DCGM_FI_DEV_GPU_UTIL GPU utilization (%).
    # TYPE DCGM_FI_DEV_GPU_UTIL gauge
    DCGM_FI_DEV_GPU_UTIL{gpu="0"} 65
    # HELP vllm:num_requests_running Current active requests.
    # TYPE vllm:num_requests_running gauge
    vllm:num_requests_running 3
    # HELP vllm:generation_tokens_total Cumulative tokens.
    # TYPE vllm:generation_tokens_total counter
    vllm:generation_tokens_total 300000
---
apiVersion: v1
kind: Pod
metadata:
  name: sim-gpu-h100
  namespace: llm-inference
  labels:
    app: vllm-sim
    llm-d.ai/hardware-class: GPU_HIGH_PERF
    llm-d.ai/tdp-watts: "700"
    llm-d.ai/role: prefill
spec:
  nodeSelector:
    llm-d.ai/hardware-class: GPU_HIGH_PERF
  containers:
    - name: metrics-server
      image: busybox:1.36
      command: ["/bin/sh", "-c"]
      args:
        - |
          while true; do
            echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n$(cat /metrics/metrics-gpu-h100.txt)" | nc -l -p 8000
          done
      ports:
        - containerPort: 8000
      volumeMounts:
        - name: metrics
          mountPath: /metrics
  volumes:
    - name: metrics
      configMap:
        name: vllm-sim-metrics
---
apiVersion: v1
kind: Pod
metadata:
  name: sim-asic-qc
  namespace: llm-inference
  labels:
    app: vllm-sim
    llm-d.ai/hardware-class: ASIC_LOW_POWER
    llm-d.ai/tdp-watts: "75"
    llm-d.ai/role: decode
spec:
  nodeSelector:
    llm-d.ai/hardware-class: ASIC_LOW_POWER
  containers:
    - name: metrics-server
      image: busybox:1.36
      command: ["/bin/sh", "-c"]
      args:
        - |
          while true; do
            echo -e "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\n$(cat /metrics/metrics-asic-qc.txt)" | nc -l -p 8000
          done
      ports:
        - containerPort: 8000
      volumeMounts:
        - name: metrics
          mountPath: /metrics
  volumes:
    - name: metrics
      configMap:
        name: vllm-sim-metrics
EOF

    log "Simulated pods deployed"
    kubectl -n llm-inference get pods -l app=vllm-sim -o wide
}

# ─── Status & Verification ──────────────────────────────────────────

check_status() {
    echo ""
    log "═══════════════════════════════════════════════════════"
    log "  CLUSTER STATUS"
    log "═══════════════════════════════════════════════════════"
    echo ""

    log "Nodes:"
    kubectl get nodes -L llm-d.ai/hardware-class,llm-d.ai/tdp-watts

    echo ""
    log "Pods:"
    kubectl -n llm-inference get pods -o wide 2>/dev/null || warn "No pods in llm-inference namespace"

    echo ""
    log "EPP Health:"
    kubectl -n llm-inference port-forward svc/energy-epp 8080:8080 &>/dev/null &
    PF_PID=$!
    sleep 2
    curl -s http://localhost:8080/healthz 2>/dev/null | python3 -m json.tool 2>/dev/null || warn "EPP not reachable yet"
    kill $PF_PID 2>/dev/null || true
}

# ─── Main ────────────────────────────────────────────────────────────

main() {
    case "${1:-}" in
        --teardown|-d)
            teardown_cluster
            ;;
        --demo)
            check_deps
            create_cluster
            build_epp_image
            load_image_to_kind
            deploy_epp
            deploy_sim_pods
            check_status
            ;;
        --status|-s)
            check_status
            ;;
        --help|-h)
            echo "Usage: $0 [--teardown|--demo|--status|--help]"
            echo ""
            echo "  (default)   Create Kind cluster only"
            echo "  --demo      Create cluster + build + deploy EPP + sim pods"
            echo "  --teardown  Delete the Kind cluster"
            echo "  --status    Show cluster and EPP status"
            ;;
        *)
            check_deps
            create_cluster
            ;;
    esac
}

main "$@"
