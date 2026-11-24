#!/bin/sh
# Backup automático do banco do Zabbix (PostgreSQL) com pg_dump.
# Roda dentro da imagem oficial do postgres (mesma versão do banco), sem root.
#
#   postgres-backup.sh loop            -> faz um backup ao iniciar (se não houver
#                                         um das últimas 24 h) e depois todo dia
#                                         às BACKUP_TIME (Docker Compose)
#   postgres-backup.sh once            -> um backup agora (CronJob do Kubernetes)
#   postgres-backup.sh list            -> lista os backups
#   postgres-backup.sh restore ARQUIVO -> restaura um backup (APAGA os dados atuais)
#
# Variáveis: PGHOST, PGUSER, PGPASSWORD, PGDATABASE (conexão, padrão do libpq),
# BACKUP_DIR (pasta dos arquivos), BACKUP_KEEP_DAYS (retenção, padrão 7) e
# BACKUP_TIME (horário diário HH:MM no fuso TZ, padrão 02:00).
set -eu
# Os backups têm todos os dados do Zabbix: só o dono lê.
umask 077

BACKUP_DIR=${BACKUP_DIR:-/backups}
BACKUP_KEEP_DAYS=${BACKUP_KEEP_DAYS:-7}
BACKUP_TIME=${BACKUP_TIME:-02:00}
: "${PGHOST:?defina PGHOST}" "${PGUSER:?defina PGUSER}" "${PGDATABASE:?defina PGDATABASE}"

log() { echo "[backup $(date '+%Y-%m-%d %H:%M:%S')] $*"; }

case $BACKUP_KEEP_DAYS in '' | *[!0-9]* | 0)
  echo "BACKUP_KEEP_DAYS precisa ser um número inteiro maior que zero" >&2; exit 2 ;;
esac
case $BACKUP_TIME in [0-2][0-9]:[0-5][0-9]) ;; *)
  echo "BACKUP_TIME precisa estar no formato HH:MM (ex.: 02:00)" >&2; exit 2 ;;
esac

backup() {
  name="$PGDATABASE-$(date +%Y%m%d-%H%M%S).dump"
  tmp="$BACKUP_DIR/.$name.partial"
  log "iniciando backup de $PGDATABASE em $PGHOST"
  # Formato custom (-Fc): já vem comprimido e permite restaurar com pg_restore.
  if ! pg_dump --format=custom --compress=6 --no-password --file="$tmp"; then
    rm -f "$tmp"
    log "ERRO: pg_dump falhou"
    return 1
  fi
  # Confere se o arquivo é um dump legível antes de considerá-lo válido.
  if ! pg_restore --list "$tmp" >/dev/null; then
    rm -f "$tmp"
    log "ERRO: o arquivo gerado não é um dump válido"
    return 1
  fi
  mv "$tmp" "$BACKUP_DIR/$name"
  log "backup concluído: $BACKUP_DIR/$name ($(du -h "$BACKUP_DIR/$name" | cut -f1))"
  # A limpeza só roda depois de um backup bem-sucedido, então o mais recente
  # sempre fica, mesmo que os backups passem dias falhando.
  find "$BACKUP_DIR" -maxdepth 1 -type f -name "$PGDATABASE-*.dump" \
    -mmin +$((BACKUP_KEEP_DAYS * 1440)) -print -exec rm -f {} + |
    while read -r old; do log "removido (mais de $BACKUP_KEEP_DAYS dias): $old"; done
  find "$BACKUP_DIR" -maxdepth 1 -type f -name '.*.partial' -mmin +1440 -exec rm -f {} +
}

# Segundos até o próximo BACKUP_TIME. Conta só com HH:MM:SS do relógio local,
# porque o date do busybox não entende "amanhã às 02:00".
seconds_until_next() {
  target=$(( $(echo "$BACKUP_TIME" | cut -d: -f1 | sed 's/^0//') * 3600 + \
             $(echo "$BACKUP_TIME" | cut -d: -f2 | sed 's/^0//') * 60 ))
  now=$(( $(date +%H | sed 's/^0//') * 3600 + $(date +%M | sed 's/^0//') * 60 + \
          $(date +%S | sed 's/^0//') ))
  wait=$(( (target - now + 86400) % 86400 ))
  [ "$wait" -eq 0 ] && wait=86400
  echo "$wait"
}

wait_for_db() {
  i=0
  until pg_isready --quiet; do
    i=$((i + 1))
    [ "$i" -ge 60 ] && { log "ERRO: banco não respondeu"; return 1; }
    sleep 5
  done
}

mkdir -p "$BACKUP_DIR"

case ${1:-loop} in
  once)
    wait_for_db
    backup
    ;;
  loop)
    log "backup diário às $BACKUP_TIME (TZ=${TZ:-UTC}), guardando $BACKUP_KEEP_DAYS dias em $BACKUP_DIR"
    wait_for_db
    if [ -z "$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "$PGDATABASE-*.dump" -mmin -1440)" ]; then
      backup || true
    fi
    while :; do
      s=$(seconds_until_next)
      log "próximo backup em $((s / 3600))h$(((s % 3600) / 60))min"
      sleep "$s"
      # Se falhar, tenta de novo no próximo horário; o healthcheck acusa.
      backup || true
      sleep 60
    done
    ;;
  list)
    set -- "$BACKUP_DIR"/*.dump
    if [ -e "$1" ]; then ls -lh "$@"; else echo "nenhum backup em $BACKUP_DIR"; fi
    ;;
  restore)
    file=${2:?informe o arquivo: restore $PGDATABASE-AAAAMMDD-HHMMSS.dump}
    case $file in /*) ;; *) file="$BACKUP_DIR/$file" ;; esac
    [ -f "$file" ] || { echo "arquivo não encontrado: $file" >&2; exit 1; }
    if [ ! -r "$file" ]; then
      echo "sem permissão para ler $file. Se ele foi copiado do seu computador" >&2
      echo "com 'docker compose cp', rode a restauração com 'docker compose exec -u 0'." >&2
      exit 1
    fi
    wait_for_db
    log "restaurando $file em $PGDATABASE (os dados atuais serão substituídos)"
    pg_restore --clean --if-exists --no-owner --single-transaction --exit-on-error \
      --no-password --dbname="$PGDATABASE" "$file"
    log "restauração concluída"
    ;;
  *)
    echo "uso: $0 [loop|once|list|restore ARQUIVO]" >&2
    exit 2
    ;;
esac
