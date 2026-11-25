#!/bin/sh
# Atualiza um ambiente Docker Compose do Zabbix 7.0 LTS para o 8.0 LTS.
#
#   ./scripts/upgrade-zabbix-8.sh            -> atualiza (pede confirmação)
#   ./scripts/upgrade-zabbix-8.sh --yes      -> atualiza sem perguntar (CI)
#   ./scripts/upgrade-zabbix-8.sh --rollback ARQUIVO.dump [--yes]
#                                            -> volta para o 7.0 restaurando o
#                                               backup feito antes da atualização
#
# O que a atualização faz:
#  1. Confere se o .env está no 7.0 e se o ambiente está rodando.
#  2. Faz um backup do banco (postgres-backup) e guarda o nome do arquivo.
#  3. Troca ZABBIX_VERSION no .env para o 8.0 (o .env antigo fica em
#     .env.antes-zabbix-8).
#  4. Sobe o Zabbix 8.0, espera o server atualizar o banco e a interface web
#     responder, roda o zabbix-init e reinicia o Grafana.
#
# A atualização do banco não tem volta: o único jeito de retornar ao 7.0 é
# restaurar o backup do passo 2 (--rollback). Roda com o sh do Linux e do
# macOS; no Windows, use o WSL.
set -eu
cd "$(dirname "$0")/.."

TARGET_VERSION=${ZABBIX_8_VERSION:-alpine-8.0.0}
ROLLBACK_VERSION=${ZABBIX_7_VERSION:-alpine-7.0.32}
ENV_FILE=.env

log() { echo "[upgrade-zabbix-8] $*"; }
die() { log "ERRO: $*"; exit 1; }

YES=0
MODE=upgrade
DUMP=
while [ $# -gt 0 ]; do
  case $1 in
    --yes | -y) YES=1 ;;
    --rollback) MODE=rollback; DUMP=${2:-}; [ -n "$DUMP" ] || die "informe o backup: --rollback zabbix-AAAAMMDD-HHMMSS.dump"; shift ;;
    -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
    *) die "opção desconhecida: $1 (use --help)" ;;
  esac
  shift
done

confirm() {
  [ "$YES" = 1 ] && return 0
  printf '%s Digite SIM para continuar: ' "$1"
  read -r answer || answer=
  [ "$answer" = SIM ] || die "cancelado"
}

# set_version <tag>: troca ZABBIX_VERSION no .env sem sed -i (que muda entre
# GNU e BSD) e mantendo as permissões do arquivo.
set_version() {
  tmp="$ENV_FILE.tmp.$$"
  if grep -q '^ZABBIX_VERSION=' "$ENV_FILE"; then
    sed "s/^ZABBIX_VERSION=.*/ZABBIX_VERSION=$1/" "$ENV_FILE" > "$tmp"
  else
    { cat "$ENV_FILE"; echo "ZABBIX_VERSION=$1"; } > "$tmp"
  fi
  cat "$tmp" > "$ENV_FILE"
  rm -f "$tmp"
}

current_version() { sed -n 's/^ZABBIX_VERSION=//p' "$ENV_FILE" | tail -n 1; }

running() { [ -n "$(docker compose ps -q --status running "$1" 2>/dev/null)" ]; }

# Espera o Zabbix server terminar de atualizar o banco. Em bancos grandes isso
# leva minutos (ou mais); o progresso aparece em "docker compose logs zabbix-server".
wait_server() {
  log "aguardando o Zabbix server atualizar o banco (acompanhe com: docker compose logs -f zabbix-server) ..."
  i=0
  until docker compose logs zabbix-server 2>/dev/null | grep -qE 'database upgrade fully completed|current database version'; do
    running zabbix-server || die "o zabbix-server parou; veja docker compose logs zabbix-server"
    i=$((i + 1))
    [ "$i" -ge 720 ] && die "o banco não terminou de atualizar em 1 hora; veja docker compose logs zabbix-server"
    sleep 5
  done
}

