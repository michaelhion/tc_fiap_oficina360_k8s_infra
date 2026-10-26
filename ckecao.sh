#!/usr/bin/env bash
set -u
set -o pipefail

ROOT="${1:-.}"
REPORT="${REPORT:-diagnostico-roles-eks-profundo.txt}"
AWS_REGION="${AWS_REGION:-us-east-1}"
CLUSTER_NAME="${CLUSTER_NAME:-oficina360}"
NODE_GROUP_NAME="${NODE_GROUP_NAME:-oficina360-lab}"
WORKFLOW_FILE="${WORKFLOW_FILE:-.github/workflows/infrastructure-apply.yml}"
TF_DIR="${TF_DIR:-terraform/lab}"

ERRORS=0
WARNINGS=0
PASSES=0
TMP_DIR="$(mktemp -d)"

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM

cd "$ROOT" || exit 1
: > "$REPORT"
chmod 600 "$REPORT" 2>/dev/null || true

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() {
  log ""
  log "============================================================"
  log "$1"
  log "============================================================"
}
pass() { PASSES=$((PASSES + 1)); log "[OK] $*"; }
warn() { WARNINGS=$((WARNINGS + 1)); log "[WARN] $*"; }
fail() { ERRORS=$((ERRORS + 1)); log "[ERRO] $*"; }
has() { command -v "$1" >/dev/null 2>&1; }

get_gh_var() {
  local name="$1"
  local value=""

  if gh variable list --json name,value >/dev/null 2>&1; then
    value="$(gh variable list --json name,value --jq ".[] | select(.name == \"$name\") | .value" 2>/dev/null | head -n 1)"
  else
    value="$(gh variable list 2>/dev/null | awk -v n="$name" '$1 == n {print $2; exit}')"
  fi

  printf '%s' "$value"
}

role_name_from_arn() {
  printf '%s' "${1##*/}"
}

section "1. CONTEXTO LOCAL"
log "Data: $(date -Is 2>/dev/null || date)"
log "Diretorio: $(pwd)"

for cmd in git aws terraform gh jq; do
  if has "$cmd"; then
    pass "Comando disponivel: $cmd"
  else
    fail "Comando ausente: $cmd"
  fi
done

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BRANCH="$(git branch --show-current 2>/dev/null || true)"
  LOCAL_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
  REMOTE_URL="$(git remote get-url origin 2>/dev/null || true)"
  pass "Repositorio Git detectado"
  log "Branch: ${BRANCH:-desconhecida}"
  log "Commit: ${LOCAL_SHA:-desconhecido}"
  log "Origin: ${REMOTE_URL:-desconhecido}"
  log "--- git status --short ---"
  git status --short >> "$REPORT" 2>&1 || true
else
  BRANCH=""
  LOCAL_SHA=""
  fail "Diretorio nao e repositorio Git"
fi

section "2. CREDENCIAIS E IDENTIDADE AWS"
IDENTITY_JSON="$(aws sts get-caller-identity --output json 2>&1)"
if [[ $? -eq 0 ]]; then
  pass "Credenciais AWS validas"
  log "$IDENTITY_JSON"
  ACCOUNT_ID="$(jq -r '.Account // empty' <<< "$IDENTITY_JSON" 2>/dev/null || true)"
else
  ACCOUNT_ID=""
  fail "Falha em aws sts get-caller-identity"
  log "$IDENTITY_JSON"
fi

section "3. ROLES EKS EXISTENTES NA SESSAO ATUAL"
ROLES_JSON="$(aws iam list-roles --output json 2>&1)"
if [[ $? -eq 0 ]]; then
  pass "iam:ListRoles permitido"
  CURRENT_CLUSTER_ROLE_ARN="$(jq -r '[.Roles[] | select(.RoleName | contains("LabEksClusterRole")) | .Arn][0] // empty' <<< "$ROLES_JSON")"
  CURRENT_NODE_ROLE_ARN="$(jq -r '[.Roles[] | select(.RoleName | contains("LabEksNodeRole")) | .Arn][0] // empty' <<< "$ROLES_JSON")"

  log "Cluster role atual: ${CURRENT_CLUSTER_ROLE_ARN:-NAO ENCONTRADA}"
  log "Node role atual: ${CURRENT_NODE_ROLE_ARN:-NAO ENCONTRADA}"

  [[ -n "$CURRENT_CLUSTER_ROLE_ARN" ]] && pass "LabEksClusterRole atual encontrada" || fail "LabEksClusterRole atual nao encontrada"
  [[ -n "$CURRENT_NODE_ROLE_ARN" ]] && pass "LabEksNodeRole atual encontrada" || fail "LabEksNodeRole atual nao encontrada"
