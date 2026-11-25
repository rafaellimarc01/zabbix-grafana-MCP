# Zabbix + Grafana: ready-to-use stack (Docker and Kubernetes)

[Versão em português](README.md)

A ready-made template to run **Zabbix 7.0 LTS** and **Grafana** with either **Docker Compose** or **Kubernetes** (Kustomize). Grafana ships with the Zabbix plugin installed, the Zabbix data source provisioned, two dashboards (hosts overview and Zabbix server health) and ready-made alert rules.

## Docker Compose

```bash
make env                 # creates .env with random passwords (or ./scripts/generate-secrets.sh)
docker compose up -d
```

On Windows without WSL (no `make`, no `sh`), create the `.env` with PowerShell instead: `powershell -ExecutionPolicy Bypass -File scripts\generate-secrets.ps1` (add `-Target k8s` for Kubernetes). The Portuguese README, section "Usando no Windows", lists PowerShell equivalents for every `make` shortcut.

- Zabbix: http://localhost:8080 (user `Admin`, password `ZABBIX_ADMIN_PASSWORD` from `.env`)
- Grafana: http://localhost:3000 (`GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` from `.env`)

The web UIs listen on `127.0.0.1` only, since they speak plain HTTP. To reach them from another machine, put an HTTPS reverse proxy in front or set `BIND_ADDRESS=0.0.0.0` in `.env`.

A one-shot `zabbix-admin-password` container replaces the default Admin password directly in the database before the web UI starts, so Admin is never reachable with `zabbix`. Then a one-shot `zabbix-init` container creates a read-only, API-only `grafana` user that Grafana uses to query Zabbix, and points the built-in "Zabbix server" host to the agent container.

Port 10051 (trapper) listens on all interfaces for active agents. Docker-published ports bypass UFW/firewalld, so filter it in the `DOCKER-USER` iptables chain or set `ZABBIX_SERVER_BIND_ADDRESS`, and enable PSK encryption per host (see "Protegendo a porta 10051" in the Portuguese README).

### macOS

Works on Intel and Apple Silicon Macs: every image has a native `arm64` build. Install Docker Desktop (give it 4 GB+ RAM), run `xcode-select --install` for `make` and `git`, and clone the repo under your home folder (Docker Desktop only shares `/Users`, `/Volumes`, `/private` and `/tmp`; anything else fails with `mounts denied`). The bundled `zabbix-agent` monitors Docker Desktop's Linux VM, not the Mac itself. The scripts only use tools that ship with macOS and are tested on `macos-latest` in CI.

## Kubernetes

```bash
make k8s-secrets   # creates kubernetes/base/secrets.env with random passwords
kubectl apply -k kubernetes/overlays/local     # NodePorts 30080 (Zabbix), 30300 (Grafana), 30051 (trapper)
# or, recommended for production (Gateway API, HTTPS only):
kubectl apply -k kubernetes/overlays/gateway   # set gatewayClassName and hosts in gateway.yaml first
# or, with an Ingress controller (Traefik by default, HTTPS only):
kubectl apply -k kubernetes/overlays/ingress   # edit class, annotations and hosts in ingress.yaml first
```

ingress-nginx was retired in March 2026 and no longer gets security fixes, so the overlays no longer use it. In the `gateway` and `ingress` overlays, NetworkPolicies only let the ingress controller reach Zabbix web and Grafana; if your controller runs in a namespace that is not in `kubernetes/components/external-access/networkpolicy.yaml`, label it with `zabbix-grafana/ingress-controller=true`.

Everything goes into the `monitoring` namespace. The default Admin password is replaced by an init container of `zabbix-web`; the rest of the setup runs as an init container of Grafana on every pod start, so `kubectl apply -k` can be repeated safely. `kubernetes/base/files/` holds a copy of `grafana/` and the scripts because Kustomize cannot read files outside its folder; run `./scripts/sync-k8s-files.sh` after changing them.

## Database backups

The Zabbix database is backed up automatically with `pg_dump`: the `postgres-backup` Compose service runs at startup and daily at `BACKUP_TIME` (default `02:00`, keeping `BACKUP_KEEP_DAYS=7`) into the `postgres-backups` volume; on Kubernetes a CronJob does the same into the `postgres-backups` PVC. Run `make backup` for an on-demand backup. Restore steps (all platforms) are in the Portuguese README, section "Backup do banco".

## Alerts

Grafana ships with 5 provisioned alert rules (`grafana/provisioning/alerting/zabbix-rules.yaml`, folder **Zabbix**) that query Zabbix and fire one alert per host (and per filesystem) for every host using the stock **Linux by Zabbix agent** and **Zabbix server health** templates:

| Rule | Zabbix item | Fires when | Severity |
|---|---|---|---|
| Host indisponível (host down) | `Zabbix agent availability` | agent unavailable for 3 min | `critical` |
| CPU alta (high CPU) | `CPU utilization` | 10-min average above 90% for 5 min | `warning` |
| Memória alta (high memory) | `Memory utilization` | 10-min average above 90% for 5 min | `warning` |
| Disco quase cheio (disk almost full) | `FS [*]: Space: Used, in %` | above 90% for 10 min | `warning` |
| Fila do Zabbix acumulada (Zabbix queue) | `Queue over 10 minutes` | more than 100 delayed items for 10 min | `warning` |

Out of the box, alerts only show up in Grafana (**Alerting → Alert rules**). To get notified, enable **one** example from `grafana/alerting-examples/`:

- **Email:** set `GRAFANA_SMTP_ENABLED=true`, `GRAFANA_SMTP_HOST`, `GRAFANA_SMTP_USER`, `GRAFANA_SMTP_PASS`, `GRAFANA_SMTP_FROM` and `ALERT_EMAIL_TO` (`;`-separated) in `.env`, then `cp grafana/alerting-examples/email.yaml grafana/provisioning/alerting/ && docker compose up -d grafana`.
- **Telegram:** set `TELEGRAM_BOT_TOKEN` in `.env`, copy `grafana/alerting-examples/telegram.yaml` to `grafana/provisioning/alerting/`, replace `COLOQUE_O_CHAT_ID_AQUI` with your chat id in the copy (Grafana turns a chat id coming from an env var into a number and rejects it), then `docker compose up -d grafana`.

Set `GRAFANA_ROOT_URL` so links in notifications work. Enabled copies are git-ignored. On Kubernetes, put the same variables in `kubernetes/base/secrets.env`, add the copied file to the `grafana-alerting` `configMapGenerator` in `kubernetes/base/kustomization.yaml`, run `./scripts/sync-k8s-files.sh` and apply again. To change a threshold, edit `params` in step `C` of the rule and restart Grafana.

## Security

No default passwords, non-root containers with all capabilities dropped, an isolated database, a read-only Zabbix user for Grafana, NetworkPolicies, Pod Security `baseline`, and TLS in the `gateway` and `ingress` overlays. See [SECURITY.md](SECURITY.md) (Portuguese) for the full list, what is still up to you, and how to report a vulnerability.

See the Portuguese README for details on monitoring your own servers, customization and troubleshooting. Run `make help` for shortcuts and `make validate` before opening a PR.

License: [MIT](LICENSE)
