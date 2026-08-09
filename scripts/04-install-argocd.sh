#!/usr/bin/env bash
set -euo pipefail

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Trimming components we don't need for this demo (saves ~500Mi-1Gi RAM)..."
kubectl -n argocd delete deployment argocd-dex-server argocd-notifications-controller \
  argocd-applicationset-controller --ignore-not-found

echo "Waiting for argocd-server and repo-server..."
kubectl -n argocd rollout status deployment/argocd-server --timeout=180s
kubectl -n argocd rollout status deployment/argocd-repo-server --timeout=180s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=180s

echo ""
echo "Initial admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d
echo ""
echo ""
echo "To open the UI: kubectl -n argocd port-forward svc/argocd-server 8080:443"
echo "Then browse https://localhost:8080 (user: admin)"
