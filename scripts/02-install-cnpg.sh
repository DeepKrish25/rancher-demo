#!/usr/bin/env bash
set -euo pipefail

kubectl create namespace cnpg-system --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/main/releases/cnpg-1.24.0.yaml

echo "Waiting for CNPG operator to be ready..."
kubectl -n cnpg-system rollout status deployment/cnpg-controller-manager --timeout=180s
