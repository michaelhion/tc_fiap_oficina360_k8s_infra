#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"

: "${EKS_CLUSTER_NAME:?EKS_CLUSTER_NAME nao definida}"
: "${EKS_CLUSTER_ENDPOINT:?EKS_CLUSTER_ENDPOINT nao definida}"
: "${EKS_CLUSTER_CA:?EKS_CLUSTER_CA nao definida}"

KUBECONFIG_PATH="${KUBECONFIG:-${HOME}/.kube/config}"

mkdir -p "$(dirname "$KUBECONFIG_PATH")"

cat > "$KUBECONFIG_PATH" <<YAML
apiVersion: v1
kind: Config
clusters:
  - name: oficina360
    cluster:
      server: ${EKS_CLUSTER_ENDPOINT}
      certificate-authority-data: ${EKS_CLUSTER_CA}
contexts:
  - name: oficina360
    context:
      cluster: oficina360
      user: oficina360-aws
current-context: oficina360
users:
  - name: oficina360-aws
    user:
      exec:
        apiVersion: client.authentication.k8s.io/v1beta1
        command: aws
        args:
          - eks
          - get-token
          - --cluster-name
          - ${EKS_CLUSTER_NAME}
          - --region
          - ${AWS_REGION}
YAML

chmod 600 "$KUBECONFIG_PATH"

export KUBECONFIG="$KUBECONFIG_PATH"

echo "Contexto configurado: $(kubectl config current-context)"
kubectl get nodes -o wide
