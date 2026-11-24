#!/bin/sh
# Configuração inicial do Zabbix via API (idempotente).
#  1. Troca a senha padrão do usuário Admin ("zabbix") por ZABBIX_ADMIN_PASSWORD.
#  2. Aponta a interface do host "Zabbix server" para o DNS do agente
#     (por padrão ela vem como 127.0.0.1, que não funciona em containers).
# Requer: curl e jq.
set -eu

ZABBIX_URL="${ZABBIX_URL:-http://zabbix-web:8080}"
API="${ZABBIX_URL%/}/api_jsonrpc.php"
NEW_PASSWORD="${ZABBIX_ADMIN_PASSWORD:?ZABBIX_ADMIN_PASSWORD não definido}"
AGENT_DNS="${ZABBIX_AGENT_DNS:-zabbix-agent}"
DEFAULT_PASSWORD="zabbix"

log() { echo "[zabbix-init] $*"; }

# call <método> <params-json> [token]
call() {
  body=$(jq -nc --arg m "$1" --argjson p "$2" '{jsonrpc:"2.0",method:$m,params:$p,id:1}')
  if [ -n "${3:-}" ]; then
    curl -fsS -H 'Content-Type: application/json-rpc' -H "Authorization: Bearer $3" -d "$body" "$API"
  else
    curl -fsS -H 'Content-Type: application/json-rpc' -d "$body" "$API"
  fi
}

# check <resposta-json> <descrição>: aborta mostrando o erro da API, se houver.
check() {
  if echo "$1" | jq -e '.error' >/dev/null; then
    log "falha ao $2: $(echo "$1" | jq -r '.error.data // .error.message')"
    exit 1
  fi
}

login() {
  call user.login "$(jq -nc --arg p "$1" '{username:"Admin",password:$p}')" | jq -r '.result // empty'
}

log "aguardando a API em $API ..."
i=0
until call apiinfo.version '{}' 2>/dev/null | jq -e '.result' >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -ge 60 ] && { log "API não respondeu"; exit 1; }
  sleep 5
done
log "API do Zabbix $(call apiinfo.version '{}' | jq -r .result) disponível"

# Login: tenta a senha padrão primeiro (primeira execução) e depois a nova.
# Nessa ordem há no máximo 1 tentativa falha por rodada, o que evita o
# bloqueio temporário do Admin após várias falhas seguidas.
# No primeiro start o zabbix-server ainda está criando o banco, então repete.
i=0
while :; do
  TOKEN=$(login "$DEFAULT_PASSWORD" 2>/dev/null || true)
  USING_DEFAULT=1
  if [ -z "$TOKEN" ]; then
    TOKEN=$(login "$NEW_PASSWORD" 2>/dev/null || true)
    USING_DEFAULT=0
  fi
  [ -n "$TOKEN" ] && break
  i=$((i + 1))
  [ "$i" -ge 60 ] && { log "não foi possível autenticar como Admin"; exit 1; }
  log "banco ainda inicializando, tentando login de novo em 5s ..."
  sleep 5
done

if [ "$USING_DEFAULT" = 1 ]; then
  if [ "$NEW_PASSWORD" != "$DEFAULT_PASSWORD" ]; then
    USERID=$(call user.get '{"filter":{"username":"Admin"},"output":["userid"]}' "$TOKEN" | jq -r '.result[0].userid')
    RESP=$(call user.update "$(jq -nc --arg id "$USERID" --arg new "$NEW_PASSWORD" --arg cur "$DEFAULT_PASSWORD" \
      '{userid:$id,passwd:$new,current_passwd:$cur}')" "$TOKEN")
    check "$RESP" "trocar a senha do Admin (a senha não pode conter 'Admin' nem 'Zabbix' e precisa ter 8+ caracteres)"
    log "senha do Admin alterada"
    TOKEN=$(login "$NEW_PASSWORD")
  fi
else
  log "senha do Admin já configurada"
fi

IFACE=$(call host.get '{"filter":{"host":["Zabbix server"]},"selectInterfaces":["interfaceid","type","useip","dns"],"output":["hostid"]}' "$TOKEN" \
  | jq -c '.result[0].interfaces[]? | select(.type=="1")')
if [ -n "$IFACE" ]; then
  IFACE_ID=$(echo "$IFACE" | jq -r .interfaceid)
  if [ "$(echo "$IFACE" | jq -r '.useip + ":" + .dns')" != "0:$AGENT_DNS" ]; then
    RESP=$(call hostinterface.update "$(jq -nc --arg id "$IFACE_ID" --arg dns "$AGENT_DNS" '{interfaceid:$id,useip:0,dns:$dns}')" "$TOKEN")
    check "$RESP" "atualizar a interface do host 'Zabbix server'"
    log "host 'Zabbix server' agora usa o agente em $AGENT_DNS:10050"
  else
    log "interface do host 'Zabbix server' já aponta para $AGENT_DNS"
  fi
fi

call user.logout '{}' "$TOKEN" >/dev/null 2>&1 || true
log "concluído"
