#!/usr/bin/env bash

set -euo pipefail

kubectl get nodes
kubectl get pods -A
kubectl rollout status deployment/oficina360-api -n oficina360 --timeout=300s
