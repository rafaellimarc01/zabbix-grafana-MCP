#!/bin/sh
# Prepara e sobe o MCP único do Zabbix e do Grafana (perfil "mcp" do Docker
# Compose) para IAs como Claude e ChatGPT usarem NA PRÓPRIA MÁQUINA.
#
#   ./scripts/mcp-setup.sh           -> cria as credenciais e sobe o MCP
#   ./scripts/mcp-setup.sh config    -> só mostra como configurar os clientes
#   ./scripts/mcp-setup.sh k8s-config -> o mesmo para o MCP no Kubernetes
#                                        (componente kubernetes/components/mcp,
#                                        acessado com make k8s-mcp)
#
# A IA conecta só no mcp-gateway (um endereço, um token). Por trás dele ficam
# os MCPs oficiais do Zabbix e do Grafana, sem porta publicada.
#
# Idempotente. Na primeira vez:
#  - Zabbix (só no 8.0, que traz o MCP oficial): cria o usuário "mcp", somente
#    leitura e só API, e um token de API para ele.
#  - Grafana: cria a service account "mcp" (Viewer) e um token para ela.
#  - Gera o token interno do MCP do Grafana e o token que a IA usa (MCP_TOKEN).
# Os tokens ficam no .env (MCP_TOKEN, ZABBIX_MCP_TOKEN, GRAFANA_MCP_SA_TOKEN e
# GRAFANA_MCP_CLIENT_TOKEN); nas próximas vezes são reaproveitados enquanto
# funcionarem. Para trocar todos, apague essas linhas do .env e rode de novo.
#
# O MCP só escuta em 127.0.0.1 e só lê dados (nenhuma ferramenta de escrita).
# Requer o ambiente rodando (make up), curl, grep e sed.
set -eu
cd "$(dirname "$0")/.."

ENV_FILE=.env
log() { echo "[mcp] $*"; }
die() { echo "[mcp] ERRO: $*" >&2; exit 1; }

MODE=${1:-setup}
if [ "$MODE" = k8s-config ]; then
  # No Kubernetes o token das IAs é o MCP_PASSWORD do secrets.env e o acesso é
  # pelo port-forward do make k8s-mcp (127.0.0.1:8765).
  ENV_FILE=${K8S_SECRETS:-kubernetes/base/secrets.env}
  [ -f "$ENV_FILE" ] || die "não achei o $ENV_FILE; rode make k8s-secrets (com o K8S_OVERLAY do ambiente)"
  MCP_TOKEN=$(sed -n 's/^MCP_PASSWORD=//p' "$ENV_FILE" | tail -n 1)
  [ -n "$MCP_TOKEN" ] || die "MCP_PASSWORD vazio no $ENV_FILE (veja \"MCP no Kubernetes\" no README)"
  load_env() { :; }
else
  [ -f "$ENV_FILE" ] || die "não achei o $ENV_FILE; rode make env e make up"
  command -v curl >/dev/null || die "curl não encontrado"
  # shellcheck source=/dev/null
  load_env() { set -a; . "./$ENV_FILE"; set +a; }
fi
load_env

ZABBIX_API="http://127.0.0.1:${ZABBIX_WEB_PORT:-8080}/api_jsonrpc.php"
GRAFANA="http://127.0.0.1:${GRAFANA_PORT:-3000}"
MCP_URL="http://127.0.0.1:${MCP_PORT:-8765}/mcp"
MCP_NAME=zabbix-grafana
MCP_USER=mcp
TOKEN_NAME=mcp-local

# set_env <VAR> <valor>: grava no .env (troca a linha ou acrescenta), sem sed -i
# (que muda entre GNU e BSD) e mantendo as permissões do arquivo.
set_env() {
  tmp="$ENV_FILE.tmp.$$"
  if grep -q "^$1=" "$ENV_FILE"; then
    sed "s|^$1=.*|$1=$2|" "$ENV_FILE" > "$tmp"
  else
    { cat "$ENV_FILE"; echo "$1=$2"; } > "$tmp"
  fi
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
}

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

