#!/bin/sh
# Configuração inicial do Zabbix via API (idempotente). Funciona no Zabbix 7.0
# e no 8.0.
#  1. Troca a senha padrão do usuário Admin ("zabbix") por ZABBIX_ADMIN_PASSWORD.
#  2. Cria/atualiza o usuário "grafana": só leitura, só API (sem acesso à
#     interface web), usado pelo datasource do Grafana no lugar do Admin.
#     Ele usa um perfil (role) próprio com acesso à API ligado, porque no
#     Zabbix 8.0 o "User role" padrão vem sem acesso à API.
#  3. Aponta a interface do host "Zabbix server" para o DNS do agente
#     (por padrão ela vem como 127.0.0.1, que não funciona em containers).
# Requer só sh, curl, grep, sed e cut. Não usa jq, porque a imagem do
# zabbix-web 8.0 não traz jq (a 7.0 trazia).
set -eu

ZABBIX_URL="${ZABBIX_URL:-http://zabbix-web:8080}"
API="${ZABBIX_URL%/}/api_jsonrpc.php"
NEW_PASSWORD="${ZABBIX_ADMIN_PASSWORD:?ZABBIX_ADMIN_PASSWORD não definido}"
GRAFANA_USER="${ZABBIX_GRAFANA_USER:-grafana}"
GRAFANA_PASSWORD="${ZABBIX_GRAFANA_PASSWORD:?ZABBIX_GRAFANA_PASSWORD não definido}"
GRAFANA_GROUP="Grafana (somente leitura)"
GRAFANA_ROLE="Grafana (somente leitura)"
AGENT_DNS="${ZABBIX_AGENT_DNS:-zabbix-agent}"
DEFAULT_PASSWORD="zabbix"

log() { echo "[zabbix-init] $*"; }

# Recusa senhas fracas antes de tocar no Zabbix.
if [ "${#NEW_PASSWORD}" -lt 8 ] || echo "$NEW_PASSWORD" | grep -qiE 'admin|zabbix'; then
  log "ZABBIX_ADMIN_PASSWORD precisa ter 8+ caracteres e não pode conter 'Admin' nem 'Zabbix'"
  exit 1
fi
if [ "${#GRAFANA_PASSWORD}" -lt 8 ]; then
  log "ZABBIX_GRAFANA_PASSWORD precisa ter 8+ caracteres"
  exit 1
fi

# ---- JSON sem jq --------------------------------------------------------------
# A API do Zabbix responde JSON compacto (sem espaços), o que permite extrair
# campos simples com grep/sed. Só lemos ids, números e nomes que nós mesmos
# controlamos.

# str <texto>: texto como string JSON (escapa \ e ").
str() { printf '"%s"' "$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"; }

# field <json> <campo>: valor do primeiro "campo":"valor" encontrado.
field() { printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | head -n 1 | cut -d '"' -f 4; }

# fields <json> <campo>: todos os valores de "campo", um por linha.
fields() { printf '%s' "$1" | grep -o "\"$2\":\"[^\"]*\"" | cut -d '"' -f 4; }

# result <json>: o "result" quando ele é uma string (login, versão).
result() { printf '%s' "$1" | sed -n 's/^.*"result":"\([^"]*\)".*$/\1/p'; }

# call <método> <params-json> [token]
call() {
  body="{\"jsonrpc\":\"2.0\",\"method\":\"$1\",\"params\":$2,\"id\":1}"
  if [ -n "${3:-}" ]; then
    curl -fsS -H 'Content-Type: application/json-rpc' -H "Authorization: Bearer $3" -d "$body" "$API"
  else
    curl -fsS -H 'Content-Type: application/json-rpc' -d "$body" "$API"
  fi
}

# check <resposta-json> <descrição>: aborta mostrando o erro da API, se houver.
check() {
  case $1 in
    *'"error":{'*)
      msg=$(field "$1" data)
      [ -n "$msg" ] || msg=$(field "$1" message)
      log "falha ao $2: $msg"
      exit 1
      ;;
  esac
}

# login <senha> [usuário]
login() {
  result "$(call user.login "{\"username\":$(str "${2:-Admin}"),\"password\":$(str "$1")}")"
}

