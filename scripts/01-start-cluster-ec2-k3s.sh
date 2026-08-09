#!/usr/bin/env bash
set -euo pipefail

# For EC2 instances specifically: skip minikube. EC2 is already a VM,
# so minikube's docker-driver (which runs a second nested environment)
# just burns RAM/CPU you don't have on a t3.medium (2 vCPU / 4GB).
# k3s installs directly on the host and is dramatically lighter.

curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644

# Make kubectl work without sudo, using k3s's built-in kubectl
mkdir -p "$HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found - installing..."
  curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
fi

if ! command -v helm >/dev/null 2>&1; then
  echo "helm not found - installing..."
  curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo ""
kubectl get nodes
echo ""
echo "k3s is up. Continue with scripts/02-install-cnpg.sh as normal"
echo "(skip 01-start-cluster.sh, you don't need minikube on EC2)."