# ---- JSON sem jq (mesmas funções do zabbix-init.sh) --------------------------
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

print_config() {
  load_env
  cat <<EOF

==================== Como conectar as IAs (só nesta máquina) ====================

O token abaixo dá acesso de LEITURA ao seu Zabbix e ao seu Grafana. Trate-o
como senha: não cole em chats, prints ou repositórios.

--- Claude Code ---------------------------------------------------------------
claude mcp add --transport http $MCP_NAME $MCP_URL \\
  --header "Authorization: Bearer $MCP_TOKEN"

--- Claude Desktop (precisa do Node.js) ---------------------------------------
Em Settings > Developer > Edit Config, junte isto ao claude_desktop_config.json
e reinicie o Claude Desktop:

{
  "mcpServers": {
    "$MCP_NAME": {
      "command": "npx",
      "args": ["-y", "mcp-remote@0.16.7", "$MCP_URL", "--header", "Authorization:\${AUTH}"],
      "env": {"AUTH": "Bearer $MCP_TOKEN"}
    }
  }
}

--- Outros clientes (Codex, VS Code, Cursor...) -------------------------------
Servidor MCP HTTP (streamable): $MCP_URL
Cabeçalho: Authorization: Bearer <MCP_TOKEN do .env>
EOF
  if [ "$MODE" = k8s-config ]; then
    echo "Antes de usar, deixe rodando em outro terminal: make k8s-mcp"
  elif [ -z "${ZABBIX_MCP_TOKEN:-}" ]; then
    echo "(As ferramentas zabbix_* precisam do Zabbix 8.0; veja \"Zabbix 8.0\" no README.)"
  fi
  echo
  if [ "$MODE" = k8s-config ]; then echo "Para ver isto de novo: make k8s-mcp-config"; else echo "Para ver isto de novo: make mcp-config"; fi
}

if [ "$MODE" = k8s-config ]; then
  print_config
  exit 0
fi
if [ "$MODE" = config ]; then
  [ -n "${MCP_TOKEN:-}" ] || die "o MCP ainda não foi configurado; rode make mcp"
  print_config
  exit 0
fi

# ---- Ambiente no ar? ----------------------------------------------------------
VERSION=$(result "$(zcall apiinfo.version '{}' 2>/dev/null || true)")
[ -n "$VERSION" ] || die "a API do Zabbix não respondeu em $ZABBIX_API; suba o ambiente com make up"
curl -fsS "$GRAFANA/api/health" >/dev/null 2>&1 || die "o Grafana não respondeu em $GRAFANA; suba o ambiente com make up"
log "Zabbix $VERSION e Grafana no ar"

