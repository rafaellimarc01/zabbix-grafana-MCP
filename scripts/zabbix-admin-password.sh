#!/bin/sh
# Troca a senha padrão ("zabbix") do usuário Admin direto no banco, ANTES de a
# interface web do Zabbix subir. Assim o Admin nunca fica acessível com a
# senha padrão, nem por alguns segundos, nem se o zabbix-init falhar depois.
#
# Roda na imagem oficial do postgres (tem psql e a extensão pgcrypto), sem root.
# É idempotente: só mexe no Admin se a senha dele ainda for "zabbix". Uma senha
# trocada depois pela interface nunca é sobrescrita.
#
# Variáveis: PGHOST, PGUSER, PGPASSWORD, PGDATABASE (conexão, padrão do libpq) e
# ZABBIX_ADMIN_PASSWORD (senha nova). WAIT_SECONDS: quanto esperar o Zabbix
# server criar as tabelas no primeiro start (padrão 600).
set -eu

: "${PGHOST:?defina PGHOST}" "${PGUSER:?defina PGUSER}" "${PGDATABASE:?defina PGDATABASE}"
: "${ZABBIX_ADMIN_PASSWORD:?defina ZABBIX_ADMIN_PASSWORD}"
WAIT_SECONDS=${WAIT_SECONDS:-600}

log() { echo "[zabbix-admin-password] $*"; }

# Mesmas regras do Zabbix: o banco não confere a política de senha, então
# conferimos aqui.
if [ "${#ZABBIX_ADMIN_PASSWORD}" -lt 8 ] || echo "$ZABBIX_ADMIN_PASSWORD" | grep -qiE 'admin|zabbix'; then
  log "ZABBIX_ADMIN_PASSWORD precisa ter 8+ caracteres e não pode conter 'Admin' nem 'Zabbix'"
  exit 1
fi

q() { psql --no-psqlrc --quiet --tuples-only --no-align --set ON_ERROR_STOP=1 "$@"; }

# No primeiro start o Zabbix server ainda está criando o banco: espera a tabela
# users e o usuário Admin existirem.
log "aguardando o Zabbix server criar o banco em $PGHOST/$PGDATABASE ..."
waited=0
until [ "$(q -c "select count(*) from users where username = 'Admin'" 2>/dev/null || true)" = 1 ]; do
  waited=$((waited + 5))
  [ "$waited" -gt "$WAIT_SECONDS" ] && { log "o banco não ficou pronto em ${WAIT_SECONDS}s"; exit 1; }
  sleep 5
done

# A senha nova vai por variável de ambiente (\getenv), nunca pela linha de
# comando, e é citada pelo próprio psql (:'pw'). crypt(senha, hash) = hash
# confere a senha atual sem precisar conhecê-la. O Zabbix grava bcrypt com o
# prefixo "$2y$" do PHP, que o pgcrypto não reconhece; "$2y$" e "$2a$" são o
# mesmo algoritmo, então a comparação troca o prefixo. gen_salt('bf') gera
# "$2a$", que o Zabbix (password_verify do PHP) aceita. Se a extensão pgcrypto não
# existia, ela é criada e apagada na mesma transação: o esquema do Zabbix
# fica como estava.
result=$(q <<'SQL'
\getenv pw ZABBIX_ADMIN_PASSWORD
BEGIN;
SELECT NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgcrypto') AS drop_after \gset
CREATE EXTENSION IF NOT EXISTS pgcrypto;
WITH updated AS (
  UPDATE users SET passwd = crypt(:'pw', gen_salt('bf', 10))
  WHERE username = 'Admin' AND passwd ~ '^\$2[aby]\$'
    AND crypt('zabbix', '$2a$' || substr(passwd, 5)) = '$2a$' || substr(passwd, 5)
  RETURNING 1
)
SELECT 'trocadas=' || count(*) FROM updated;
\if :drop_after
DROP EXTENSION pgcrypto;
\endif
COMMIT;
SQL
)

case $result in
  *trocadas=1*) log "senha padrão do Admin trocada" ;;
  *) log "o Admin já não usa a senha padrão; nada alterado" ;;
esac
