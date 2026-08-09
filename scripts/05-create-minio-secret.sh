#!/usr/bin/env bash
set -euo pipefail

# Credentials are NOT committed to git (matches real-world practice —
# your GCP service account key wouldn't be in git either).
kubectl create secret generic minio-creds -n default \
  --from-literal=ACCESS_KEY_ID=minioadmin \
  --from-literal=ACCESS_SECRET_KEY=minioadmin123 \
  --dry-run=client -o yaml | kubectl apply -f -
