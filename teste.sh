#!/usr/bin/env bash
set -u
set -o pipefail

# Validacao ponta a ponta da aplicacao Oficina360 no EKS.
# O script nao exibe valores de Secrets.
# O unico recurso temporario criado e um Pod de teste TCP, removido ao final.

NAMESPACE="${NAMESPACE:-oficina360}"
DEPLOYMENT="${DEPLOYMENT:-oficina360-api}"
SERVICE="${SERVICE:-oficina360-api}"
APP_LABEL="${APP_LABEL:-app=oficina360-api}"
CONTAINER_NAME="${CONTAINER_NAME:-oficina360-api}"
LOCAL_PORT="${LOCAL_PORT:-18080}"
HEALTH_PATH="${HEALTH_PATH:-/actuator/health}"
API_PATH="${API_PATH:-}"
EXPECTED_IMAGE="${EXPECTED_IMAGE:-}"
AWS_REGION="${AWS_REGION:-us-east-1}"
RDS_INSTANCE_ID="${RDS_INSTANCE_ID:-oficina360-lab-postgres}"
REPORT="${REPORT:-/tmp/oficina360-validacao-completa.txt}"
TCP_TEST_IMAGE="${TCP_TEST_IMAGE:-postgres:16-alpine}"
SKIP_AWS="${SKIP_AWS:-false}"
SKIP_RDS_TCP="${SKIP_RDS_TCP:-false}"
SKIP_HTTP="${SKIP_HTTP:-false}"

ERRORS=0
WARNINGS=0
PASSES=0
PF_PID=""
TCP_POD="oficina360-rds-check-$(date +%s)"

: > "$REPORT"

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

