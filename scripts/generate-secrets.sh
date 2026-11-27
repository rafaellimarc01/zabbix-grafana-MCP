#!/bin/sh
# Gera o arquivo de segredos a partir do exemplo, preenchendo toda variável
# *_PASSWORD vazia com uma senha aleatória de 24 caracteres.
#   ./scripts/generate-secrets.sh                   -> .env (Docker Compose)
#   ./scripts/generate-secrets.sh compose staging   -> .env do ambiente de staging
#   ./scripts/generate-secrets.sh compose production
#   ./scripts/generate-secrets.sh k8s               -> kubernetes/base/secrets.env
#   ./scripts/generate-secrets.sh k8s staging       -> kubernetes/overlays/staging/secrets.env
#   ./scripts/generate-secrets.sh k8s production    -> kubernetes/overlays/production/secrets.env
# Com um ambiente, as configurações dele (environments/<ambiente>/compose.env
# ou kubernetes/overlays/<ambiente>/settings.env) entram no lugar das do
# exemplo, e cada ambiente ganha senhas próprias.
# Nunca sobrescreve um arquivo existente. O arquivo é criado com permissão 600.
set -eu
cd "$(dirname "$0")/.."

usage() { echo "uso: $0 [compose|k8s] [staging|production]" >&2; exit 2; }

DEPLOY_ENV=${2:-}
case "$DEPLOY_ENV" in
  ''|staging|production) ;;
  *) usage ;;
esac

SETTINGS=
case "${1:-compose}" in
  compose)
    SRC=.env.example
    DEST=.env
    [ -z "$DEPLOY_ENV" ] || SETTINGS=environments/$DEPLOY_ENV/compose.env
    ;;
  k8s)
    SRC=kubernetes/base/secrets.env.example
    if [ -n "$DEPLOY_ENV" ]; then
      DEST=kubernetes/overlays/$DEPLOY_ENV/secrets.env
      SETTINGS=kubernetes/overlays/$DEPLOY_ENV/settings.env
    else
      DEST=kubernetes/base/secrets.env
    fi
    ;;
  *) usage ;;
esac

if [ -f "$DEST" ]; then
  echo "$DEST já existe; nada foi alterado."
  # Avisa se o .env existente é de outro ambiente (ex.: make env DEPLOY_ENV=production
  # numa pasta que já tinha o .env de staging).
  if [ "$DEST" = .env ] && [ -n "$DEPLOY_ENV" ]; then
    current=$(sed -n 's/^DEPLOY_ENV=//p' .env | tail -n 1)
    if [ "$current" != "$DEPLOY_ENV" ]; then
      echo "atenção: o .env é do ambiente '${current:-padrão}', não '$DEPLOY_ENV'." >&2
      echo "Para trocar, guarde o .env atual (as senhas!) e veja \"Ambientes de staging e produção\" no README." >&2
    fi
  fi
  exit 0
fi

# setting <VAR>: a linha VAR=... das configurações do ambiente (vazio se não houver).
setting() {
  [ -n "$SETTINGS" ] || return 0
  grep -E "^$1=" "$SETTINGS" | tail -n 1 || true
}

# Senha aleatória só com letras e números (sem problemas de escape em .env).
# Evita "admin" e "zabbix", que o Zabbix proíbe na senha do Admin.
random_password() {
  while :; do
    # Lê uma quantidade fixa de /dev/urandom. Com "tr < /dev/urandom" a leitura
    # é infinita e, onde o SIGPIPE é ignorado (ex.: runner macOS do GitHub
    # Actions), o tr do macOS nunca termina depois que o head fecha o pipe.
    p=$(head -c 512 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 24)
    if [ "${#p}" -eq 24 ] && ! echo "$p" | grep -qiE 'admin|zabbix'; then
      echo "$p"
      return
    fi
  done
}

umask 077
TMP="$DEST.tmp.$$"
trap 'rm -f "$TMP"' EXIT
{
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      [A-Z]*=*) override=$(setting "${line%%=*}") ;;
      *) override= ;;
    esac
    if [ -n "$override" ]; then
      printf '%s\n' "$override"
    else
      case "$line" in
        [A-Z]*_PASSWORD=) printf '%s%s\n' "$line" "$(random_password)" ;;
        *) printf '%s\n' "$line" ;;
      esac
    fi
  done <"$SRC"
  # Configurações do ambiente que não existem no exemplo vão no fim.
  if [ -n "$SETTINGS" ]; then
    printf '\n# ---- Ambiente: %s (de %s) ----\n' "$DEPLOY_ENV" "$SETTINGS"
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        [A-Z]*=*) grep -qE "^${line%%=*}=" "$SRC" || printf '%s\n' "$line" ;;
      esac
    done <"$SETTINGS"
  fi
} >"$TMP"
mv "$TMP" "$DEST"
trap - EXIT
echo "$DEST criado com senhas aleatórias (permissão 600). Guarde as senhas em um cofre."
