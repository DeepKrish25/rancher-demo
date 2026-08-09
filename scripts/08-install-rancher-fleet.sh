#!/usr/bin/env bash
set -euo pipefail

# Run this script manually on the EC2 K3s host.
#
# It deliberately does not:
#   - configure a Fleet GitRepo
#   - touch the existing ArgoCD demo-pg application
#   - modify CNPG resources
#   - modify MinIO
#
# Expected lab environment:
#   K3s:    v1.35.6+k3s1
#   Rancher: 2.14.3
#
# Example:
#
#   export RANCHER_HOSTNAME=203.0.113.10.sslip.io
#   read -r -s -p 'Rancher bootstrap password: ' RANCHER_BOOTSTRAP_PASSWORD
#   echo
#   export RANCHER_BOOTSTRAP_PASSWORD
#
#   ./scripts/08-install-rancher-fleet.sh

readonly CERT_MANAGER_NAMESPACE="cert-manager"
readonly RANCHER_NAMESPACE="cattle-system"
readonly RANCHER_RELEASE="rancher"
readonly RANCHER_VERSION="${RANCHER_VERSION:-2.14.3}"

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

: "${RANCHER_HOSTNAME:?Set RANCHER_HOSTNAME (for example: 203.0.113.10.sslip.io)}"
: "${RANCHER_BOOTSTRAP_PASSWORD:?Set RANCHER_BOOTSTRAP_PASSWORD before running this script}"

if [[ "$RANCHER_HOSTNAME" == *://* || "$RANCHER_HOSTNAME" == */* ]]; then
  echo "ERROR: RANCHER_HOSTNAME must be a DNS hostname only (no scheme or path)." >&2
  exit 1
fi

if ! kubectl get ingressclass traefik >/dev/null 2>&1; then
  echo "ERROR: K3s Traefik IngressClass was not found."
  echo "Install/configure an ingress controller before installing Rancher." >&2
  exit 1
fi

echo "Checking Kubernetes version..."
kubectl get nodes -o wide

echo ""
echo "Installing Rancher version: ${RANCHER_VERSION}"
echo ""

echo "Adding Helm repositories..."
helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
helm repo add rancher-latest https://releases.rancher.com/server-charts/latest >/dev/null 2>&1 || true
helm repo update

echo ""
echo "Installing or upgrading cert-manager..."

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace "$CERT_MANAGER_NAMESPACE" \
  --create-namespace \
  --set crds.enabled=true \
  --wait \
  --timeout 10m

echo ""
echo "Installing or upgrading Rancher ${RANCHER_VERSION}..."
echo "Hostname: ${RANCHER_HOSTNAME}"

helm upgrade --install "$RANCHER_RELEASE" rancher-latest/rancher \
  --version "$RANCHER_VERSION" \
  --namespace "$RANCHER_NAMESPACE" \
  --create-namespace \
  --set "hostname=$RANCHER_HOSTNAME" \
  --set "bootstrapPassword=$RANCHER_BOOTSTRAP_PASSWORD" \
  --set replicas=1 \
  --set ingress.ingressClassName=traefik \
  --wait \
  --timeout 15m

echo ""
echo "Waiting for Rancher deployment..."
kubectl -n "$RANCHER_NAMESPACE" \
  rollout status deployment/rancher \
  --timeout=10m

echo ""
echo "Waiting for Fleet GitRepo CRD..."

for i in $(seq 1 120); do
  if kubectl get crd gitrepos.fleet.cattle.io >/dev/null 2>&1; then
    echo "Fleet GitRepo CRD found."
    break
  fi

  if [[ "$i" -eq 120 ]]; then
    echo "ERROR: Fleet GitRepo CRD was not created within 10 minutes." >&2
    echo ""
    echo "Rancher pods:"
    kubectl get pods -n "$RANCHER_NAMESPACE" || true
    echo ""
    echo "Fleet-related CRDs:"
    kubectl get crd | grep 'fleet.cattle.io' || true
    exit 1
  fi

  sleep 5
done

echo ""
echo "Waiting for Fleet GitRepo CRD to become Established..."

kubectl wait \
  --for=condition=Established \
  crd/gitrepos.fleet.cattle.io \
  --timeout=10m

echo ""
echo "Waiting for Fleet controller..."

kubectl -n cattle-fleet-system \
  wait \
  --for=condition=Available \
  deployment/fleet-controller \
  --timeout=10m

echo ""
echo "Waiting for Fleet local agent..."

kubectl -n cattle-fleet-local-system \
  wait \
  --for=condition=Available \
  deployment/fleet-agent \
  --timeout=10m

echo ""
echo "=============================================="
echo " Rancher and Fleet are ready"
echo "=============================================="
echo ""
echo "Rancher version: ${RANCHER_VERSION}"
echo "Rancher URL:     https://${RANCHER_HOSTNAME}"
echo "Login user:      admin"
echo ""
echo "Useful verification commands:"
echo ""
echo "kubectl get pods -n ${RANCHER_NAMESPACE}"
echo "kubectl get pods -n cattle-fleet-system"
echo "kubectl get pods -n cattle-fleet-local-system"
echo "kubectl get crd | grep 'fleet.cattle.io'"
echo "helm list -A"
echo "./scripts/09-verify-rancher-fleet.sh"
echo ""
echo "Next:"
echo "Apply fleet/gitrepo-fleet-demo-pg.yaml manually after"
echo "confirming Rancher and Fleet are healthy."
echo ""
echo "The GitRepo is restricted to fleet/fleet-demo-pg"
echo "and must not manage the existing ArgoCD demo-pg Cluster."
echo ""