# ---- Zabbix: usuário mcp + token de API (só 8.0) -----------------------------
SERVICES="grafana-mcp mcp-gateway"
case $VERSION in
  8.*)
    SERVICES="zabbix-mcp grafana-mcp mcp-gateway"
    # Token atual ainda vale? (checkAuthentication devolve o usuário dono dele)
    CHECK=""
    [ -z "${ZABBIX_MCP_TOKEN:-}" ] || CHECK=$(zcall user.checkAuthentication "{\"token\":$(str "$ZABBIX_MCP_TOKEN")}" 2>/dev/null || true)
    if [ "$(field "$CHECK" username)" = "$MCP_USER" ]; then
      log "Zabbix: token do usuário '$MCP_USER' já configurado"
    else
      ADMIN=$(result "$(zcall user.login "{\"username\":\"Admin\",\"password\":$(str "$ZABBIX_ADMIN_PASSWORD")}")")
      [ -n "$ADMIN" ] || die "Zabbix: não consegui entrar como Admin com a senha do .env"
      # Mesmo grupo e perfil somente leitura que o zabbix-init criou para o Grafana.
      GROUPID=$(field "$(zcall usergroup.get '{"filter":{"name":"Grafana (somente leitura)"},"output":["usrgrpid"]}' "$ADMIN")" usrgrpid)
      ROLEID=$(field "$(zcall role.get '{"filter":{"name":"Grafana (somente leitura)"},"output":["roleid"]}' "$ADMIN")" roleid)
      [ -n "$GROUPID" ] && [ -n "$ROLEID" ] || die "Zabbix: grupo/perfil 'Grafana (somente leitura)' não existe; rode docker compose up zabbix-init"
      USERID=$(field "$(zcall user.get "{\"filter\":{\"username\":\"$MCP_USER\"},\"output\":[\"userid\"]}" "$ADMIN")" userid)
      if [ -z "$USERID" ]; then
        # Senha aleatória que ninguém usa: o acesso é só pelo token de API, e o
        # grupo não entra na interface web.
        RESP=$(zcall user.create "{\"username\":\"$MCP_USER\",\"name\":\"MCP (IAs)\",\"passwd\":\"$(random_password)\",\"roleid\":\"$ROLEID\",\"usrgrps\":[{\"usrgrpid\":\"$GROUPID\"}]}" "$ADMIN")
        zcheck "$RESP" "criar o usuário '$MCP_USER'"
        USERID=$(printf '%s' "$RESP" | sed -n 's/^.*"userids":\["\([0-9]*\)".*$/\1/p')
        log "Zabbix: usuário '$MCP_USER' (somente leitura) criado"
      fi
      # Um token por nome: apaga o anterior (se houver) e cria outro.
      for id in $(zcall token.get "{\"userids\":[\"$USERID\"],\"filter\":{\"name\":\"$TOKEN_NAME\"},\"output\":[\"tokenid\"]}" "$ADMIN" | grep -o '"tokenid":"[0-9]*"' | cut -d '"' -f 4); do
        zcheck "$(zcall token.delete "[\"$id\"]" "$ADMIN")" "apagar o token antigo"
      done
      RESP=$(zcall token.create "{\"name\":\"$TOKEN_NAME\",\"userid\":\"$USERID\",\"description\":\"MCP local (make mcp)\"}" "$ADMIN")
      zcheck "$RESP" "criar o token de API"
      TID=$(printf '%s' "$RESP" | sed -n 's/^.*"tokenids":\["\([0-9]*\)".*$/\1/p')
      RESP=$(zcall token.generate "[\"$TID\"]" "$ADMIN")
      zcheck "$RESP" "gerar o token de API"
      set_env ZABBIX_MCP_TOKEN "$(field "$RESP" token)"
      zcall user.logout '{}' "$ADMIN" >/dev/null 2>&1 || true
      log "Zabbix: token de API do usuário '$MCP_USER' criado (ZABBIX_MCP_TOKEN no .env)"
    fi
    ;;
  *)
    log "Zabbix $VERSION: o MCP oficial do Zabbix só existe a partir do 8.0; o MCP terá só as ferramentas do Grafana"
    log "para ter as do Zabbix também, atualize com make upgrade-8 (veja \"Zabbix 8.0\" no README)"
    # Sem MCP do Zabbix, o gateway não deve tentar usá-lo.
    [ -z "${ZABBIX_MCP_TOKEN:-}" ] || set_env ZABBIX_MCP_TOKEN ""
    ;;
esac

# ---- Grafana: service account mcp (Viewer) + token ---------------------------
if [ -n "${GRAFANA_MCP_SA_TOKEN:-}" ] && curl -fsS -H "Authorization: Bearer $GRAFANA_MCP_SA_TOKEN" "$GRAFANA/api/user" >/dev/null 2>&1; then
  log "Grafana: token da service account '$MCP_USER' já configurado"
else
  RESP=$(gcall GET "/api/serviceaccounts/search?query=$MCP_USER")
  SAID=$(num "$(printf '%s' "$RESP" | grep -o "{[^{}]*\"name\":\"$MCP_USER\"[^{}]*}" | head -n 1)" id)
  if [ -z "$SAID" ]; then
    SAID=$(num "$(gcall POST /api/serviceaccounts "{\"name\":\"$MCP_USER\",\"role\":\"Viewer\"}")" id)
    [ -n "$SAID" ] || die "Grafana: não consegui criar a service account '$MCP_USER'"
    log "Grafana: service account '$MCP_USER' (Viewer) criada"
  fi
  for obj in $(gcall GET "/api/serviceaccounts/$SAID/tokens" | grep -o "{[^{}]*\"name\":\"$TOKEN_NAME\"[^{}]*}" | tr -d ' '); do
    id=$(num "$obj" id)
    gcall DELETE "/api/serviceaccounts/$SAID/tokens/$id" >/dev/null
  done
  KEY=$(field "$(gcall POST "/api/serviceaccounts/$SAID/tokens" "{\"name\":\"$TOKEN_NAME\"}")" key)
  [ -n "$KEY" ] || die "Grafana: não consegui criar o token da service account"
  set_env GRAFANA_MCP_SA_TOKEN "$KEY"
  log "Grafana: token da service account '$MCP_USER' criado (GRAFANA_MCP_SA_TOKEN no .env)"
fi
if [ -z "${GRAFANA_MCP_CLIENT_TOKEN:-}" ]; then
  set_env GRAFANA_MCP_CLIENT_TOKEN "$(random_token)"
  log "token interno do MCP do Grafana gerado (GRAFANA_MCP_CLIENT_TOKEN no .env)"
fi
if [ -z "${MCP_TOKEN:-}" ]; then
  set_env MCP_TOKEN "$(random_token)"
  log "token da IA gerado (MCP_TOKEN no .env)"
fi

# ---- Sobe os MCPs --------------------------------------------------------------
# Recarrega o .env: as variáveis exportadas no início (vazias na primeira vez)
# têm prioridade sobre o .env no docker compose e deixariam os MCPs sem token.
load_env
[ -n "${MCP_TOKEN:-}" ] && [ -n "${GRAFANA_MCP_CLIENT_TOKEN:-}" ] && [ -n "${GRAFANA_MCP_SA_TOKEN:-}" ] \
  || die "tokens vazios no $ENV_FILE"
log "subindo: $SERVICES"
docker compose --profile mcp build -q mcp-gateway
# A versão anterior publicava os MCPs oficiais em 127.0.0.1; recriar tira as portas.
# shellcheck disable=SC2086 # lista de serviços
docker compose --profile mcp up -d --no-deps --force-recreate $SERVICES
case $SERVICES in *zabbix-mcp*) ;; *) docker compose --profile mcp rm -sf zabbix-mcp >/dev/null 2>&1 || true ;; esac

# O MCP tem de recusar quem não manda o token, e responder a quem manda.
mcp_post() { # mcp_post <json> [token] -> imprime o código HTTP
  curl -s -o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' ${2:+-H "Authorization: Bearer $2"} -d "$1" "$MCP_URL"
}
i=0
until code=$(mcp_post '{"jsonrpc":"2.0","id":1,"method":"ping"}') && [ "$code" != 000 ]; do
  i=$((i + 1)); [ "$i" -ge 30 ] && die "o MCP não respondeu em $MCP_URL; veja docker compose --profile mcp logs mcp-gateway"
  sleep 1
done
if [ "$code" != 401 ]; then
  docker compose --profile mcp stop mcp-gateway
  die "o MCP aceitou um pedido sem token (HTTP $code); ele foi parado"
fi
[ "$(mcp_post '{"jsonrpc":"2.0","id":1,"method":"ping"}' "$MCP_TOKEN")" = 200 ] || die "o MCP recusou o MCP_TOKEN; veja docker compose --profile mcp logs mcp-gateway"
log "MCP no ar em $MCP_URL (só nesta máquina)"
print_config
