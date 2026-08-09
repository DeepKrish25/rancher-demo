#!/usr/bin/env bash
set -euo pipefail

# Tuned for an 8GB RAM / 4-core laptop. Close browsers/IDEs before running.
# If this OOMs or is too slow, fall back to an EC2 t3.large (see README).
minikube start \
  --driver=docker \
  --cpus=4 \
  --memory=4500mb \
  --disk-size=20g

kubectl config use-context minikube
kubectl get nodes
