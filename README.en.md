# Zabbix + Grafana: ready-to-use stack (Docker and Kubernetes)

[Versão em português](README.md)

A ready-made template to run **Zabbix 7.0 LTS** and **Grafana** with either **Docker Compose** or **Kubernetes** (Kustomize). Grafana ships with the Zabbix plugin installed, the Zabbix data source provisioned and two dashboards (hosts overview and Zabbix server health).

## Docker Compose

```bash
make env                 # creates .env with random passwords (or ./scripts/generate-secrets.sh)
docker compose up -d
```

- Zabbix: http://localhost:8080 (user `Admin`, password `ZABBIX_ADMIN_PASSWORD` from `.env`)
- Grafana: http://localhost:3000 (`GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` from `.env`)

The web UIs listen on `127.0.0.1` only, since they speak plain HTTP. To reach them from another machine, put an HTTPS reverse proxy in front or set `BIND_ADDRESS=0.0.0.0` in `.env`.

A one-shot `zabbix-init` container replaces the default Admin password, creates a read-only, API-only `grafana` user that Grafana uses to query Zabbix, and points the built-in "Zabbix server" host to the agent container.

## Kubernetes

```bash
make k8s-secrets   # creates kubernetes/base/secrets.env with random passwords
kubectl apply -k kubernetes/overlays/local     # NodePorts 30080 (Zabbix), 30300 (Grafana), 30051 (trapper)
# or
kubectl apply -k kubernetes/overlays/ingress   # HTTPS; edit hosts in ingress.yaml first
```

Everything goes into the `monitoring` namespace. `kubernetes/base/files/` holds a copy of `grafana/` and the init script because Kustomize cannot read files outside its folder; run `./scripts/sync-k8s-files.sh` after changing them.

## Security

No default passwords, non-root containers with all capabilities dropped, an isolated database, a read-only Zabbix user for Grafana, NetworkPolicies, Pod Security `baseline`, and TLS in the `ingress` overlay. See [SECURITY.md](SECURITY.md) (Portuguese) for the full list, what is still up to you, and how to report a vulnerability.

See the Portuguese README for details on monitoring your own servers, customization and troubleshooting. Run `make help` for shortcuts and `make validate` before opening a PR.

License: [MIT](LICENSE)
