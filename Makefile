# Atalhos para o dia a dia. Rode "make help" para ver tudo.
.DEFAULT_GOAL := help
K8S_OVERLAY ?= local

.PHONY: help env check-env up down logs ps reset backup backup-list upgrade-8 mcp mcp-config k8s-secrets k8s-render k8s-apply k8s-delete sync-k8s validate

help: ## Mostra esta ajuda
	@# Regex sem "*?" (não guloso), que o grep/awk do macOS (BSD) não aceitam.
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":[^#]*## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

env: ## Gera o .env com senhas aleatórias (não sobrescreve)
	@./scripts/generate-secrets.sh compose

check-env: ## Confere se as senhas do .env são fortes
	@./scripts/check-secrets.sh .env

up: env check-env ## Sobe o ambiente com Docker Compose
	docker compose up -d

down: ## Para o ambiente (mantém os dados)
	docker compose down

logs: ## Acompanha os logs
	docker compose logs -f --tail=100

ps: ## Status dos containers
	docker compose ps -a

backup: ## Faz um backup do banco agora (além do automático diário)
	docker compose exec postgres-backup sh /postgres-backup.sh once

backup-list: ## Lista os backups do banco
	docker compose exec postgres-backup sh /postgres-backup.sh list

upgrade-8: ## Atualiza do Zabbix 7.0 para o 8.0 (faz backup antes; veja o README)
	./scripts/upgrade-zabbix-8.sh

mcp: ## Sobe os MCPs do Zabbix e do Grafana (só em 127.0.0.1) e mostra como conectar as IAs
	./scripts/mcp-setup.sh

mcp-config: ## Mostra de novo como conectar o Claude e outras IAs aos MCPs
	@./scripts/mcp-setup.sh config

reset: ## APAGA tudo, inclusive volumes/dados
	docker compose down -v

k8s-secrets: ## Gera kubernetes/base/secrets.env com senhas aleatórias (não sobrescreve)
	@./scripts/generate-secrets.sh k8s
	@./scripts/check-secrets.sh kubernetes/base/secrets.env

k8s-render: k8s-secrets ## Mostra os manifests gerados (K8S_OVERLAY=local|gateway|ingress)
	kubectl kustomize kubernetes/overlays/$(K8S_OVERLAY)

k8s-apply: k8s-secrets ## Aplica no cluster atual (K8S_OVERLAY=local|gateway|ingress)
	kubectl apply -k kubernetes/overlays/$(K8S_OVERLAY)

k8s-delete: ## Remove do cluster (os PVCs do PostgreSQL ficam)
	kubectl delete -k kubernetes/overlays/$(K8S_OVERLAY)

sync-k8s: ## Copia grafana/ e os scripts para kubernetes/base/files
	./scripts/sync-k8s-files.sh

validate: k8s-secrets ## Valida compose, kustomize, YAML e scripts
	sed 's/_PASSWORD=$$/_PASSWORD=SomenteValidacao1234/' .env.example > .env.validate
	docker compose --env-file .env.validate config -q
	shellcheck scripts/*.sh
	./scripts/sync-k8s-files.sh --check
	@for o in local ingress gateway; do kubectl kustomize kubernetes/overlays/$$o >/dev/null && echo "kustomize $$o ok"; done
	yamllint -s .
