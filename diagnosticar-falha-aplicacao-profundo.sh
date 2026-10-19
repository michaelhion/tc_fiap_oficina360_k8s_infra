#!/usr/bin/env bash
set -u

ROOT="${1:-.}"
REPORT="${REPORT:-diagnostico-profundo-aplicacao.txt}"
WORKFLOW_NAME="${WORKFLOW_NAME:-Aplicacao}"
WORKFLOW_FILE="${WORKFLOW_FILE:-.github/workflows/deploy-aplicacao.yml}"
NAMESPACE="${NAMESPACE:-oficina360}"
DB_INSTANCE_ID="${DB_INSTANCE_ID:-oficina360-lab-postgres}"
AWS_REGION="${AWS_REGION:-us-east-1}"

cd "$ROOT" || exit 1
: > "$REPORT"

ERRORS=0
WARNINGS=0
PASSES=0
SSM_DENIED=0
DB_VARS_READY=0

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
section() { log ""; log "============================================================"; log "$1"; log "============================================================"; }
pass() { PASSES=$((PASSES + 1)); log "[OK] $*"; }
warn() { WARNINGS=$((WARNINGS + 1)); log "[WARN] $*"; }
fail() { ERRORS=$((ERRORS + 1)); log "[ERRO] $*"; }
mask() { sed -E 's/(password|token|secret|key)[^[:space:]]*/\1=***/Ig'; }

section "1. CONTEXTO LOCAL E GIT"
log "Data: $(date)"
log "Diretorio: $(pwd)"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  BRANCH="$(git branch --show-current 2>/dev/null || true)"
  LOCAL_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
  pass "Repositorio Git detectado"
  log "Branch local: $BRANCH"
  log "Commit local: $LOCAL_SHA"
  git status --short >> "$REPORT" 2>&1 || true
else
  BRANCH=""
  LOCAL_SHA=""
  fail "Diretorio nao e um repositorio Git"
fi

section "2. IDENTIDADE AWS"
if aws sts get-caller-identity >> "$REPORT" 2>&1; then
  pass "Credenciais AWS validas"
else
  fail "Credenciais AWS invalidas ou expiradas"
fi

section "3. TESTE DIRETO DE PERMISSOES SSM"
for parameter in \
  /oficina360/database/host \
  /oficina360/database/port \
  /oficina360/database/name
do
  OUT="$(aws ssm get-parameter --name "$parameter" --region "$AWS_REGION" --query 'Parameter.Value' --output text 2>&1)"
  RC=$?
  if [[ $RC -eq 0 ]]; then
    pass "Leitura SSM permitida: $parameter"
    log "Valor: $OUT"
  else
    if grep -q 'AccessDenied' <<< "$OUT"; then
      SSM_DENIED=1
      fail "Leitura SSM negada por IAM: $parameter"
    else
      warn "Falha ao ler $parameter: $OUT"
    fi
    printf '%s\n' "$OUT" >> "$REPORT"
  fi
done

section "4. ESTADO REAL DO RDS"
RDS_JSON="$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" --region "$AWS_REGION" --query 'DBInstances[0].{Status:DBInstanceStatus,Host:Endpoint.Address,Port:Endpoint.Port,Name:DBName,Public:PubliclyAccessible,Encrypted:StorageEncrypted,SecurityGroups:VpcSecurityGroups[].VpcSecurityGroupId}' --output json 2>&1)"
RDS_RC=$?
if [[ $RDS_RC -eq 0 ]]; then
  pass "RDS localizado"
  log "$RDS_JSON"
  DB_HOST="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("Host") or "")' <<< "$RDS_JSON" 2>/dev/null || true)"
  DB_PORT="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("Port") or "")' <<< "$RDS_JSON" 2>/dev/null || true)"
  DB_NAME="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("Name") or "")' <<< "$RDS_JSON" 2>/dev/null || true)"
  [[ -n "$DB_NAME" ]] || DB_NAME="oficina360"
else
  fail "Nao foi possivel consultar o RDS $DB_INSTANCE_ID"
  log "$RDS_JSON"
  DB_HOST=""
  DB_PORT=""
  DB_NAME=""
fi

section "5. WORKFLOW LOCAL"
if [[ -s "$WORKFLOW_FILE" ]]; then
  pass "Workflow presente: $WORKFLOW_FILE"
  grep -n -E 'name: (Deploy|Destroy|Configurar cluster)|inputs.action|/oficina360/database/|DB_(HOST|PORT|NAME|USERNAME|PASSWORD)|configure-eks-kubeconfig' "$WORKFLOW_FILE" >> "$REPORT" 2>&1 || true

  if grep -q '/oficina360/database/host' "$WORKFLOW_FILE"; then
    warn "Workflow ainda depende de ssm:GetParameter para dados do banco"
  else
    pass "Workflow nao consulta host do banco via SSM"
  fi

  if grep -q '\${{ vars.DB_HOST }}' "$WORKFLOW_FILE" && \
     grep -q '\${{ vars.DB_PORT }}' "$WORKFLOW_FILE" && \
     grep -q '\${{ vars.DB_NAME }}' "$WORKFLOW_FILE"; then
    pass "Workflow preparado para Repository Variables do banco"
  else
    warn "Workflow ainda nao usa vars.DB_HOST, vars.DB_PORT e vars.DB_NAME"
  fi
else
  fail "Workflow ausente: $WORKFLOW_FILE"
fi

