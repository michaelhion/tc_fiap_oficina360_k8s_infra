#!/usr/bin/env bash
set -euo pipefail

AWS_REGION="${AWS_REGION:-us-east-1}"

CLUSTER_NAME="$(
  aws ssm get-parameter \
    --name "/oficina360/cluster/name" \
    --region "$AWS_REGION" \
    --query "Parameter.Value" \
    --output text
)"

CLUSTER_ENDPOINT="$(
  aws ssm get-parameter \
    --name "/oficina360/cluster/endpoint" \
    --region "$AWS_REGION" \
    --query "Parameter.Value" \
    --output text
)"

CLUSTER_CA="$(
  aws ssm get-parameter \
    --name "/oficina360/cluster/certificate-authority" \
    --region "$AWS_REGION" \
    --query "Parameter.Value" \
    --output text
)"

if [[ -z "$CLUSTER_NAME" || "$CLUSTER_NAME" == "None" ]]; then
  echo "::error::Nome do cluster não encontrado no Parameter Store."
  exit 1
fi

if [[ -z "$CLUSTER_ENDPOINT" || "$CLUSTER_ENDPOINT" == "None" ]]; then
  echo "::error::Endpoint do cluster não encontrado no Parameter Store."
  exit 1
fi

if [[ -z "$CLUSTER_CA" || "$CLUSTER_CA" == "None" ]]; then
  echo "::error::CA do cluster não encontrada no Parameter Store."
  exit 1
fi

mkdir -p "$HOME/.kube"

printf '%s' "$CLUSTER_CA" |
  base64 --decode \
  > /tmp/oficina360-ca.crt

kubectl config set-cluster "$CLUSTER_NAME" \
  --server="$CLUSTER_ENDPOINT" \
  --certificate-authority=/tmp/oficina360-ca.crt \
  --embed-certs=true

kubectl config set-credentials oficina360-aws \
  --exec-command=aws \
  --exec-api-version=client.authentication.k8s.io/v1beta1 \
  --exec-arg=eks \
  --exec-arg=get-token \
  --exec-arg=--cluster-name \
  --exec-arg="$CLUSTER_NAME" \
  --exec-arg=--region \
  --exec-arg="$AWS_REGION"

kubectl config set-context oficina360 \
  --cluster="$CLUSTER_NAME" \
  --user=oficina360-aws

kubectl config use-context oficina360

echo "Contexto configurado sem eks:DescribeCluster."
kubectl get nodes -o wide