cleanup() {
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" >/dev/null 2>&1 || true
    wait "$PF_PID" >/dev/null 2>&1 || true
  fi
  kubectl delete pod "$TCP_POD" -n "$NAMESPACE" \
    --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

command_exists() { command -v "$1" >/dev/null 2>&1; }

section "1. PRE-REQUISITOS"
for cmd in kubectl curl; do
  if command_exists "$cmd"; then
    pass "Comando disponivel: $cmd"
  else
    fail "Comando ausente: $cmd"
  fi
done
if [[ "$SKIP_AWS" != "true" ]]; then
  if command_exists aws; then pass "Comando disponivel: aws"; else warn "AWS CLI ausente; testes AWS serao ignorados"; SKIP_AWS=true; fi
fi

section "2. CONTEXTO E ACESSO AO CLUSTER"
CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
SERVER="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
log "Contexto: ${CONTEXT:-ausente}"
log "Endpoint: ${SERVER:-ausente}"

if [[ -z "$CONTEXT" ]]; then fail "Contexto Kubernetes ausente"; else pass "Contexto Kubernetes configurado"; fi
if kubectl get nodes -o wide >> "$REPORT" 2>&1; then
  pass "Cluster Kubernetes acessivel"
else
  fail "Nao foi possivel consultar os nodes"
fi

NOT_READY_NODES="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {print $1 ":" $2}' || true)"
if [[ -z "$NOT_READY_NODES" ]]; then pass "Todos os nodes estao Ready"; else fail "Nodes nao saudaveis: $NOT_READY_NODES"; fi

for verb_resource in "get namespaces" "create namespaces" "create deployments.apps" "create services" "create configmaps" "create secrets"; do
  verb="${verb_resource%% *}"
  resource="${verb_resource#* }"
  answer="$(kubectl auth can-i "$verb" "$resource" -n "$NAMESPACE" 2>/dev/null || true)"
  if [[ "$answer" == "yes" ]]; then pass "Permissao Kubernetes: $verb $resource"; else warn "Permissao Kubernetes nao confirmada: $verb $resource ($answer)"; fi
done

section "3. NAMESPACE E OBJETOS"
if kubectl get namespace "$NAMESPACE" >> "$REPORT" 2>&1; then
  pass "Namespace $NAMESPACE existe"
else
  fail "Namespace $NAMESPACE nao existe"
fi

if kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" >> "$REPORT" 2>&1; then
  pass "Deployment $DEPLOYMENT existe"
else
  fail "Deployment $DEPLOYMENT ausente"
fi

if kubectl get service "$SERVICE" -n "$NAMESPACE" >> "$REPORT" 2>&1; then
  pass "Service $SERVICE existe"
else
  fail "Service $SERVICE ausente"
fi

if kubectl get configmap oficina360-config -n "$NAMESPACE" >> "$REPORT" 2>&1; then
  pass "ConfigMap oficina360-config existe"
else
  fail "ConfigMap oficina360-config ausente"
fi

if kubectl get secret oficina360-secret -n "$NAMESPACE" >/dev/null 2>&1; then
  pass "Secret oficina360-secret existe"
else
  fail "Secret oficina360-secret ausente"
fi

kubectl get deployment,pod,service,configmap -n "$NAMESPACE" -o wide >> "$REPORT" 2>&1 || true

section "4. ROLLOUT, PODS E IMAGEM"
if kubectl rollout status deployment/"$DEPLOYMENT" -n "$NAMESPACE" --timeout=2m >> "$REPORT" 2>&1; then
  pass "Rollout concluido"
else
  fail "Rollout nao concluido"
fi

DESIRED="$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 0)"
READY="$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
AVAILABLE="$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.status.availableReplicas}' 2>/dev/null || echo 0)"
READY="${READY:-0}"
AVAILABLE="${AVAILABLE:-0}"
log "Replicas: desejadas=$DESIRED prontas=$READY disponiveis=$AVAILABLE"
if [[ "$READY" -ge 1 && "$AVAILABLE" -ge 1 ]]; then pass "Deployment possui replica pronta e disponivel"; else fail "Deployment sem replica pronta/disponivel"; fi

POD_LINES="$(kubectl get pods -n "$NAMESPACE" -l "$APP_LABEL" -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"|"}{.status.containerStatuses[0].ready}{"|"}{.status.containerStatuses[0].restartCount}{"\n"}{end}' 2>/dev/null || true)"
if [[ -z "$POD_LINES" ]]; then
  fail "Nenhum pod encontrado com selector $APP_LABEL"
else
  while IFS='|' read -r pod phase ready restarts; do
    [[ -n "$pod" ]] || continue
    log "Pod $pod: phase=$phase ready=$ready restarts=$restarts"
    if [[ "$phase" == "Running" && "$ready" == "true" ]]; then pass "Pod $pod esta Running e Ready"; else fail "Pod $pod nao esta saudavel"; fi
    if [[ "${restarts:-0}" -eq 0 ]]; then pass "Pod $pod sem reinicializacoes"; else warn "Pod $pod possui ${restarts:-0} reinicializacao(oes)"; fi
  done <<< "$POD_LINES"
fi

DEPLOYED_IMAGE="$(kubectl get deployment "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
IMAGE_ID="$(kubectl get pods -n "$NAMESPACE" -l "$APP_LABEL" -o jsonpath='{.items[0].status.containerStatuses[0].imageID}' 2>/dev/null || true)"
log "Imagem declarada: ${DEPLOYED_IMAGE:-ausente}"
log "Image ID: ${IMAGE_ID:-ausente}"
if [[ -n "$DEPLOYED_IMAGE" ]]; then pass "Imagem implantada identificada"; else fail "Imagem implantada nao identificada"; fi
if [[ -n "$EXPECTED_IMAGE" ]]; then
  if [[ "$DEPLOYED_IMAGE" == "$EXPECTED_IMAGE" ]]; then pass "Imagem corresponde a EXPECTED_IMAGE"; else fail "Imagem divergente. Esperada=$EXPECTED_IMAGE Atual=$DEPLOYED_IMAGE"; fi
fi
if [[ "$IMAGE_ID" == *@sha256:* ]]; then pass "Runtime informa digest sha256 da imagem"; else warn "Digest sha256 da imagem nao foi identificado"; fi

section "5. CONFIGMAP E SECRET"
DB_HOST="$(kubectl get configmap oficina360-config -n "$NAMESPACE" -o jsonpath='{.data.DB_HOST}' 2>/dev/null || true)"
DB_PORT="$(kubectl get configmap oficina360-config -n "$NAMESPACE" -o jsonpath='{.data.DB_PORT}' 2>/dev/null || true)"
DB_NAME="$(kubectl get configmap oficina360-config -n "$NAMESPACE" -o jsonpath='{.data.DB_NAME}' 2>/dev/null || true)"
PROFILE="$(kubectl get configmap oficina360-config -n "$NAMESPACE" -o jsonpath='{.data.SPRING_PROFILES_ACTIVE}' 2>/dev/null || true)"
SERVER_PORT="$(kubectl get configmap oficina360-config -n "$NAMESPACE" -o jsonpath='{.data.SERVER_PORT}' 2>/dev/null || true)"
log "DB_HOST=$DB_HOST"
log "DB_PORT=$DB_PORT"
log "DB_NAME=$DB_NAME"
log "SPRING_PROFILES_ACTIVE=$PROFILE"
log "SERVER_PORT=$SERVER_PORT"
[[ -n "$DB_HOST" ]] && pass "DB_HOST configurado" || fail "DB_HOST ausente"
[[ "$DB_PORT" =~ ^[0-9]+$ ]] && pass "DB_PORT numerico" || fail "DB_PORT invalido"
[[ -n "$DB_NAME" ]] && pass "DB_NAME configurado" || fail "DB_NAME ausente"
[[ "$PROFILE" == "aws" ]] && pass "Profile aws ativo" || warn "Profile esperado aws, atual=$PROFILE"
[[ "$SERVER_PORT" == "8081" ]] && pass "SERVER_PORT=8081" || warn "SERVER_PORT atual=$SERVER_PORT"

SECRET_KEYS="$(kubectl get secret oficina360-secret -n "$NAMESPACE" -o json 2>/dev/null | python3 -c 'import json,sys; print("\n".join(sorted(json.load(sys.stdin).get("data",{}).keys())))' 2>/dev/null || true)"
for key in DB_USERNAME DB_PASSWORD JWT_SECRET; do
  if grep -qx "$key" <<< "$SECRET_KEYS"; then pass "Secret contem chave $key"; else fail "Secret nao contem chave $key"; fi
done

section "6. SERVICE E ENDPOINTS"
SERVICE_TYPE="$(kubectl get service "$SERVICE" -n "$NAMESPACE" -o jsonpath='{.spec.type}' 2>/dev/null || true)"
SERVICE_PORT="$(kubectl get service "$SERVICE" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || true)"
TARGET_PORT="$(kubectl get service "$SERVICE" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].targetPort}' 2>/dev/null || true)"
ENDPOINTS="$(kubectl get endpoints "$SERVICE" -n "$NAMESPACE" -o jsonpath='{range .subsets[*].addresses[*]}{.ip}{" "}{end}' 2>/dev/null || true)"
log "Service type=$SERVICE_TYPE port=$SERVICE_PORT targetPort=$TARGET_PORT"
log "Endpoints=${ENDPOINTS:-ausentes}"
[[ "$SERVICE_TYPE" == "ClusterIP" ]] && pass "Service permanece interno (ClusterIP)" || warn "Service type atual=$SERVICE_TYPE"
[[ -n "$ENDPOINTS" ]] && pass "Service possui endpoint pronto" || fail "Service sem endpoints"

section "7. EVENTOS E ESTADOS PROBLEMATICOS"
BAD_PODS="$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '$3 != "Running" && $3 != "Completed" {print}' || true)"
if [[ -z "$BAD_PODS" ]]; then pass "Nenhum pod em estado problematico"; else fail "Pods problematicos: $BAD_PODS"; fi
kubectl get events -n "$NAMESPACE" --sort-by=.lastTimestamp >> "$REPORT" 2>&1 || true
WARNING_EVENTS="$(kubectl get events -n "$NAMESPACE" --field-selector type=Warning --no-headers 2>/dev/null | tail -n 20 || true)"
if [[ -z "$WARNING_EVENTS" ]]; then pass "Nenhum evento Warning atual"; else warn "Eventos Warning encontrados; consulte o relatorio"; printf '%s\n' "$WARNING_EVENTS" >> "$REPORT"; fi

section "8. CONECTIVIDADE COM RDS"
if [[ "$SKIP_RDS_TCP" == "true" ]]; then
  warn "Teste TCP com RDS ignorado por SKIP_RDS_TCP=true"
elif [[ -z "$DB_HOST" || -z "$DB_PORT" ]]; then
  fail "Teste RDS impossivel: DB_HOST/DB_PORT ausentes"
else
  kubectl delete pod "$TCP_POD" -n "$NAMESPACE" --ignore-not-found=true --wait=false >/dev/null 2>&1 || true
  if kubectl run "$TCP_POD" \
      -n "$NAMESPACE" \
      --image="$TCP_TEST_IMAGE" \
      --restart=Never \
      --env="PGCONNECT_TIMEOUT=5" \
      --command -- sh -c "pg_isready -h '$DB_HOST' -p '$DB_PORT'" >> "$REPORT" 2>&1; then
    if kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/"$TCP_POD" -n "$NAMESPACE" --timeout=90s >> "$REPORT" 2>&1; then
      kubectl logs "$TCP_POD" -n "$NAMESPACE" >> "$REPORT" 2>&1 || true
      pass "RDS resolve DNS e aceita conexoes TCP na porta $DB_PORT"
    else
      kubectl describe pod "$TCP_POD" -n "$NAMESPACE" >> "$REPORT" 2>&1 || true
      kubectl logs "$TCP_POD" -n "$NAMESPACE" >> "$REPORT" 2>&1 || true
      fail "Teste TCP com RDS falhou"
    fi
  else
    fail "Nao foi possivel criar pod temporario de teste RDS"
  fi
fi

section "9. ESTADO AWS DO RDS"
if [[ "$SKIP_AWS" == "true" ]]; then
  warn "Testes AWS ignorados por SKIP_AWS=true"
elif aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" --region "$AWS_REGION" --query 'DBInstances[0].{Status:DBInstanceStatus,Endpoint:Endpoint.Address,Port:Endpoint.Port,Public:PubliclyAccessible,Encrypted:StorageEncrypted}' --output json >> "$REPORT" 2>&1; then
  RDS_STATUS="$(aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" --region "$AWS_REGION" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || true)"
  RDS_PUBLIC="$(aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" --region "$AWS_REGION" --query 'DBInstances[0].PubliclyAccessible' --output text 2>/dev/null || true)"
  RDS_ENCRYPTED="$(aws rds describe-db-instances --db-instance-identifier "$RDS_INSTANCE_ID" --region "$AWS_REGION" --query 'DBInstances[0].StorageEncrypted' --output text 2>/dev/null || true)"
  [[ "$RDS_STATUS" == "available" ]] && pass "RDS available" || warn "RDS status=$RDS_STATUS"
  [[ "$RDS_PUBLIC" == "False" || "$RDS_PUBLIC" == "false" ]] && pass "RDS nao e publico" || fail "RDS aparece como publico"
  [[ "$RDS_ENCRYPTED" == "True" || "$RDS_ENCRYPTED" == "true" ]] && pass "RDS criptografado" || fail "RDS sem criptografia confirmada"