section "6. ULTIMA EXECUCAO DO GITHUB ACTIONS"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  RUN_JSON="$(gh run list --workflow "$WORKFLOW_NAME" --limit 1 --json databaseId,headBranch,headSha,status,conclusion,event,url 2>/dev/null || true)"
  if [[ -n "$RUN_JSON" && "$RUN_JSON" != "[]" ]]; then
    log "$RUN_JSON"
    RUN_ID="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["databaseId"] if d else "")' <<< "$RUN_JSON" 2>/dev/null || true)"
    RUN_BRANCH="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["headBranch"] if d else "")' <<< "$RUN_JSON" 2>/dev/null || true)"
    RUN_SHA="$(python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0]["headSha"] if d else "")' <<< "$RUN_JSON" 2>/dev/null || true)"
    log "Run ID: $RUN_ID"
    log "Branch do run: $RUN_BRANCH"
    log "SHA do run: $RUN_SHA"
    [[ "$RUN_BRANCH" == "$BRANCH" ]] && pass "Run usou a branch local" || warn "Run usou branch diferente"
    [[ "$RUN_SHA" == "$LOCAL_SHA" ]] && pass "Run usou o commit local" || warn "Run nao usou o commit local atual"

    RUN_LOG="$(gh run view "$RUN_ID" --log 2>&1 || true)"
    printf '%s\n' "$RUN_LOG" | grep -E 'Deploy|GetParameter|AccessDenied|database/host|namespace/oficina360|deployment.apps/oficina360|successfully rolled out' >> "$REPORT" 2>&1 || true
    if grep -q 'GetParameter.*AccessDenied\|AccessDenied.*GetParameter' <<< "$RUN_LOG"; then
      SSM_DENIED=1
      fail "Ultimo run falhou por ssm:GetParameter"
    fi
  else
    warn "Nenhuma execucao encontrada para $WORKFLOW_NAME"
  fi
else
  warn "gh ausente ou nao autenticado; logs remotos ignorados"
fi

section "7. REPOSITORY VARIABLES"
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  VARS="$(gh variable list 2>/dev/null || true)"
  for name in EKS_CLUSTER_NAME EKS_CLUSTER_ENDPOINT EKS_CLUSTER_CA; do
    grep -q "^${name}[[:space:]]" <<< "$VARS" && pass "Variable $name presente" || fail "Variable $name ausente"
  done

  DB_PRESENT=0
  for name in DB_HOST DB_PORT DB_NAME; do
    if grep -q "^${name}[[:space:]]" <<< "$VARS"; then
      pass "Variable $name presente"
      DB_PRESENT=$((DB_PRESENT + 1))
    else
      warn "Variable $name ausente"
    fi
  done
  [[ $DB_PRESENT -eq 3 ]] && DB_VARS_READY=1
else
  warn "Nao foi possivel listar Repository Variables"
fi

section "8. ESTADO KUBERNETES"
if kubectl get nodes -o wide >> "$REPORT" 2>&1; then
  pass "Cluster Kubernetes acessivel"
else
  fail "Cluster Kubernetes inacessivel"
fi
if kubectl get namespace "$NAMESPACE" >> "$REPORT" 2>&1; then
  pass "Namespace $NAMESPACE existe"
  kubectl get all -n "$NAMESPACE" -o wide >> "$REPORT" 2>&1 || true
else
  warn "Namespace $NAMESPACE ainda nao existe"
fi

section "9. CORRECAO EFETIVA RECOMENDADA"
if [[ $SSM_DENIED -eq 1 ]]; then
  log "CAUSA RAIZ: a politica do Learner Lab possui explicit deny para ssm:GetParameter."
  log "CORRECAO: nao usar Parameter Store no workflow da aplicacao."
  log "Use Repository Variables para DB_HOST, DB_PORT e DB_NAME; mantenha usuario/senha em GitHub Secrets."
  log ""
  if [[ -n "$DB_HOST" && -n "$DB_PORT" && -n "$DB_NAME" ]]; then
    log "Comandos para cadastrar as variables:"
    log "gh variable set DB_HOST --body '$DB_HOST'"
    log "gh variable set DB_PORT --body '$DB_PORT'"
    log "gh variable set DB_NAME --body '$DB_NAME'"
  else
    log "Nao foi possivel obter automaticamente os valores do RDS."
  fi
  log ""
  log "No step Deploy, substitua os tres aws ssm get-parameter por:"
  log 'env:'
  log '  DB_HOST: ${{ vars.DB_HOST }}'
  log '  DB_PORT: ${{ vars.DB_PORT }}'
  log '  DB_NAME: ${{ vars.DB_NAME }}'
  log '  DB_USERNAME: ${{ secrets.DB_USERNAME }}'
  log '  DB_PASSWORD: ${{ secrets.DB_PASSWORD }}'
  log '  JWT_SECRET: ${{ secrets.JWT_SECRET }}'
else
  log "Nenhum deny de ssm:GetParameter foi confirmado nesta execucao."
fi

section "10. RESUMO"
log "Aprovados: $PASSES"
log "Avisos: $WARNINGS"
log "Erros: $ERRORS"
if [[ $SSM_DENIED -eq 1 ]]; then
  log "RESULTADO: FALHA EXPLICADA. MIGRAR CONFIGURACAO DO BANCO PARA GITHUB VARIABLES."
elif [[ $ERRORS -eq 0 ]]; then
  log "RESULTADO: DIAGNOSTICO SEM BLOQUEIOS"
else
  log "RESULTADO: $ERRORS ERRO(S) ENCONTRADO(S)"
fi
log "Relatorio: $REPORT"

[[ $ERRORS -eq 0 ]] || exit 1