else
  CURRENT_CLUSTER_ROLE_ARN=""
  CURRENT_NODE_ROLE_ARN=""
  fail "Nao foi possivel listar roles IAM"
  log "$ROLES_JSON"
fi

section "4. REPOSITORY VARIABLES DO GITHUB"
if gh auth status >/dev/null 2>&1; then
  pass "GitHub CLI autenticado"

  GH_CLUSTER_ROLE_ARN="$(get_gh_var EKS_CLUSTER_ROLE_ARN)"
  GH_NODE_ROLE_ARN="$(get_gh_var EKS_NODE_ROLE_ARN)"
  GH_STATE_BUCKET="$(get_gh_var TF_STATE_BUCKET)"
  GH_STATE_KEY="$(get_gh_var TF_STATE_KEY)"

  log "EKS_CLUSTER_ROLE_ARN=${GH_CLUSTER_ROLE_ARN:-AUSENTE}"
  log "EKS_NODE_ROLE_ARN=${GH_NODE_ROLE_ARN:-AUSENTE}"
  log "TF_STATE_BUCKET=${GH_STATE_BUCKET:-AUSENTE}"
  log "TF_STATE_KEY=${GH_STATE_KEY:-oficina360/lab.tfstate (default)}"

  [[ "$GH_CLUSTER_ROLE_ARN" == *LabEksClusterRole* ]] && pass "Repository Variable de cluster tem tipo correto" || fail "EKS_CLUSTER_ROLE_ARN ausente ou incorreta"
  [[ "$GH_NODE_ROLE_ARN" == *LabEksNodeRole* ]] && pass "Repository Variable de node tem tipo correto" || fail "EKS_NODE_ROLE_ARN ausente ou incorreta"

  if [[ -n "$CURRENT_CLUSTER_ROLE_ARN" && "$GH_CLUSTER_ROLE_ARN" == "$CURRENT_CLUSTER_ROLE_ARN" ]]; then
    pass "Repository Variable da cluster role corresponde a sessao atual"
  else
    fail "Repository Variable da cluster role nao corresponde a sessao atual"
  fi

  if [[ -n "$CURRENT_NODE_ROLE_ARN" && "$GH_NODE_ROLE_ARN" == "$CURRENT_NODE_ROLE_ARN" ]]; then
    pass "Repository Variable da node role corresponde a sessao atual"
  else
    fail "Repository Variable da node role nao corresponde a sessao atual"
  fi
else
  GH_CLUSTER_ROLE_ARN=""
  GH_NODE_ROLE_ARN=""
  GH_STATE_BUCKET=""
  GH_STATE_KEY=""
  fail "GitHub CLI nao autenticado"
fi

section "5. EXISTENCIA DAS ROLES REFERENCIADAS"
for pair in \
  "GH_CLUSTER|$GH_CLUSTER_ROLE_ARN" \
  "GH_NODE|$GH_NODE_ROLE_ARN" \
  "CURRENT_CLUSTER|$CURRENT_CLUSTER_ROLE_ARN" \
  "CURRENT_NODE|$CURRENT_NODE_ROLE_ARN"
do
  label="${pair%%|*}"
  arn="${pair#*|}"
  [[ -n "$arn" ]] || continue
  role_name="$(role_name_from_arn "$arn")"

  if jq -e --arg arn "$arn" '.Roles[] | select(.Arn == $arn)' <<< "$ROLES_JSON" >/dev/null 2>&1; then
    pass "$label existe: $role_name"
  else
    fail "$label NAO existe na sessao atual: $role_name"
  fi
done

