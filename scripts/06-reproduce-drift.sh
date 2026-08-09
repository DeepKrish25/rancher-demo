#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

pause() { read -r -p "-- press enter to continue -- "; }

echo "### STEP A: confirm the app is synced via initdb (this is 'git state') ###"
kubectl get cluster.postgresql.cnpg.io demo-pg -n default -o jsonpath='{.spec.bootstrap}' ; echo
kubectl get pods -n default -l cnpg.io/cluster=demo-pg
pause

echo "### STEP B: pause the bundle -> disable auto-sync (mirrors 'pause app bundle') ###"
kubectl patch application demo-pg -n argocd --type merge \
  -p '{"spec":{"syncPolicy":null}}'
echo "Auto-sync disabled. ArgoCD will no longer self-heal this app."
pause

echo "### STEP C: delete the CNPG cluster (mirrors 'delete the postgres db') ###"
kubectl delete cluster.postgresql.cnpg.io demo-pg -n default
pause

echo "### STEP D: apply the manual recovery YAML (mirrors your current manual restore) ###"
kubectl apply -f "$ROOT/manual/manual-restore-cluster.yaml"
echo "Waiting for restored pod to go healthy..."
kubectl wait --for=condition=Ready pod -l cnpg.io/cluster=demo-pg -n default --timeout=180s
kubectl get cluster.postgresql.cnpg.io demo-pg -n default
pause

echo "### STEP E: unpause the bundle -> re-enable auto-sync (mirrors 'unpause app bundle') ###"
kubectl patch application demo-pg -n argocd --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true},"syncOptions":["CreateNamespace=true"]}}}'
echo ""
echo "### Now check the app status - it should show OutOfSync / Modified: ###"
sleep 5
kubectl get application demo-pg -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
echo ""
echo "Run this to see exactly what's drifting:"
echo "  kubectl get application demo-pg -n argocd -o jsonpath='{.status.resources}' | jq"
echo ""
echo "This is the bug. spec.bootstrap in git (initdb) != live object (recovery)."