else
  warn "Nao foi possivel consultar o RDS pela AWS CLI"
fi

section "10. TESTE HTTP INTERNO"
if [[ "$SKIP_HTTP" == "true" ]]; then
  warn "Teste HTTP ignorado por SKIP_HTTP=true"
elif [[ -z "$SERVICE_PORT" ]]; then
  fail "Service sem porta; port-forward impossivel"
else
  PF_LOG="/tmp/oficina360-port-forward.log"
  kubectl port-forward -n "$NAMESPACE" service/"$SERVICE" "$LOCAL_PORT:$SERVICE_PORT" > "$PF_LOG" 2>&1 &
  PF_PID=$!

  READY_PF=0
  for _ in $(seq 1 20); do
    if grep -q 'Forwarding from' "$PF_LOG" 2>/dev/null; then READY_PF=1; break; fi
    if ! kill -0 "$PF_PID" 2>/dev/null; then break; fi
    sleep 1
  done

  if [[ $READY_PF -eq 1 ]]; then
    pass "Port-forward estabelecido em localhost:$LOCAL_PORT"
    HTTP_CODE="$(curl -sS -o /tmp/oficina360-health-body.txt -w '%{http_code}' --connect-timeout 5 --max-time 20 "http://127.0.0.1:${LOCAL_PORT}${HEALTH_PATH}" || true)"
    log "Health URL: http://127.0.0.1:${LOCAL_PORT}${HEALTH_PATH} codigo=$HTTP_CODE"
    head -c 1000 /tmp/oficina360-health-body.txt >> "$REPORT" 2>/dev/null || true
    log ""
    case "$HTTP_CODE" in
      200|204) pass "Health endpoint respondeu com HTTP $HTTP_CODE" ;;
      401|403) warn "Aplicacao respondeu, mas health exige autenticacao (HTTP $HTTP_CODE)" ;;
      404) warn "Aplicacao respondeu, mas HEALTH_PATH nao existe (HTTP 404)" ;;
      000|'') fail "Aplicacao nao respondeu ao teste HTTP" ;;
      5*) fail "Aplicacao respondeu com erro HTTP $HTTP_CODE" ;;
      *) warn "Health endpoint respondeu HTTP $HTTP_CODE" ;;
    esac

    if [[ -n "$API_PATH" ]]; then
      API_CODE="$(curl -sS -o /tmp/oficina360-api-body.txt -w '%{http_code}' --connect-timeout 5 --max-time 20 "http://127.0.0.1:${LOCAL_PORT}${API_PATH}" || true)"
      log "API URL: http://127.0.0.1:${LOCAL_PORT}${API_PATH} codigo=$API_CODE"
      if [[ "$API_CODE" =~ ^(2|3|4)[0-9][0-9]$ ]]; then pass "Rota de negocio respondeu HTTP $API_CODE"; else fail "Rota de negocio falhou HTTP ${API_CODE:-000}"; fi
    else
      warn "API_PATH nao informado; teste de rota de negocio ignorado"
    fi
  else
    cat "$PF_LOG" >> "$REPORT" 2>/dev/null || true
    fail "Nao foi possivel estabelecer port-forward"
  fi