section "6. CONFIGURACAO TERRAFORM"
if [[ -f "$TF_DIR/eks.tf" ]]; then
  pass "$TF_DIR/eks.tf encontrado"
  log "--- referencias de role em eks.tf ---"
  grep -n -E 'resource "aws_eks_(cluster|node_group)"|role_arn|node_role_arn|ignore_changes' "$TF_DIR/eks.tf" >> "$REPORT" 2>&1 || true

  CLUSTER_RESOURCE_COUNT="$(grep -c 'resource "aws_eks_cluster" "main"' "$TF_DIR/eks.tf" || true)"
  NODE_RESOURCE_COUNT="$(grep -c 'resource "aws_eks_node_group" "main"' "$TF_DIR/eks.tf" || true)"
  [[ "$CLUSTER_RESOURCE_COUNT" -eq 1 ]] && pass "Existe exatamente um aws_eks_cluster.main" || fail "Quantidade invalida de aws_eks_cluster.main: $CLUSTER_RESOURCE_COUNT"
  [[ "$NODE_RESOURCE_COUNT" -eq 1 ]] && pass "Existe exatamente um aws_eks_node_group.main" || fail "Quantidade invalida de aws_eks_node_group.main: $NODE_RESOURCE_COUNT"

  if grep -Eq 'node_role_arn[[:space:]]*=[[:space:]]*var\.eks_node_role_arn' "$TF_DIR/eks.tf"; then
    pass "Node group usa var.eks_node_role_arn"
  else
    fail "Node group nao usa var.eks_node_role_arn"
  fi

  if grep -Eq 'role_arn[[:space:]]*=[[:space:]]*var\.eks_cluster_role_arn' "$TF_DIR/eks.tf"; then
    pass "Cluster usa var.eks_cluster_role_arn"
  else
    fail "Cluster nao usa var.eks_cluster_role_arn"
  fi
else
  fail "$TF_DIR/eks.tf ausente"
fi

if terraform -chdir="$TF_DIR" validate >> "$REPORT" 2>&1; then
  pass "terraform validate passou"
else
  fail "terraform validate falhou"
fi

section "7. WORKFLOW LOCAL E REMOTO"
if [[ -f "$WORKFLOW_FILE" ]]; then
  pass "$WORKFLOW_FILE encontrado"
  log "--- trechos relevantes do workflow local ---"
  grep -n -E 'Configurar roles EKS|EKS_(CLUSTER|NODE)_ROLE_ARN|TF_VAR_eks_(cluster|node)_role_arn|Terraform plan|Terraform apply|NODE_ROLE=' "$WORKFLOW_FILE" >> "$REPORT" 2>&1 || true

  if grep -q 'TF_VAR_eks_node_role_arn=$EKS_NODE_ROLE_ARN' "$WORKFLOW_FILE"; then
    pass "Workflow local exporta node role corretamente"
  else
    fail "Workflow local nao exporta node role corretamente"
  fi

  if grep -q 'TF_VAR_eks_cluster_role_arn=$EKS_CLUSTER_ROLE_ARN' "$WORKFLOW_FILE"; then
    pass "Workflow local exporta cluster role corretamente"
  else
    fail "Workflow local nao exporta cluster role corretamente"
  fi
else
  fail "$WORKFLOW_FILE ausente"
fi

if [[ -n "$BRANCH" ]]; then
  git fetch origin "$BRANCH" >> "$REPORT" 2>&1 || warn "Falha em git fetch origin $BRANCH"
  if git show "origin/$BRANCH:$WORKFLOW_FILE" > "$TMP_DIR/remote-workflow.yml" 2>/dev/null; then
    REMOTE_SHA="$(git rev-parse "origin/$BRANCH" 2>/dev/null || true)"
    log "Commit remoto: $REMOTE_SHA"
    [[ "$LOCAL_SHA" == "$REMOTE_SHA" ]] && pass "Commit local corresponde ao remoto" || warn "Commit local difere do remoto"

    if cmp -s "$WORKFLOW_FILE" "$TMP_DIR/remote-workflow.yml"; then
      pass "Workflow local e remoto sao identicos"
    else
      fail "Workflow local difere do remoto; pipeline pode usar codigo antigo"
      diff -u "$TMP_DIR/remote-workflow.yml" "$WORKFLOW_FILE" >> "$REPORT" 2>&1 || true
    fi
  else
    fail "Nao foi possivel ler workflow na branch remota"
  fi
