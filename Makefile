# Atalhos para o dia a dia. Rode "make help" para ver tudo.
.DEFAULT_GOAL := help
K8S_OVERLAY ?= local
# Ambiente do Docker Compose para o make env: vazio (padrão), staging ou production.
DEPLOY_ENV ?=
# Overlays que são ambientes, cada um com o próprio secrets.env e namespace.
K8S_ENVS := staging production
K8S_ENV := $(filter $(K8S_OVERLAY),$(K8S_ENVS))
K8S_NAMESPACE := $(if $(filter staging,$(K8S_OVERLAY)),monitoring-staging,monitoring)
K8S_SECRETS := $(if $(K8S_ENV),kubernetes/overlays/$(K8S_ENV)/secrets.env,kubernetes/base/secrets.env)

.PHONY: help env check-env up down logs ps reset backup backup-list upgrade-8 mcp mcp-config k8s-secrets k8s-render k8s-apply k8s-delete k8s-mcp k8s-mcp-config sync-k8s validate

help: ## Mostra esta ajuda
	@# Regex sem "*?" (não guloso), que o grep/awk do macOS (BSD) não aceitam.
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":[^#]*## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

env: ## Gera o .env com senhas aleatórias (DEPLOY_ENV=staging|production; não sobrescreve)
	@./scripts/generate-secrets.sh compose $(DEPLOY_ENV)

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

mcp: ## Sobe o MCP único do Zabbix e do Grafana (só em 127.0.0.1) e mostra como conectar as IAs
	./scripts/mcp-setup.sh

mcp-config: ## Mostra de novo como conectar o Claude e outras IAs ao MCP
	@./scripts/mcp-setup.sh config

reset: ## APAGA tudo, inclusive volumes/dados
	docker compose down -v

k8s-secrets: ## Gera o secrets.env com senhas aleatórias (K8S_OVERLAY=staging|production: um por ambiente; não sobrescreve)
	@./scripts/generate-secrets.sh k8s
	@./scripts/check-secrets.sh kubernetes/base/secrets.env
	@if [ -n "$(K8S_ENV)" ]; then ./scripts/generate-secrets.sh k8s $(K8S_ENV) && ./scripts/check-secrets.sh $(K8S_SECRETS); fi

k8s-render: k8s-secrets ## Mostra os manifests gerados (K8S_OVERLAY=local|gateway|ingress|staging|production)
	kubectl kustomize kubernetes/overlays/$(K8S_OVERLAY)

k8s-apply: k8s-secrets ## Aplica no cluster atual (K8S_OVERLAY=local|gateway|ingress|staging|production)
	kubectl apply -k kubernetes/overlays/$(K8S_OVERLAY)

k8s-delete: ## Remove do cluster (os PVCs do PostgreSQL ficam)
	kubectl delete -k kubernetes/overlays/$(K8S_OVERLAY)

k8s-mcp: ## Liga o MCP do Kubernetes em 127.0.0.1:8765 (port-forward; deixe rodando)
	kubectl -n $(K8S_NAMESPACE) port-forward --address 127.0.0.1 svc/mcp 8765:8765

k8s-mcp-config: ## Mostra como conectar o Claude e outras IAs ao MCP do Kubernetes
	@K8S_SECRETS=$(K8S_SECRETS) ./scripts/mcp-setup.sh k8s-config

sync-k8s: ## Copia grafana/ e os scripts para kubernetes/base/files
	./scripts/sync-k8s-files.sh

validate: k8s-secrets ## Valida compose, kustomize, YAML e scripts
	sed 's/_PASSWORD=$$/_PASSWORD=SomenteValidacao1234/' .env.example > .env.validate
	docker compose --env-file .env.validate config -q
	@for e in staging production; do \
	  sed 's/_PASSWORD=$$/_PASSWORD=SomenteValidacao1234/' .env.example > .env.validate; \
	  grep -E '^[A-Z_]+=' environments/$$e/compose.env >> .env.validate; \
	  docker compose --env-file .env.validate -f docker-compose.yml -f environments/$$e/compose.yml config -q && echo "compose $$e ok"; \
	done
	@./scripts/generate-secrets.sh k8s staging >/dev/null
	@./scripts/generate-secrets.sh k8s production >/dev/null
	shellcheck scripts/*.sh
	./scripts/sync-k8s-files.sh --check
	@for o in local ingress gateway staging production; do kubectl kustomize kubernetes/overlays/$$o >/dev/null && echo "kustomize $$o ok"; done
	yamllint -s .
