#!/usr/bin/env bash
set -u -o pipefail

# Read-only verification for the manually installed Rancher/Fleet lab.
failures=0

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }

check_command() {
  if command -v "$1" >/dev/null 2>&1; then pass "command: $1"; else fail "command: $1"; fi
}

check_command kubectl
check_command helm

if ! command -v kubectl >/dev/null 2>&1; then
  echo "Cannot continue without kubectl." >&2
  exit 1
fi

if kubectl cluster-info >/dev/null 2>&1 && kubectl get nodes >/dev/null 2>&1; then
  pass "K3s Kubernetes API and nodes"
else
  fail "K3s Kubernetes API and nodes"
fi

for namespace in cattle-system cert-manager cattle-fleet-system cattle-fleet-local-system; do
  if kubectl get namespace "$namespace" >/dev/null 2>&1; then
    pass "namespace: $namespace"
  else
    fail "namespace: $namespace"
  fi
done

if kubectl -n cattle-system get deployment rancher >/dev/null 2>&1 && \
   kubectl -n cattle-system rollout status deployment/rancher --timeout=5s >/dev/null 2>&1; then
  pass "Rancher deployment"
else
  fail "Rancher deployment"
fi

for crd in gitrepos.fleet.cattle.io bundles.fleet.cattle.io bundledeployments.fleet.cattle.io; do
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    pass "Fleet CRD: $crd"
  else
    fail "Fleet CRD: $crd"
  fi
done

if kubectl -n cattle-fleet-system get deployment fleet-controller >/dev/null 2>&1 && \
   kubectl -n cattle-fleet-system rollout status deployment/fleet-controller --timeout=5s >/dev/null 2>&1; then
  pass "Fleet controller"
else
  fail "Fleet controller"
fi

if kubectl -n cattle-fleet-local-system get deployment fleet-agent >/dev/null 2>&1 && \
   kubectl -n cattle-fleet-local-system rollout status deployment/fleet-agent --timeout=5s >/dev/null 2>&1; then
  pass "Fleet local-cluster agent"
else
  fail "Fleet local-cluster agent"
fi

if command -v helm >/dev/null 2>&1 && helm status rancher -n cattle-system >/dev/null 2>&1; then
  pass "Helm release: cattle-system/rancher"
else
  fail "Helm release: cattle-system/rancher"
fi

if command -v helm >/dev/null 2>&1 && helm status cert-manager -n cert-manager >/dev/null 2>&1; then
  pass "Helm release: cert-manager/cert-manager"
else
  fail "Helm release: cert-manager/cert-manager"
fi

echo
echo "Read-only inventory:"
kubectl get gitrepos.fleet.cattle.io -A 2>/dev/null || true
kubectl get pods -n cattle-fleet-system 2>/dev/null || true
kubectl get pods -n cattle-fleet-local-system 2>/dev/null || true

if (( failures > 0 )); then
  echo "Verification failed: $failures check(s) failed." >&2
  exit 1
fi

echo "Verification passed."