fi

section "11. LOGS DE INICIALIZACAO"
POD="$(kubectl get pods -n "$NAMESPACE" -l "$APP_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "$POD" ]]; then
  kubectl logs "$POD" -n "$NAMESPACE" --tail=250 2>/dev/null | grep -Ei 'started|hikari|flyway|migration|postgres|database|connection|error|exception|failed' >> "$REPORT" || true
  if kubectl logs "$POD" -n "$NAMESPACE" --tail=250 2>/dev/null | grep -Eqi 'password authentication failed|connection refused|connection timed out|unknown host|flyway validation failed'; then
    fail "Logs contem erro conhecido de banco/inicializacao"
  else
    pass "Nenhum erro conhecido de banco/inicializacao nos ultimos logs"
  fi
else
  fail "Pod da aplicacao nao encontrado para leitura de logs"
fi

section "12. RESUMO"
log "Aprovados: $PASSES"
log "Avisos: $WARNINGS"
log "Erros: $ERRORS"
if [[ "$ERRORS" -eq 0 ]]; then
  log "RESULTADO: APLICACAO APROVADA"
  log "A aplicacao esta pronta para os testes da Lambda e do Kong."
  EXIT_CODE=0
else
  log "RESULTADO: APLICACAO REPROVADA"
  log "Corrija os itens [ERRO] antes de avancar."
  EXIT_CODE=1
fi
log "Relatorio: $REPORT"
exit "$EXIT_CODE"