fi

section "8. STATE REMOTO E RECURSOS ATUAIS"
if terraform -chdir="$TF_DIR" state list > "$TMP_DIR/state.txt" 2>> "$REPORT"; then
  pass "State remoto acessivel"
  cat "$TMP_DIR/state.txt" >> "$REPORT"
  grep -qx 'aws_eks_cluster.main' "$TMP_DIR/state.txt" && pass "Cluster presente no state" || fail "Cluster ausente do state"
  if grep -qx 'aws_eks_node_group.main' "$TMP_DIR/state.txt"; then
    warn "Node group ja consta no state"
  else
    pass "Node group ainda nao consta no state, coerente com a falha"
  fi
else
  fail "Nao foi possivel consultar o state remoto"
fi

CLUSTER_JSON="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --output json 2>&1)"
if [[ $? -eq 0 ]]; then
  pass "Cluster EKS existe"
  ACTUAL_CLUSTER_ROLE="$(jq -r '.cluster.roleArn // empty' <<< "$CLUSTER_JSON")"
  CLUSTER_STATUS="$(jq -r '.cluster.status // empty' <<< "$CLUSTER_JSON")"
  log "Cluster status: $CLUSTER_STATUS"
  log "Cluster role real: $ACTUAL_CLUSTER_ROLE"
else
  ACTUAL_CLUSTER_ROLE=""
  fail "Nao foi possivel consultar o cluster EKS"
  log "$CLUSTER_JSON"
fi

NODEGROUP_JSON="$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODE_GROUP_NAME" --region "$AWS_REGION" --output json 2>&1)"
if [[ $? -eq 0 ]]; then
  warn "Node group ja existe na AWS"
  log "$NODEGROUP_JSON"
else
  pass "Node group ainda nao existe na AWS"
fi

section "9. ULTIMA EXECUCAO DO GITHUB ACTIONS"
if gh auth status >/dev/null 2>&1; then
  RUN_JSON="$(gh run list --workflow 'Infrastructure Apply' --limit 1 --json databaseId,headBranch,headSha,status,conclusion,url 2>/dev/null || true)"
  if [[ -n "$RUN_JSON" && "$RUN_JSON" != "[]" ]]; then
    log "$RUN_JSON"
    RUN_ID="$(jq -r '.[0].databaseId // empty' <<< "$RUN_JSON")"
    RUN_SHA="$(jq -r '.[0].headSha // empty' <<< "$RUN_JSON")"
    RUN_BRANCH="$(jq -r '.[0].headBranch // empty' <<< "$RUN_JSON")"
    log "Run ID: $RUN_ID"
    log "Run branch: $RUN_BRANCH"
    log "Run SHA: $RUN_SHA"
    [[ "$RUN_SHA" == "$LOCAL_SHA" ]] && pass "Ultimo run usou o commit local" || fail "Ultimo run nao usou o commit local"

    RUN_LOG="$(gh run view "$RUN_ID" --log 2>&1 || true)"
    printf '%s\n' "$RUN_LOG" | grep -E 'Cluster role:|Node role:|Node role planejada:|TF_VAR_eks_|CreateNodegroup|LabEks(Cluster|Node)Role|NoSuchEntity|Terraform plan|Terraform apply' >> "$REPORT" 2>&1 || true

    FAILED_ROLE_NAME="$(printf '%s\n' "$RUN_LOG" | sed -nE 's/.*The role with name ([^ ]+) cannot be found.*/\1/p' | tail -n 1)"
    if [[ -n "$FAILED_ROLE_NAME" ]]; then
      fail "Ultimo run tentou usar role inexistente: $FAILED_ROLE_NAME"
      if [[ "$FAILED_ROLE_NAME" == *LabEksClusterRole* ]]; then
        fail "Ultimo run tentou usar CLUSTER ROLE no node group"
      fi
    fi
  else
    warn "Nenhum run encontrado"
  fi
fi

section "10. PLANO LOCAL DIAGNOSTICO"
PLAN_READY=true
if [[ -z "$CURRENT_CLUSTER_ROLE_ARN" || -z "$CURRENT_NODE_ROLE_ARN" ]]; then
  warn "Roles atuais indisponiveis; plano local ignorado"
  PLAN_READY=false