[ -f "$ENV_FILE" ] || die "não achei o $ENV_FILE; rode make env"
command -v docker >/dev/null || die "docker não encontrado"

if [ "$MODE" = rollback ]; then
  confirm "Isto APAGA o banco atual do Zabbix e restaura $DUMP, voltando para o $ROLLBACK_VERSION."
  running postgres || docker compose up -d --wait postgres postgres-backup
  log "parando Zabbix e Grafana"
  docker compose stop zabbix-server zabbix-web zabbix-agent grafana
  # O 8.0 cria tabelas que o 7.0 não conhece; o pg_restore --clean só apaga as
  # tabelas que estão no backup. Por isso o esquema é recriado do zero antes.
  log "recriando o esquema do banco"
  # shellcheck disable=SC2016 # as variáveis são do container do postgres
  docker compose exec -T postgres sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION \"$POSTGRES_USER\";"'
  docker compose exec -T postgres-backup sh /postgres-backup.sh restore "$DUMP"
  set_version "$ROLLBACK_VERSION"
  log "subindo o Zabbix $ROLLBACK_VERSION"
  docker compose up -d --wait --wait-timeout 600 zabbix-server zabbix-web zabbix-agent
  docker compose up zabbix-init --exit-code-from zabbix-init
  docker compose up -d --wait --wait-timeout 300 grafana
  log "rollback concluído: Zabbix $ROLLBACK_VERSION com os dados de $DUMP"
  exit 0
fi

CURRENT=$(current_version)
case $CURRENT in
  *8.0*) log "o $ENV_FILE já está no Zabbix 8.0 ($CURRENT); nada a fazer"; exit 0 ;;
  *7.0*) ;;
  *) die "esta atualização é do 7.0 para o 8.0, mas o $ENV_FILE tem ZABBIX_VERSION=$CURRENT" ;;
esac
running postgres || die "o ambiente não está rodando; suba com make up antes"
running postgres-backup || die "o serviço postgres-backup não está rodando"

confirm "O Zabbix vai de $CURRENT para $TARGET_VERSION. O banco é atualizado e não há volta sem o backup."

log "1/4 fazendo backup do banco"
OUT=$(docker compose exec -T postgres-backup sh /postgres-backup.sh once 2>&1) || { echo "$OUT"; die "o backup falhou; nada foi alterado"; }
echo "$OUT"
DUMP=$(echo "$OUT" | sed -n 's|^.*backup concluído: .*/\([^/ ]*\.dump\).*$|\1|p' | tail -n 1)
[ -n "$DUMP" ] || die "não consegui identificar o arquivo do backup; nada foi alterado"

log "2/4 trocando ZABBIX_VERSION para $TARGET_VERSION no $ENV_FILE (cópia em $ENV_FILE.antes-zabbix-8)"
cp -p "$ENV_FILE" "$ENV_FILE.antes-zabbix-8"
set_version "$TARGET_VERSION"

log "3/4 subindo o Zabbix $TARGET_VERSION"
docker compose pull -q zabbix-server zabbix-web zabbix-agent zabbix-init
docker compose up -d zabbix-server
wait_server
docker compose up -d --wait --wait-timeout 600 zabbix-server zabbix-web zabbix-agent

log "4/4 rodando o zabbix-init e reiniciando o Grafana"
docker compose up zabbix-init --exit-code-from zabbix-init
docker compose up -d --wait --wait-timeout 300 --force-recreate grafana

log "concluído: Zabbix $(docker compose exec -T zabbix-server zabbix_server -V 2>/dev/null | head -n 1 | sed 's/^.*(Zabbix) //')"
log "backup de antes da atualização: $DUMP"
log "copie-o para fora do servidor: docker compose cp postgres-backup:/var/lib/postgresql/backups/$DUMP ./"
log "para voltar ao 7.0: ./scripts/upgrade-zabbix-8.sh --rollback $DUMP"
