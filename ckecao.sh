#!/usr/bin/env bash
set -euo pipefail

ROOT="${1:-.}"
TF_DIR="${TF_DIR:-terraform/lab}"
AWS_REGION="${AWS_REGION:-us-east-1}"
DEFAULT_STATE_KEY="${DEFAULT_STATE_KEY:-oficina360/lab.tfstate}"
STATE_JSON="${STATE_JSON:-/tmp/oficina360-state.json}"
TEST_KUBECONFIG="${TEST_KUBECONFIG:-/tmp/oficina360-kubeconfig-test}"

cd "$ROOT"

info() { printf '[INFO] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
fail() { printf '[ERRO] %s\n' "$*" >&2; exit 1; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Comando obrigatorio nao encontrado: $1"
}

get_gh_variable() {
  local name="$1"
  local value=""

  if gh variable list --json name,value >/dev/null 2>&1; then
    value="$(
      gh variable list --json name,value \
        --jq ".[] | select(.name == \"${name}\") | .value" \
        2>/dev/null | head -n 1
    )"
  else
    value="$(
      gh variable list 2>/dev/null |
        awk -v variable="$name" '$1 == variable { print $2; exit }'
    )"
  fi

  printf '%s' "$value"
}

require_command aws
require_command terraform
require_command gh
require_command jq
require_command kubectl

[[ -d "$TF_DIR" ]] || fail "Diretorio Terraform nao encontrado: $TF_DIR"
[[ -f "$TF_DIR/versions.tf" ]] || fail "Arquivo versions.tf nao encontrado em $TF_DIR"

gh auth status >/dev/null 2>&1 || fail "GitHub CLI nao autenticado. Execute: gh auth login"

info "Validando credenciais AWS"
aws sts get-caller-identity --output table

info "Obtendo configuracao do backend no GitHub"
TF_STATE_BUCKET="$(get_gh_variable TF_STATE_BUCKET)"
TF_STATE_KEY="$(get_gh_variable TF_STATE_KEY)"
TF_STATE_KEY="${TF_STATE_KEY:-$DEFAULT_STATE_KEY}"

[[ -n "$TF_STATE_BUCKET" ]] || {
  printf '\nRepository Variables encontradas:\n' >&2
  gh variable list >&2 || true
  fail "TF_STATE_BUCKET nao esta definida no GitHub"
}

printf 'Bucket: %s\n' "$TF_STATE_BUCKET"
printf 'Key:    %s\n' "$TF_STATE_KEY"

info "Validando bucket S3"
aws s3api head-bucket --bucket "$TF_STATE_BUCKET"

info "Validando objeto do state"
if ! aws s3api head-object \
  --bucket "$TF_STATE_BUCKET" \
  --key "$TF_STATE_KEY" \
  >/dev/null; then

  printf '\nObjetos disponiveis no bucket:\n' >&2
  aws s3api list-objects-v2 \
    --bucket "$TF_STATE_BUCKET" \
    --query 'Contents[].{Key:Key,Size:Size,Modified:LastModified}' \
    --output table >&2 || true

  fail "Objeto do state nao encontrado ou sem permissao: s3://${TF_STATE_BUCKET}/${TF_STATE_KEY}"
fi

info "Inicializando o backend Terraform"
terraform -chdir="$TF_DIR" init -reconfigure \
  -backend-config="bucket=$TF_STATE_BUCKET" \
  -backend-config="key=$TF_STATE_KEY" \
  -backend-config="region=$AWS_REGION" \
  -backend-config="use_lockfile=true"

info "Validando recursos no state"
STATE_LIST="$(terraform -chdir="$TF_DIR" state list)"
printf '%s\n' "$STATE_LIST"

grep -qx 'aws_eks_cluster.main' <<< "$STATE_LIST" || \
  fail "aws_eks_cluster.main nao foi encontrado no state"

info "Gerando snapshot JSON do state"
rm -f "$STATE_JSON"
terraform -chdir="$TF_DIR" show -json > "$STATE_JSON"
[[ -s "$STATE_JSON" ]] || fail "State JSON vazio: $STATE_JSON"
chmod 600 "$STATE_JSON"

info "Extraindo configuracao atual do cluster"
EKS_CLUSTER_NAME="$(
  jq -er '
    .values.root_module.resources[]
    | select(.type == "aws_eks_cluster" and .name == "main")
    | .values.name
  ' "$STATE_JSON"
)"

EKS_CLUSTER_ENDPOINT="$(
  jq -er '
    .values.root_module.resources[]
    | select(.type == "aws_eks_cluster" and .name == "main")
    | .values.endpoint
  ' "$STATE_JSON"
)"

EKS_CLUSTER_CA="$(
  jq -er '
    .values.root_module.resources[]
    | select(.type == "aws_eks_cluster" and .name == "main")
    | .values.certificate_authority[0].data
  ' "$STATE_JSON"
)"

[[ -n "$EKS_CLUSTER_NAME" && "$EKS_CLUSTER_NAME" != "null" ]] || fail "Nome do cluster invalido"
[[ "$EKS_CLUSTER_ENDPOINT" =~ ^https://.+\.eks\.amazonaws\.com$ ]] || fail "Endpoint EKS invalido: $EKS_CLUSTER_ENDPOINT"
[[ "${#EKS_CLUSTER_CA}" -ge 100 ]] || fail "Certificate Authority parece invalida"

printf 'Cluster:   %s\n' "$EKS_CLUSTER_NAME"
printf 'Endpoint:  %s\n' "$EKS_CLUSTER_ENDPOINT"
printf 'CA length: %s\n' "${#EKS_CLUSTER_CA}"

info "Atualizando Repository Variables"
gh variable set EKS_CLUSTER_NAME --body "$EKS_CLUSTER_NAME"
gh variable set EKS_CLUSTER_ENDPOINT --body "$EKS_CLUSTER_ENDPOINT"
gh variable set EKS_CLUSTER_CA --body "$EKS_CLUSTER_CA"
ok "Repository Variables atualizadas"

info "Validando resolucao DNS do endpoint"
ENDPOINT_HOST="${EKS_CLUSTER_ENDPOINT#https://}"
getent hosts "$ENDPOINT_HOST" >/dev/null || fail "Endpoint nao resolve no DNS: $ENDPOINT_HOST"
ok "Endpoint resolve no DNS"

info "Testando kubeconfig com os dados atualizados"
export AWS_REGION
export EKS_CLUSTER_NAME
export EKS_CLUSTER_ENDPOINT
export EKS_CLUSTER_CA
export KUBECONFIG="$TEST_KUBECONFIG"

rm -f "$TEST_KUBECONFIG"
bash scripts/configure-eks-kubeconfig.sh

info "Validando nodes"
kubectl get nodes -o wide

READY_NODES="$(
  kubectl get nodes --no-headers 2>/dev/null |
    awk '$2 == "Ready" {count++} END {print count+0}'
)"

[[ "$READY_NODES" -ge 1 ]] || fail "Nenhum node Ready encontrado"
ok "Nodes Ready: $READY_NODES"

info "Conferindo nomes das Repository Variables"
gh variable list |
  grep -E '^EKS_CLUSTER_(NAME|ENDPOINT|CA)[[:space:]]' || true

printf '\n'
ok "Configuracao do cluster atualizada e validada"
printf 'State JSON local: %s\n' "$STATE_JSON"
printf 'Kubeconfig de teste: %s\n' "$TEST_KUBECONFIG"
printf '\nAgora execute a pipeline Aplicacao novamente.\n'