fi

if [[ "$PLAN_READY" == true ]]; then
  export TF_VAR_aws_region="$AWS_REGION"
  export TF_VAR_project_name="$CLUSTER_NAME"
  export TF_VAR_kubernetes_version="1.36"
  export TF_VAR_eks_cluster_role_arn="$CURRENT_CLUSTER_ROLE_ARN"
  export TF_VAR_eks_node_role_arn="$CURRENT_NODE_ROLE_ARN"

  if terraform -chdir="$TF_DIR" plan -out="$TMP_DIR/diagnostic.tfplan" >> "$REPORT" 2>&1; then
    pass "Plano local gerado"
    terraform -chdir="$TF_DIR" show -json "$TMP_DIR/diagnostic.tfplan" > "$TMP_DIR/plan.json" 2>> "$REPORT" || true
    terraform -chdir="$TF_DIR" show -no-color "$TMP_DIR/diagnostic.tfplan" > "$TMP_DIR/plan.txt" 2>> "$REPORT" || true

    PLANNED_NODE_ROLE="$(jq -r '
      [
        .planned_values.root_module.resources[]?,
        .planned_values.root_module.child_modules[]?.resources[]?
      ]
      | .[]
      | select(.type == "aws_eks_node_group" and .name == "main")
      | .values.node_role_arn
    ' "$TMP_DIR/plan.json" 2>/dev/null | head -n 1)"

    log "Node role no plano local: ${PLANNED_NODE_ROLE:-NAO ENCONTRADA}"
    if [[ "$PLANNED_NODE_ROLE" == "$CURRENT_NODE_ROLE_ARN" ]]; then
      pass "Plano local usa a LabEksNodeRole atual"
    else
      fail "Plano local nao usa a LabEksNodeRole atual"
    fi

    if grep -q 'aws_eks_cluster.main must be replaced' "$TMP_DIR/plan.txt"; then
      fail "Plano local tenta substituir o cluster"
    else
      pass "Plano local preserva o cluster"
    fi

    PLAN_SUMMARY="$(grep 'Plan:' "$TMP_DIR/plan.txt" | tail -n 1 || true)"
    log "Resumo do plano: ${PLAN_SUMMARY:-sem alteracoes ou nao identificado}"
  else
    fail "Falha ao gerar plano local"
  fi
fi

section "11. DIAGNOSTICO E CORRECAO SUGERIDA"
if [[ -n "$CURRENT_NODE_ROLE_ARN" && "$GH_NODE_ROLE_ARN" != "$CURRENT_NODE_ROLE_ARN" ]]; then
  log "CAUSA CONFIRMADA: EKS_NODE_ROLE_ARN no GitHub esta desatualizada."
  log "Comando de correcao:"
  log "gh variable set EKS_NODE_ROLE_ARN --body '$CURRENT_NODE_ROLE_ARN'"
fi

if [[ -n "$CURRENT_CLUSTER_ROLE_ARN" && "$GH_CLUSTER_ROLE_ARN" != "$CURRENT_CLUSTER_ROLE_ARN" ]]; then
  log "ATENCAO: EKS_CLUSTER_ROLE_ARN no GitHub difere da role atual."
  log "Como o cluster existente preserva a role antiga com ignore_changes, nao troque o cluster sem revisar o plano."
fi

if [[ -n "$FAILED_ROLE_NAME" ]]; then
  log "A role usada na falha foi: $FAILED_ROLE_NAME"
fi

log "Antes de um novo deploy, confirme no log do step Configurar roles EKS:"
log "Cluster role: ...LabEksClusterRole..."
log "Node role: ...LabEksNodeRole..."
log "E no step Terraform plan: Node role planejada: ...LabEksNodeRole..."

section "12. RESUMO"
log "Aprovados: $PASSES"
log "Avisos: $WARNINGS"
log "Erros: $ERRORS"
log "Relatorio: $REPORT"

if [[ "$ERRORS" -eq 0 ]]; then
  log "RESULTADO: DIAGNOSTICO SEM BLOQUEIOS"
  exit 0
else
  log "RESULTADO: $ERRORS PROBLEMA(S) ENCONTRADO(S)"
  exit 1
fi

