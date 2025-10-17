#!/usr/bin/env bash
set -euo pipefail
# Wait for all pods to be ready in monitoring and default namespaces (timeout 4m)
kubectl wait --for=condition=Ready pods --all --namespace monitoring --timeout=240s || true
kubectl wait --for=condition=Ready pods --all --namespace default --timeout=240s || true
