# ─── Build Stage ───────────────────────────────────────────────────
FROM golang:1.25-alpine AS builder

WORKDIR /app

# Cache dependencies (no external deps — pure stdlib)
COPY go.mod ./
RUN go mod download

# Build binary
COPY . .
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w" -o /energy-epp ./cmd/energy-epp/

# ─── Runtime Stage ─────────────────────────────────────────────────
FROM gcr.io/distroless/static-debian12:nonroot

LABEL org.opencontainers.image.title="energy-aware-epp"
LABEL org.opencontainers.image.description="Energy-Aware Endpoint Picker Plugin for llm-d"
LABEL org.opencontainers.image.source="https://github.com/johnnie/energy-aware-epp"

COPY --from=builder /energy-epp /energy-epp

# Health check port
EXPOSE 8080

# Default to sidecar mode in K8s
ENTRYPOINT ["/energy-epp"]
CMD ["--mode", "sidecar", "--health-port", "8080"]
