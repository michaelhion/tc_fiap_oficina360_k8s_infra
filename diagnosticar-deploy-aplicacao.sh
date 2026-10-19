#!/usr/bin/env bash
set -u

ROOT="${1:-.}"
REPORT="${REPORT:-aplicacao-deploy-diagnostico.txt}"
NAMESPACE="${NAMESPACE:-oficina360}"
DEPLOYMENT="${DEPLOYMENT:-oficina360-api}"
SERVICE="${SERVICE:-oficina360-api}"
WORKFLOW="${WORKFLOW:-Aplicacao}"

cd "$ROOT" || exit 1
: > "$REPORT"

ERRORS=0
WARNINGS=0
PASSES=0

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "============================================================"; log "$1"; log "============================================================"; }
pass() { PASSES=$((PASSES + 1)); log "[OK] $*"; }
warn() { WARNINGS=$((WARNINGS + 1)); log "[WARN] $*"; }
fail() { ERRORS=$((ERRORS + 1)); log "[ERRO] $*"; }
run_capture() { "$@" >> "$REPORT" 2>&1; }

section "1. CONTEXTO LOCAL"
log "Data: $(date)"
log "Diretorio: $(pwd)"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  pass "Repositorio Git detectado"
  BRANCH="$(git branch --show-current 2>/dev/null || true)"
  HEAD_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
  log "Branch local: ${BRANCH:-desconhecida}"
  log "Commit local: ${HEAD_SHA:-desconhecido}"
  git status --short >> "$REPORT" 2>&1 || true
else
  fail "O diretorio nao e um repositorio Git"
  BRANCH=""
  HEAD_SHA=""
fi

section "2. IDENTIDADE AWS E CLUSTER ATUAL"
if command -v aws >/dev/null 2>&1; then
  if run_capture aws sts get-caller-identity; then
    pass "Credenciais AWS validas"
  else
    fail "Falha em aws sts get-caller-identity"
  fi
else
  fail "AWS CLI nao instalado"
fi

if command -v kubectl >/dev/null 2>&1; then
  CURRENT_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
  CURRENT_SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  log "Contexto kubectl: ${CURRENT_CONTEXT:-ausente}"
  log "Endpoint kubectl: ${CURRENT_SERVER:-ausente}"

  if run_capture kubectl auth can-i get namespaces; then
    CAN_GET_NS="$(kubectl auth can-i get namespaces 2>/dev/null || true)"
    if [[ "$CAN_GET_NS" == "yes" ]]; then pass "Identidade pode consultar namespaces"; else fail "Identidade nao pode consultar namespaces"; fi
  else
    fail "Falha ao consultar autorizacao Kubernetes"
  fi

  if run_capture kubectl get nodes -o wide; then
    pass "Cluster Kubernetes acessivel"
  else
    fail "Cluster Kubernetes inacessivel"
  fi
else
  fail "kubectl nao instalado"
fi

section "3. ESTADO REAL DA APLICACAO"
if kubectl get namespace "$NAMESPACE" >> "$REPORT" 2>&1; then
  pass "Namespace $NAMESPACE existe"

  kubectl get deployment,pod,service,configmap,secret -n "$NAMESPACE" -o wide >> "$REPORT" 2>&1 || true
  kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp >> "$REPORT" 2>&1 || true

  if kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" >> "$REPORT" 2>&1; then
    pass "Deployment $DEPLOYMENT existe"
    if kubectl rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout=30s >> "$REPORT" 2>&1; then
      pass "Rollout do Deployment concluido"
    else
      fail "Rollout do Deployment nao esta saudavel"
    fi

    IMAGE="$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
    log "Imagem implantada: ${IMAGE:-nao encontrada}"
  else
    fail "Deployment $DEPLOYMENT ausente"
  fi

  if kubectl get service "$SERVICE" -n "$NAMESPACE" >> "$REPORT" 2>&1; then
    pass "Service $SERVICE existe"
  else
    fail "Service $SERVICE ausente"
  fi
else
  fail "Namespace $NAMESPACE nao existe no cluster atual"
fi

section "4. MANIFESTO E WORKFLOW LOCAL"
WORKFLOW_FILE=".github/workflows/deploy-aplicacao.yml"
NAMESPACE_FILE="k8s/aws/namespace.yaml"

if [[ -s "$NAMESPACE_FILE" ]]; then
  pass "Manifesto $NAMESPACE_FILE existe"
  if grep -Eq '^[[:space:]]*name:[[:space:]]*oficina360[[:space:]]*$' "$NAMESPACE_FILE"; then
    pass "Manifesto declara namespace oficina360"
  else
    fail "Manifesto nao declara metadata.name=oficina360"
  fi
else
  fail "Manifesto $NAMESPACE_FILE ausente ou vazio"
fi

if [[ -s "$WORKFLOW_FILE" ]]; then
  pass "Workflow $WORKFLOW_FILE existe"

  if grep -Eq "if:[[:space:]]*inputs\.action[[:space:]]*==[[:space:]]*'deploy'" "$WORKFLOW_FILE"; then
    pass "Step de deploy possui condicao action=deploy"
  else
    warn "Nao foi encontrada condicao exata inputs.action == 'deploy'"
  fi

  if grep -Eq 'kubectl apply -f k8s/aws/namespace.yaml' "$WORKFLOW_FILE"; then
    pass "Workflow aplica o namespace"
  else
    fail "Workflow nao aplica k8s/aws/namespace.yaml"
  fi

  if grep -Eq 'configure-eks-kubeconfig\.sh' "$WORKFLOW_FILE"; then
    pass "Workflow usa script de kubeconfig sem DescribeCluster"
  else
    fail "Workflow nao usa configure-eks-kubeconfig.sh"
  fi

  if grep -Eq 'eks update-kubeconfig' "$WORKFLOW_FILE"; then
    fail "Workflow ainda usa aws eks update-kubeconfig"
  else
    pass "Workflow nao usa aws eks update-kubeconfig"
  fi

  if grep -Eq 'kubectl delete namespace.*NAMESPACE|kubectl delete namespace oficina360' "$WORKFLOW_FILE"; then
    log "[INFO] Workflow contem exclusao de namespace; revise se esta somente no step Destroy"
  fi

  log "--- Trechos relevantes do workflow ---"
  grep -n -E "name: (Deploy|Destroy|Configurar cluster|Verificar deploy)|if:.*inputs\.action|namespace\.yaml|delete namespace|configure-eks-kubeconfig" "$WORKFLOW_FILE" >> "$REPORT" 2>&1 || true
