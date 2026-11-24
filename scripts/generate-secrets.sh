#!/bin/sh
# Gera o arquivo de segredos a partir do exemplo, preenchendo toda variável
# *_PASSWORD vazia com uma senha aleatória de 24 caracteres.
#   ./scripts/generate-secrets.sh          -> .env (Docker Compose)
#   ./scripts/generate-secrets.sh k8s      -> kubernetes/base/secrets.env
# Nunca sobrescreve um arquivo existente. O arquivo é criado com permissão 600.
set -eu
cd "$(dirname "$0")/.."

case "${1:-compose}" in
  compose) SRC=.env.example; DEST=.env ;;
  k8s) SRC=kubernetes/base/secrets.env.example; DEST=kubernetes/base/secrets.env ;;
  *) echo "uso: $0 [compose|k8s]" >&2; exit 2 ;;
esac

if [ -f "$DEST" ]; then
  echo "$DEST já existe; nada foi alterado."
  exit 0
fi

# Senha aleatória só com letras e números (sem problemas de escape em .env).
# Evita "admin" e "zabbix", que o Zabbix proíbe na senha do Admin.
random_password() {
  while :; do
    p=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)
    if [ "${#p}" -eq 24 ] && ! echo "$p" | grep -qiE 'admin|zabbix'; then
      echo "$p"
      return
    fi
  done
}

umask 077
TMP="$DEST.tmp.$$"
trap 'rm -f "$TMP"' EXIT
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    [A-Z]*_PASSWORD=) printf '%s%s\n' "$line" "$(random_password)" ;;
    *) printf '%s\n' "$line" ;;
  esac
done <"$SRC" >"$TMP"
mv "$TMP" "$DEST"
trap - EXIT
echo "$DEST criado com senhas aleatórias (permissão 600). Guarde as senhas em um cofre."
