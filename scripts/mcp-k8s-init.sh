#!/bin/sh
# Init container do pod "mcp" no Kubernetes (componente kubernetes/components/mcp).
# Faz o mesmo que o "make mcp" do Docker Compose, mas a cada start do pod:
#  - Zabbix (só no 8.0, que traz o MCP oficial): garante o usuário "mcp",
#    somente leitura e só API, e cria um token de API novo para ele.
#  - Grafana: garante a service account "mcp" (Viewer) e cria um token novo.
#  - Gera o token interno do MCP do Grafana.
# Os tokens vão para arquivos em $OUT (um emptyDir em memória, só deste pod) e
# os tokens antigos com o mesmo nome são apagados: nada fica guardado no
# cluster e um pod novo sempre começa com tokens novos.
#
# Variáveis: ZABBIX_URL, ZABBIX_ADMIN_PASSWORD, GRAFANA_URL, GRAFANA_ADMIN_USER,
# GRAFANA_ADMIN_PASSWORD e OUT (padrão /run/mcp). Requer curl, grep e sed.
set -eu

OUT=${OUT:-/run/mcp}
ZABBIX_API="${ZABBIX_URL:-http://zabbix-web:8080}/api_jsonrpc.php"
GRAFANA=${GRAFANA_URL:-http://grafana:3000}
MCP_USER=mcp
TOKEN_NAME=mcp-k8s
ROLE="Grafana (somente leitura)"

log() { echo "[mcp-init] $*"; }
die() { echo "[mcp-init] ERRO: $*" >&2; exit 1; }

random_token() {
  while :; do
    t=$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 40)
    [ "${#t}" -eq 40 ] && { echo "$t"; return; }
  done
}
# Senha do usuário "mcp" do Zabbix: o Zabbix recusa senhas que contêm o nome,
# o usuário ou palavras como "zabbix" e "admin" (de vez em quando um token
# aleatório contém "mcp" ou "ias", de "MCP (IAs)").
random_password() {
  while :; do
    t=$(random_token)
    printf '%s' "$t" | grep -qiE 'mcp|ias|zabbix|admin' || { echo "$t"; return; }
  done
}
# Os outros containers do pod rodam com outros usuários e precisam ler os
# arquivos; o volume só existe dentro deste pod.
write_token() { (umask 022; printf '%s' "$2" > "$OUT/$1"); }

# ---- JSON sem jq (mesmas funções do mcp-setup.sh) ----------------------------
str() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; }
field() { printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -n 1 | cut -d '"' -f 4; }
num() { printf '%s' "$1" | grep -o "\"$2\":[0-9]*" | head -n 1 | cut -d : -f 2; }
result() { printf '%s' "$1" | sed -n 's/^.*"result":"\([^"]*\)".*$/\1/p'; }
zcall() {
  curl -fsS -H 'Content-Type: application/json-rpc' ${3:+-H "Authorization: Bearer $3"} \
    -d "{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":$2,\"id\":1}" "$ZABBIX_API"
}
zcheck() {
  case $1 in *'"error":{'*) die "Zabbix: falha ao $2: $(printf '%s' "$1" | sed -n 's/^.*"data":"\(.*\)".*$/\1/p')" ;; esac
}
gcall() { # gcall <método> <caminho> [json]
  curl -fsS -u "$GRAFANA_ADMIN_USER:$GRAFANA_ADMIN_PASSWORD" -H 'Content-Type: application/json' \
    -X "$1" ${3:+-d "$3"} "$GRAFANA$2"
}

mkdir -p "$OUT"
: > "$OUT/zabbix-token"

# ---- Espera o Zabbix e o Grafana (até 10 minutos) -----------------------------
i=0
until VERSION=$(result "$(zcall apiinfo.version '{}' 2>/dev/null)") && [ -n "$VERSION" ] \
    && curl -fsS "$GRAFANA/api/health" >/dev/null 2>&1; do
  i=$((i + 1)); [ "$i" -ge 120 ] && die "o Zabbix ($ZABBIX_API) ou o Grafana ($GRAFANA) não responderam"
  sleep 5
done
log "Zabbix $VERSION e Grafana no ar"

