#!/usr/bin/env bash
set -euo pipefail

kubectl create namespace minio --dry-run=client -o yaml | kubectl apply -f -

helm repo add minio https://charts.min.io/ >/dev/null 2>&1 || true
helm repo update

helm upgrade --install minio minio/minio -n minio \
  --set mode=standalone \
  --set replicas=1 \
  --set resources.requests.memory=256Mi \
  --set resources.requests.cpu=100m \
  --set persistence.size=2Gi \
  --set rootUser=minioadmin \
  --set rootPassword=minioadmin123

echo "Waiting for MinIO to be ready..."
kubectl -n minio rollout status statefulset/minio --timeout=180s

echo "Creating pg-backups bucket..."
kubectl apply -f "$(dirname "$0")/../manual/minio-bucket-job.yaml"
kubectl -n minio wait --for=condition=complete job/create-pg-backups-bucket --timeout=120s
