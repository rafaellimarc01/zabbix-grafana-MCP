#!/bin/sh
# Confere se as senhas de um arquivo de segredos são seguras o bastante
# para subir o ambiente. Usado pelo Makefile (make up / make k8s-apply) e pelo CI.
#   ./scripts/check-secrets.sh .env
#   ./scripts/check-secrets.sh kubernetes/base/secrets.env
set -eu
FILE="${1:-.env}"
MIN_LENGTH=12

if [ ! -f "$FILE" ]; then
  echo "erro: $FILE não existe. Gere com: make env (ou make k8s-secrets)" >&2
  exit 1
fi

errors=0
fail() { echo "erro: $*" >&2; errors=$((errors + 1)); }

found=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    [A-Z]*_PASSWORD=*) ;;
    *) continue ;;
  esac
  found=$((found + 1))
  key=${line%%=*}
  value=${line#*=}
  if [ -z "$value" ]; then
    fail "$key está vazia"
    continue
  fi
  [ "${#value}" -ge "$MIN_LENGTH" ] || fail "$key tem menos de $MIN_LENGTH caracteres"
  case "$value" in
    *TroqueEstaSenha* | *changeme* | *password* | *senha*)
      fail "$key ainda usa uma senha de exemplo" ;;
  esac
  if [ "$key" = ZABBIX_ADMIN_PASSWORD ] && echo "$value" | grep -qiE 'admin|zabbix'; then
    fail "$key não pode conter \"Admin\" nem \"Zabbix\" (regra do Zabbix)"
  fi
done <"$FILE"

[ "$found" -gt 0 ] || fail "nenhuma variável *_PASSWORD encontrada em $FILE"

if [ "$errors" -gt 0 ]; then
  echo "Corrija $FILE (ou apague e gere de novo com make env / make k8s-secrets)." >&2
  exit 1
fi
echo "$FILE: senhas ok"