else
  fail "Workflow $WORKFLOW_FILE ausente ou vazio"
fi

section "5. COMPARACAO COM BRANCH REMOTA"
if [[ -n "$BRANCH" ]]; then
  git fetch origin "$BRANCH" >> "$REPORT" 2>&1 || warn "Nao foi possivel atualizar origin/$BRANCH"
  if git show "origin/${BRANCH}:${WORKFLOW_FILE}" >/tmp/oficina360-remote-workflow.yml 2>/dev/null; then
    REMOTE_SHA="$(git rev-parse "origin/$BRANCH" 2>/dev/null || true)"
    log "Commit remoto: ${REMOTE_SHA:-desconhecido}"

    if cmp -s "$WORKFLOW_FILE" /tmp/oficina360-remote-workflow.yml; then
      pass "Workflow local e remoto sao identicos"
    else
      warn "Workflow local difere da branch remota"
      diff -u /tmp/oficina360-remote-workflow.yml "$WORKFLOW_FILE" >> "$REPORT" 2>&1 || true
    fi

    if grep -Eq 'configure-eks-kubeconfig\.sh' /tmp/oficina360-remote-workflow.yml; then
      pass "Workflow remoto usa configure-eks-kubeconfig.sh"
    else
      fail "Workflow remoto nao contem a configuracao nova do kubeconfig"
    fi
  else
    fail "Nao foi possivel ler $WORKFLOW_FILE em origin/$BRANCH"
  fi
fi

section "6. ULTIMA EXECUCAO DO GITHUB ACTIONS"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  RUN_JSON="$(gh run list --workflow "$WORKFLOW" --limit 1 --json databaseId,headBranch,headSha,status,conclusion,event,displayTitle,url 2>/dev/null || true)"
  if [[ -n "$RUN_JSON" && "$RUN_JSON" != "[]" ]]; then
    log "$RUN_JSON"
    RUN_ID="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["databaseId"] if d else "")' <<< "$RUN_JSON" 2>/dev/null || true)"
    RUN_BRANCH="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["headBranch"] if d else "")' <<< "$RUN_JSON" 2>/dev/null || true)"
    RUN_SHA="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["headSha"] if d else "")' <<< "$RUN_JSON" 2>/dev/null || true)"
    log "Ultima execucao: id=$RUN_ID branch=$RUN_BRANCH sha=$RUN_SHA"

    if [[ "$RUN_BRANCH" == "$BRANCH" ]]; then pass "Ultima execucao usou a branch local atual"; else warn "Ultima execucao usou branch diferente: $RUN_BRANCH"; fi
    if [[ "$RUN_SHA" == "$HEAD_SHA" ]]; then pass "Ultima execucao usou o commit local atual"; else warn "Ultima execucao nao usou o commit local atual"; fi

    if [[ -n "$RUN_ID" ]]; then
      log "--- Jobs da ultima execucao ---"
      gh run view "$RUN_ID" --json jobs >> "$REPORT" 2>&1 || true
      log "--- Linhas relevantes do log ---"
      gh run view "$RUN_ID" --log 2>/dev/null | grep -E "action=|namespace/oficina360|configmap/oficina360|secret/oficina360|deployment.apps/oficina360|service/oficina360|successfully rolled out|Deploy|Destroy|skipped" >> "$REPORT" 2>&1 || true
    fi
  else
    warn "Nenhuma execucao encontrada para o workflow $WORKFLOW"
  fi
else
  warn "gh ausente ou nao autenticado; analise da execucao remota ignorada"
fi

section "7. REPOSITORY VARIABLES"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  VARS="$(gh variable list 2>/dev/null || true)"
  for name in EKS_CLUSTER_NAME EKS_CLUSTER_ENDPOINT EKS_CLUSTER_CA; do
    if grep -q "^${name}[[:space:]]" <<< "$VARS"; then pass "Repository Variable $name existe"; else fail "Repository Variable $name ausente"; fi
  done
fi

section "8. DIAGNOSTICO FINAL"
if [[ "$ERRORS" -eq 0 ]] && kubectl get namespace "$NAMESPACE" >/dev/null 2>&1; then
  log "RESULTADO: APLICACAO IMPLANTADA E VALIDADA"
elif [[ "$ERRORS" -gt 0 ]]; then
  log "RESULTADO: DEPLOY NAO COMPROVADO; $ERRORS ERRO(S), $WARNINGS AVISO(S)"
else
  log "RESULTADO: DEPLOY NAO COMPROVADO"
fi
log "Aprovados: $PASSES"
log "Avisos: $WARNINGS"
log "Erros: $ERRORS"
log "Relatorio: $REPORT"

if [[ ! -e "/tmp/oficina360-remote-workflow.yml" ]]; then :; else rm -f /tmp/oficina360-remote-workflow.yml; fi

[[ "$ERRORS" -eq 0 ]] || exit 1