log "aguardando a API em $API ..."
i=0
until VERSION=$(result "$(call apiinfo.version '{}' 2>/dev/null)") && [ -n "$VERSION" ]; do
  i=$((i + 1))
  [ "$i" -ge 60 ] && { log "API não respondeu"; exit 1; }
  sleep 5
done
log "API do Zabbix $VERSION disponível"

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
    USERID=$(field "$(call user.get '{"filter":{"username":"Admin"},"output":["userid"]}' "$TOKEN")" userid)
    RESP=$(call user.update "{\"userid\":\"$USERID\",\"passwd\":$(str "$NEW_PASSWORD"),\"current_passwd\":$(str "$DEFAULT_PASSWORD")}" "$TOKEN")
    check "$RESP" "trocar a senha do Admin (a senha não pode conter 'Admin' nem 'Zabbix' e precisa ter 8+ caracteres)"
    log "senha do Admin alterada"
    TOKEN=$(login "$NEW_PASSWORD")
  fi
else
  log "senha do Admin já configurada"
fi

# ---- Usuário somente leitura para o Grafana ---------------------------------
# Grupo de usuários sem acesso à interface web (gui_access=3), com permissão de
# leitura em todos os grupos de hosts que existem agora. Rodar o init de novo
# inclui grupos de hosts criados depois.
RIGHTS=""
for id in $(fields "$(call hostgroup.get '{"output":["groupid"]}' "$TOKEN")" groupid); do
  RIGHTS="${RIGHTS:+$RIGHTS,}{\"id\":\"$id\",\"permission\":2}"
