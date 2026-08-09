#!/usr/bin/env bash
set -euo pipefail

cat <<'EOF'
### THE FIX ###

1. In argocd/application.yaml, uncomment the ignoreDifferences block:

     ignoreDifferences:
       - group: postgresql.cnpg.io
         kind: Cluster
         jsonPointers:
           - /spec/bootstrap

2. Commit + push that change to your git repo.

3. Then run:
     kubectl apply -f argocd/application.yaml

This script re-applies the Application manifest from disk (make sure
you've edited and saved argocd/application.yaml first) and then
verifies drift is resolved.
EOF

read -r -p "-- press enter once you've edited and saved argocd/application.yaml -- "

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
kubectl apply -f "$ROOT/argocd/application.yaml"

echo "Forcing a refresh..."
kubectl -n argocd annotate application demo-pg argocd.argoproj.io/refresh=hard --overwrite

sleep 8
echo ""
echo "Sync + Health status (expect: Synced / Healthy):"
kubectl get application demo-pg -n argocd -o jsonpath='{.status.sync.status}{"\n"}{.status.health.status}{"\n"}'
echo ""
echo "Confirm it stays Synced even though live spec.bootstrap differs from git:"
kubectl get cluster.postgresql.cnpg.io demo-pg -n default -o jsonpath='{.spec.bootstrap}'
echo ""
echo "(git still says initdb in values.yaml — that's fine now, it's ignored.)"
