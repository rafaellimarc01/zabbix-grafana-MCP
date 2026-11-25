#!/bin/sh
# O Kustomize não lê arquivos fora da pasta dele, então o Kubernetes usa uma
# cópia dos arquivos do Grafana e dos scripts de init e de backup. Rode este
# script sempre que alterar algo em grafana/ ou nos scripts listados em SCRIPTS.
#   ./scripts/sync-k8s-files.sh          -> copia
#   ./scripts/sync-k8s-files.sh --check  -> só verifica (usado no CI)
set -eu
cd "$(dirname "$0")/.."
DEST=kubernetes/base/files
SCRIPTS="zabbix-init.sh zabbix-admin-password.sh postgres-backup.sh"
# Lixo que o macOS (Finder) cria nas pastas: .DS_Store e ._* (AppleDouble).
# Não pode ir para o Kubernetes nem fazer o --check acusar diferença.

if [ "${1:-}" = "--check" ]; then
  ok=1
  diff -r -x .DS_Store -x '._*' grafana "$DEST/grafana" || ok=0
  for s in $SCRIPTS; do
    diff "scripts/$s" "$DEST/$s" || ok=0
  done
  if [ "$ok" = 1 ]; then
    echo "kubernetes/base/files está sincronizado"
    exit 0
  fi
  echo "arquivos diferentes: rode ./scripts/sync-k8s-files.sh"
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"
cp -r grafana "$DEST/grafana"
for s in $SCRIPTS; do
  cp "scripts/$s" "$DEST/$s"
done
find "$DEST" -type f \( -name .DS_Store -o -name '._*' \) -exec rm -f {} +
echo "arquivos copiados para $DEST"