done
GROUPID=$(field "$(call usergroup.get "{\"filter\":{\"name\":$(str "$GRAFANA_GROUP")},\"output\":[\"usrgrpid\"]}" "$TOKEN")" usrgrpid)
if [ -z "$GROUPID" ]; then
  RESP=$(call usergroup.create "{\"name\":$(str "$GRAFANA_GROUP"),\"gui_access\":3,\"hostgroup_rights\":[$RIGHTS]}" "$TOKEN")
  check "$RESP" "criar o grupo de usuários '$GRAFANA_GROUP'"
  GROUPID=$(printf '%s' "$RESP" | sed -n 's/^.*"usrgrpids":\["\([0-9]*\)".*$/\1/p')
  log "grupo '$GRAFANA_GROUP' criado"
else
  RESP=$(call usergroup.update "{\"usrgrpid\":\"$GROUPID\",\"gui_access\":3,\"hostgroup_rights\":[$RIGHTS]}" "$TOKEN")
  check "$RESP" "atualizar o grupo de usuários '$GRAFANA_GROUP'"
fi

# Perfil do tipo "User" (type 1: só leitura, nunca edita configuração), sem
# nenhuma tela da interface e com acesso à API. api.mode 0 com lista vazia =
# todos os métodos, limitados pelo tipo User e pelas permissões do grupo.
ROLE_RULES='{"ui.default_access":"0","modules.default_access":"0","actions.default_access":"0","api.access":"1","api.mode":"0","api":[]}'
ROLEID=$(field "$(call role.get "{\"filter\":{\"name\":$(str "$GRAFANA_ROLE")},\"output\":[\"roleid\"]}" "$TOKEN")" roleid)
if [ -z "$ROLEID" ]; then
  RESP=$(call role.create "{\"name\":$(str "$GRAFANA_ROLE"),\"type\":\"1\",\"rules\":$ROLE_RULES}" "$TOKEN")
  check "$RESP" "criar o perfil '$GRAFANA_ROLE'"
  ROLEID=$(printf '%s' "$RESP" | sed -n 's/^.*"roleids":\["\([0-9]*\)".*$/\1/p')
  log "perfil '$GRAFANA_ROLE' criado"
else
  RESP=$(call role.update "{\"roleid\":\"$ROLEID\",\"type\":\"1\",\"rules\":$ROLE_RULES}" "$TOKEN")
  check "$RESP" "atualizar o perfil '$GRAFANA_ROLE'"
fi
[ -n "$ROLEID" ] || { log "perfil '$GRAFANA_ROLE' não encontrado"; exit 1; }

GUSERID=$(field "$(call user.get "{\"filter\":{\"username\":$(str "$GRAFANA_USER")},\"output\":[\"userid\"]}" "$TOKEN")" userid)
if [ -z "$GUSERID" ]; then
  RESP=$(call user.create "{\"username\":$(str "$GRAFANA_USER"),\"passwd\":$(str "$GRAFANA_PASSWORD"),\"roleid\":\"$ROLEID\",\"usrgrps\":[{\"usrgrpid\":\"$GROUPID\"}]}" "$TOKEN")
  check "$RESP" "criar o usuário '$GRAFANA_USER'"
  log "usuário '$GRAFANA_USER' (somente leitura) criado"
else
  # Só troca a senha se a atual não funcionar (evita derrubar sessões à toa).
  PARAMS="\"userid\":\"$GUSERID\",\"roleid\":\"$ROLEID\",\"usrgrps\":[{\"usrgrpid\":\"$GROUPID\"}]"
  # O login com a senha atual só funciona se o perfil já tiver acesso à API;
  # por isso o perfil é ajustado antes (bloco acima).
  RESP=$(call user.update "{$PARAMS}" "$TOKEN")
  check "$RESP" "atualizar o usuário '$GRAFANA_USER'"
  GTOKEN=$(login "$GRAFANA_PASSWORD" "$GRAFANA_USER" 2>/dev/null || true)
  if [ -n "$GTOKEN" ]; then
    call user.logout '{}' "$GTOKEN" >/dev/null 2>&1 || true
  else
    RESP=$(call user.update "{$PARAMS,\"passwd\":$(str "$GRAFANA_PASSWORD")}" "$TOKEN")
    check "$RESP" "atualizar a senha do usuário '$GRAFANA_USER'"
    log "senha do usuário '$GRAFANA_USER' atualizada"
  fi
fi

# ---- Interface do host "Zabbix server" --------------------------------------
HOSTID=$(field "$(call host.get '{"filter":{"host":["Zabbix server"]},"output":["hostid"]}' "$TOKEN")" hostid)
if [ -n "$HOSTID" ]; then
  IFACES=$(call hostinterface.get "{\"hostids\":[\"$HOSTID\"],\"output\":[\"interfaceid\",\"type\",\"useip\",\"dns\"]}" "$TOKEN")
  # Interface do agente (type 1).
  IFACE=$(printf '%s' "$IFACES" | grep -o '{[^{}]*"type":"1"[^{}]*}' | head -n 1)
  if [ -n "$IFACE" ]; then
    IFACE_ID=$(field "$IFACE" interfaceid)
    if [ "$(field "$IFACE" useip):$(field "$IFACE" dns)" = "0:$AGENT_DNS" ]; then
      log "interface do host 'Zabbix server' já aponta para $AGENT_DNS"
    else
      NEW_IFACE="{\"interfaceid\":\"$IFACE_ID\",\"useip\":0,\"dns\":$(str "$AGENT_DNS")}"
      RESP=$(call hostinterface.update "$NEW_IFACE" "$TOKEN")
      case $RESP in
        *'"code":-32601'*)
          # Zabbix 8.0 removeu hostinterface.update: as interfaces passam a ser
          # alteradas pelo host.update, que substitui a lista inteira. Só
          # fazemos isso com uma única interface (a de fábrica), para nunca
          # apagar interfaces que o usuário tenha criado.
          if [ "$(fields "$IFACES" interfaceid | wc -l)" -ne 1 ]; then
            log "o host 'Zabbix server' tem mais de uma interface; aponte a do agente para $AGENT_DNS na interface web"
          else
            RESP=$(call host.update "{\"hostid\":\"$HOSTID\",\"interfaces\":[{\"interfaceid\":\"$IFACE_ID\",\"type\":1,\"main\":1,\"useip\":0,\"ip\":\"\",\"dns\":$(str "$AGENT_DNS"),\"port\":\"10050\"}]}" "$TOKEN")
            check "$RESP" "atualizar a interface do host 'Zabbix server'"
            log "host 'Zabbix server' agora usa o agente em $AGENT_DNS:10050"
          fi
          ;;
        *)
          check "$RESP" "atualizar a interface do host 'Zabbix server'"
          log "host 'Zabbix server' agora usa o agente em $AGENT_DNS:10050"
          ;;
      esac
    fi
  fi
fi

call user.logout '{}' "$TOKEN" >/dev/null 2>&1 || true
log "concluído"
