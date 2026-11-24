#!/bin/sh
# O Kustomize não lê arquivos fora da pasta dele, então o Kubernetes usa uma
# cópia dos arquivos do Grafana e do script de init. Rode este script sempre
# que alterar algo em grafana/ ou scripts/zabbix-init.sh.
#   ./scripts/sync-k8s-files.sh          -> copia
#   ./scripts/sync-k8s-files.sh --check  -> só verifica (usado no CI)
set -eu
cd "$(dirname "$0")/.."
DEST=kubernetes/base/files
# Lixo que o macOS (Finder) cria nas pastas: .DS_Store e ._* (AppleDouble).
# Não pode ir para o Kubernetes nem fazer o --check acusar diferença.

if [ "${1:-}" = "--check" ]; then
  if diff -r -x .DS_Store -x '._*' grafana "$DEST/grafana" && diff scripts/zabbix-init.sh "$DEST/zabbix-init.sh"; then
    echo "kubernetes/base/files está sincronizado"
    exit 0
  fi
  echo "arquivos diferentes: rode ./scripts/sync-k8s-files.sh"
  exit 1
fi

rm -rf "$DEST"
mkdir -p "$DEST"
cp -r grafana "$DEST/grafana"
cp scripts/zabbix-init.sh "$DEST/zabbix-init.sh"
find "$DEST" -type f \( -name .DS_Store -o -name '._*' \) -exec rm -f {} +
echo "arquivos copiados para $DEST"
