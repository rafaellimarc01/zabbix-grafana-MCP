# Atalhos para o dia a dia. Rode "make help" para ver tudo.
.DEFAULT_GOAL := help
K8S_OVERLAY ?= local

.PHONY: help env up down logs ps reset k8s-secrets k8s-render k8s-apply k8s-delete sync-k8s validate

help: ## Mostra esta ajuda
	@grep -E '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

env: ## Cria o .env a partir do .env.example (não sobrescreve)
	@test -f .env || (cp .env.example .env && echo ".env criado - troque as senhas!")

up: env ## Sobe o ambiente com Docker Compose
	docker compose up -d

down: ## Para o ambiente (mantém os dados)
	docker compose down

logs: ## Acompanha os logs
	docker compose logs -f --tail=100

ps: ## Status dos containers
	docker compose ps -a

reset: ## APAGA tudo, inclusive volumes/dados
	docker compose down -v

k8s-secrets: ## Cria kubernetes/base/secrets.env a partir do exemplo
	@test -f kubernetes/base/secrets.env || (cp kubernetes/base/secrets.env.example kubernetes/base/secrets.env && echo "secrets.env criado - troque as senhas!")

k8s-render: k8s-secrets ## Mostra os manifests gerados (K8S_OVERLAY=local|ingress)
	kubectl kustomize kubernetes/overlays/$(K8S_OVERLAY)

k8s-apply: k8s-secrets ## Aplica no cluster atual (K8S_OVERLAY=local|ingress)
	kubectl apply -k kubernetes/overlays/$(K8S_OVERLAY)

k8s-delete: ## Remove do cluster (os PVCs do PostgreSQL ficam)
	kubectl delete -k kubernetes/overlays/$(K8S_OVERLAY)

sync-k8s: ## Copia grafana/ e o script de init para kubernetes/base/files
	./scripts/sync-k8s-files.sh

validate: ## Valida compose, kustomize e YAML
	docker compose --env-file .env.example config -q
	./scripts/sync-k8s-files.sh --check
	@for o in local ingress; do kubectl kustomize kubernetes/overlays/$$o >/dev/null && echo "kustomize $$o ok"; done
	yamllint -s .
