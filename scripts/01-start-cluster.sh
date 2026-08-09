#!/usr/bin/env bash
set -euo pipefail

# Auto-detect available CPUs so this works on both a laptop and a
# smaller EC2 instance (e.g. t3.medium = 2 vCPU / 4GB).
AVAIL_CPUS=$(nproc)
USE_CPUS=$(( AVAIL_CPUS > 2 ? AVAIL_CPUS - 1 : AVAIL_CPUS ))

AVAIL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
USE_MEM_MB=$(( AVAIL_MEM_MB > 3000 ? AVAIL_MEM_MB - 1000 : AVAIL_MEM_MB * 70 / 100 ))

echo "Detected ${AVAIL_CPUS} CPUs / ${AVAIL_MEM_MB}MB RAM -> requesting ${USE_CPUS} CPUs / ${USE_MEM_MB}MB"

minikube start \
  --driver=docker \
  --cpus="${USE_CPUS}" \
  --memory="${USE_MEM_MB}mb" \
  --disk-size=20g

kubectl config use-context minikube
kubectl get nodes