# ---- Zabbix: usuário mcp + token de API (só 8.0) -----------------------------
case $VERSION in
  8.*)
    ADMIN=$(result "$(zcall user.login "{\"username\":\"Admin\",\"password\":$(str "$ZABBIX_ADMIN_PASSWORD")}")")
    [ -n "$ADMIN" ] || die "Zabbix: não consegui entrar como Admin com a senha do secrets.env"
    # Grupo e perfil somente leitura criados pelo zabbix-init (init container do
    # Grafana), que pode ainda estar rodando.
    i=0
    while :; do
      GROUPID=$(field "$(zcall usergroup.get "{\"filter\":{\"name\":$(str "$ROLE")},\"output\":[\"usrgrpid\"]}" "$ADMIN")" usrgrpid)
      ROLEID=$(field "$(zcall role.get "{\"filter\":{\"name\":$(str "$ROLE")},\"output\":[\"roleid\"]}" "$ADMIN")" roleid)
      [ -n "$GROUPID" ] && [ -n "$ROLEID" ] && break
      i=$((i + 1)); [ "$i" -ge 60 ] && die "Zabbix: grupo/perfil '$ROLE' não existe; veja os logs do init container zabbix-init do Grafana"
      sleep 5
    done
    USERID=$(field "$(zcall user.get "{\"filter\":{\"username\":\"$MCP_USER\"},\"output\":[\"userid\"]}" "$ADMIN")" userid)
    if [ -z "$USERID" ]; then
      # Senha aleatória que ninguém usa: o acesso é só pelo token de API.
      RESP=$(zcall user.create "{\"username\":\"$MCP_USER\",\"name\":\"MCP (IAs)\",\"passwd\":\"$(random_password)\",\"roleid\":\"$ROLEID\",\"usrgrps\":[{\"usrgrpid\":\"$GROUPID\"}]}" "$ADMIN")
      zcheck "$RESP" "criar o usuário '$MCP_USER'"
      USERID=$(printf '%s' "$RESP" | sed -n 's/^.*"userids":\["\([0-9]*\)".*$/\1/p')
      log "Zabbix: usuário '$MCP_USER' (somente leitura) criado"
    fi
    for id in $(zcall token.get "{\"userids\":[\"$USERID\"],\"filter\":{\"name\":\"$TOKEN_NAME\"},\"output\":[\"tokenid\"]}" "$ADMIN" | grep -o '"tokenid":"[0-9]*"' | cut -d '"' -f 4); do
      zcheck "$(zcall token.delete "[\"$id\"]" "$ADMIN")" "apagar o token antigo"
    done
    RESP=$(zcall token.create "{\"name\":\"$TOKEN_NAME\",\"userid\":\"$USERID\",\"description\":\"MCP no Kubernetes (pod mcp)\"}" "$ADMIN")
    zcheck "$RESP" "criar o token de API"
    TID=$(printf '%s' "$RESP" | sed -n 's/^.*"tokenids":\["\([0-9]*\)".*$/\1/p')
    RESP=$(zcall token.generate "[\"$TID\"]" "$ADMIN")
    zcheck "$RESP" "gerar o token de API"
    write_token zabbix-token "$(field "$RESP" token)"
    zcall user.logout '{}' "$ADMIN" >/dev/null 2>&1 || true
    log "Zabbix: token de API novo para o usuário '$MCP_USER'"
    ;;
  *)
    log "Zabbix $VERSION: o MCP oficial do Zabbix só existe a partir do 8.0; só as ferramentas do Grafana e do Kubernetes ficam ativas"
    ;;
esac

# ---- Grafana: service account mcp (Viewer) + token ---------------------------
RESP=$(gcall GET "/api/serviceaccounts/search?query=$MCP_USER")
SAID=$(num "$(printf '%s' "$RESP" | grep -o "{[^{}]*\"name\":\"$MCP_USER\"[^{}]*}" | head -n 1)" id)
if [ -z "$SAID" ]; then
  SAID=$(num "$(gcall POST /api/serviceaccounts "{\"name\":\"$MCP_USER\",\"role\":\"Viewer\"}")" id)
  [ -n "$SAID" ] || die "Grafana: não consegui criar a service account '$MCP_USER'"
  log "Grafana: service account '$MCP_USER' (Viewer) criada"
fi
for obj in $(gcall GET "/api/serviceaccounts/$SAID/tokens" | grep -o "{[^{}]*\"name\":\"$TOKEN_NAME\"[^{}]*}" | tr -d ' '); do
  gcall DELETE "/api/serviceaccounts/$SAID/tokens/$(num "$obj" id)" >/dev/null
done
KEY=$(field "$(gcall POST "/api/serviceaccounts/$SAID/tokens" "{\"name\":\"$TOKEN_NAME\"}")" key)
[ -n "$KEY" ] || die "Grafana: não consegui criar o token da service account"
write_token grafana-sa-token "$KEY"
write_token grafana-client-token "$(random_token)"
log "Grafana: token novo para a service account '$MCP_USER'"
