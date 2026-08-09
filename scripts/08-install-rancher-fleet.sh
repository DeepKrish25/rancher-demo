#!/usr/bin/env bash
set -euo pipefail

# Run this script manually on the EC2 K3s host. It deliberately does not
# configure a Fleet GitRepo or touch the existing ArgoCD demo-pg application.
#
# Example for an EC2 public IPv4 address 203.0.113.10:
#   export RANCHER_HOSTNAME=203.0.113.10.sslip.io
#   read -r -s -p 'Rancher bootstrap password: ' RANCHER_BOOTSTRAP_PASSWORD; echo
#   export RANCHER_BOOTSTRAP_PASSWORD
#   ./scripts/08-install-rancher-fleet.sh

readonly CERT_MANAGER_NAMESPACE="cert-manager"
readonly RANCHER_NAMESPACE="cattle-system"
readonly RANCHER_RELEASE="rancher"

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

require_command kubectl
require_command helm

kubectl cluster-info >/dev/null
kubectl get nodes >/dev/null
helm version --short >/dev/null

: "${RANCHER_HOSTNAME:?Set RANCHER_HOSTNAME (for example: <EC2-public-IP>.sslip.io)}"
: "${RANCHER_BOOTSTRAP_PASSWORD:?Set RANCHER_BOOTSTRAP_PASSWORD before running this script}"

if [[ "$RANCHER_HOSTNAME" == *://* || "$RANCHER_HOSTNAME" == */* ]]; then
  echo "ERROR: RANCHER_HOSTNAME must be a DNS hostname only (no scheme or path)." >&2
  exit 1
fi

if ! kubectl get ingressclass traefik >/dev/null 2>&1; then
  echo "ERROR: K3s Traefik IngressClass was not found. Install/configure an ingress controller first." >&2
  exit 1
fi

echo "Adding Helm repositories..."
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest >/dev/null 2>&1 || true
helm repo update

echo "Installing or upgrading cert-manager..."
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace "$CERT_MANAGER_NAMESPACE" \
  --create-namespace \
  --set crds.enabled=true \
  --wait \
  --timeout 10m

echo "Installing or upgrading Rancher (single replica lab configuration)..."
helm upgrade --install "$RANCHER_RELEASE" rancher-latest/rancher \
  --namespace "$RANCHER_NAMESPACE" \
  --create-namespace \
  --set "hostname=$RANCHER_HOSTNAME" \
  --set "bootstrapPassword=$RANCHER_BOOTSTRAP_PASSWORD" \
  --set replicas=1 \
  --set ingress.ingressClassName=traefik \
  --wait \
  --timeout 15m

echo "Waiting for Rancher and Fleet components..."
kubectl -n "$RANCHER_NAMESPACE" rollout status deployment/rancher --timeout=10m
kubectl wait --for=condition=Established crd/gitrepos.fleet.cattle.io --timeout=10m
kubectl -n cattle-fleet-system wait --for=condition=Available deployment/fleet-controller --timeout=10m
kubectl -n cattle-fleet-local-system wait --for=condition=Available deployment/fleet-agent --timeout=10m

cat <<EOF

Rancher and its bundled Fleet components are ready.

Rancher URL: https://${RANCHER_HOSTNAME}
Login user: admin

Useful verification commands:
  kubectl get pods -n ${RANCHER_NAMESPACE}
  kubectl get pods -n cattle-fleet-system
  kubectl get pods -n cattle-fleet-local-system
  kubectl get crd | grep 'fleet.cattle.io'
  helm list -A
  ./scripts/09-verify-rancher-fleet.sh

Next, apply fleet/gitrepo-fleet-demo-pg.yaml manually after committing and
pushing this repository. That GitRepo is restricted to fleet/fleet-demo-pg
and cannot manage the existing ArgoCD demo-pg Cluster.
EOF
