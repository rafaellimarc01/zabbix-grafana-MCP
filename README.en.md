# Zabbix + Grafana: ready-to-use stack (Docker and Kubernetes)

[Versão em português](README.md)

A ready-made template to run **Zabbix 7.0 LTS** and **Grafana** with either **Docker Compose** or **Kubernetes** (Kustomize). Grafana ships with the Zabbix plugin installed, the Zabbix data source provisioned and two dashboards (hosts overview and Zabbix server health).

## Docker Compose

```bash
cp .env.example .env     # then CHANGE THE PASSWORDS
docker compose up -d
```

- Zabbix: http://localhost:8080 (user `Admin`, password `ZABBIX_ADMIN_PASSWORD`)
- Grafana: http://localhost:3000 (`GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`)

A one-shot `zabbix-init` container replaces the default Admin password and points the built-in "Zabbix server" host to the agent container. The Admin password must be 8+ characters and must not contain "Admin" or "Zabbix".

## Kubernetes

```bash
cp kubernetes/base/secrets.env.example kubernetes/base/secrets.env   # CHANGE THE PASSWORDS
kubectl apply -k kubernetes/overlays/local     # NodePorts 30080 (Zabbix), 30300 (Grafana), 30051 (trapper)
# or
kubectl apply -k kubernetes/overlays/ingress   # edit hosts in ingress.yaml first
```

Everything goes into the `monitoring` namespace. `kubernetes/base/files/` holds a copy of `grafana/` and the init script because Kustomize cannot read files outside its folder; run `./scripts/sync-k8s-files.sh` after changing them.

See the Portuguese README for details on monitoring your own servers, customization and troubleshooting. Run `make help` for shortcuts and `make validate` before opening a PR.

License: [MIT](LICENSE)
