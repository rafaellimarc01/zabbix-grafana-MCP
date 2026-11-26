# zabbix-grafana-MCP: ready-to-use Zabbix + Grafana stack (Docker and Kubernetes)

[Versão em português](README.md)

A ready-made template to run **Zabbix** and **Grafana** with either **Docker Compose** or **Kubernetes** (Kustomize). Grafana ships with the Zabbix plugin installed, the Zabbix data source provisioned, two dashboards (hosts overview and Zabbix server health) and ready-made alert rules.

The project delivers three things:

| | What it is | Where |
|---|---|---|
| **Zabbix 7.0 or 8.0 LTS** | 7.0 is the default; 8.0 is optional, tested in CI, with an automated 7.0 upgrade | [Zabbix 8.0](#zabbix-80) |
| **Grafana with the Zabbix plugin** | Dashboards and alert rules, reading Zabbix through a read-only user | [Alerts](#alerts) |
| **MCP for AI assistants** | A single MCP server (one URL, one token) that combines the official Zabbix and Grafana MCP servers, read-only and bound to `127.0.0.1`, so Claude and other assistants on your machine can query your monitoring | [MCP](#mcp-zabbix-and-grafana-for-ai-assistants) |

## Platforms

**Linux is the default platform.** The scripts are POSIX `sh`, the shortcuts use `make`, and CI brings the whole stack up (smoke test) on Ubuntu for every change. For production, run it on a Linux server. macOS and Windows work too, as alternatives for study and testing (see [Other platforms](#other-platforms)).

## Quick start on Linux (default)

Commands use `apt` (Ubuntu, Debian); on Fedora, RHEL, Rocky or Alma use `dnf`. You need 2 vCPU, 4 GB RAM and internet access on first start (Grafana downloads the Zabbix plugin).

1. **Install Docker Engine 24+ with the compose plugin, git and make.** Follow the official guide for your distro ([Ubuntu](https://docs.docker.com/engine/install/ubuntu/), [Debian](https://docs.docker.com/engine/install/debian/), [Fedora](https://docs.docker.com/engine/install/fedora/), [RHEL](https://docs.docker.com/engine/install/rhel/)), or for a lab:

   ```bash
   curl -fsSL https://get.docker.com | sudo sh   # lab only; use your distro's guide in production
   sudo systemctl enable --now docker
   sudo apt install -y git make                  # Fedora/RHEL: sudo dnf install -y git make
   docker compose version                        # must answer; "unknown command" means the plugin is missing
   ```

   Avoid the distro's `docker.io` package and the old hyphenated `docker-compose`; use `docker-ce` and `docker-compose-plugin` from Docker's repository.

2. **Use Docker without sudo (optional).** `sudo usermod -aG docker "$USER"`, then `newgrp docker` (or log out and back in) and check with `docker run --rm hello-world`. Members of the `docker` group are effectively root; on shared servers keep using `sudo` or [rootless Docker](https://docs.docker.com/engine/security/rootless/).

3. **Clone:**

   ```bash
   mkdir -p ~/projects && cd ~/projects
   git clone https://github.com/<your-user>/zabbix-grafana-MCP.git
   cd zabbix-grafana-MCP
   ```

4. **Generate passwords:** `make env` creates `.env` (mode `600`, never overwritten) with random passwords (without make: `./scripts/generate-secrets.sh`).

5. **Start:** `make up` (checks the passwords and runs `docker compose up -d`). `docker compose ps -a` should show `zabbix-admin-password` and `zabbix-init` as `Exited (0)` after 1 to 2 minutes; follow with `make logs`.

6. **Open:**
   - Zabbix: http://localhost:8080 (user `Admin`, password `ZABBIX_ADMIN_PASSWORD` from `.env`)
   - Grafana: http://localhost:3000 (`GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` from `.env`)

   The web UIs listen on `127.0.0.1` only, since they speak plain HTTP. On a headless server, tunnel from your computer with `ssh -L 8080:localhost:8080 -L 3000:localhost:3000 user@server`. For direct network access, put an HTTPS reverse proxy in front or set `BIND_ADDRESS=0.0.0.0` in `.env`.

7. **Monitor the server itself (optional).** The bundled `zabbix-agent` container monitors itself, not the Linux host. Install Zabbix Agent 2 on the host from the [Zabbix repository](https://www.zabbix.com/download?zabbix=7.0&components=agent_2) with `Server=127.0.0.1,172.16.0.0/12` and `ServerActive=127.0.0.1:10051`, then add the host in Zabbix with its LAN IP, port `10050`, and the **Linux by Zabbix agent** template.

The stack comes back after a reboot (`restart: unless-stopped` plus `systemctl enable docker`). Shortcuts: `make help`, `make logs`, `make backup`, `make down`, `make reset` (deletes volumes).

A one-shot `zabbix-admin-password` container replaces the default Admin password directly in the database before the web UI starts, so Admin is never reachable with `zabbix`. Then a one-shot `zabbix-init` container creates a read-only, API-only `grafana` user that Grafana uses to query Zabbix, and points the built-in "Zabbix server" host to the agent container.

Port 10051 (trapper) listens on all interfaces for active agents. Docker-published ports bypass UFW/firewalld, so filter it in the `DOCKER-USER` iptables chain or set `ZABBIX_SERVER_BIND_ADDRESS`, and enable PSK encryption per host (see "Protegendo a porta 10051" in the Portuguese README).

### Zabbix 8.0

Zabbix 7.0 LTS is the default. Zabbix 8.0 LTS is also supported and tested in CI: set `ZABBIX_VERSION=alpine-8.0.0` in `.env` (Docker Compose), or add `- ../../components/zabbix-8` under `components:` in your Kubernetes overlay. To upgrade an existing 7.0 Compose install, run `make upgrade-8`: it backs up the database, switches `.env` to 8.0, waits for the in-place database upgrade and reruns the init. `./scripts/upgrade-zabbix-8.sh --rollback <dump>` goes back to 7.0 by restoring that backup. Details in the Portuguese README, section "Zabbix 8.0".

## MCP: Zabbix and Grafana for AI assistants

The assistant connects to **one MCP server**, `mcp-gateway` (`127.0.0.1:8765/mcp`), with **one token** (`MCP_TOKEN`). Behind it run the official [Zabbix MCP server](https://hub.docker.com/r/zabbix/zabbix-mcp-server) (requires Zabbix 8.0) and the official [Grafana MCP server](https://github.com/grafana/mcp-grafana), on the internal Docker network only. Their tools are exposed as `zabbix_*` and `grafana_*`. The gateway is this repo's `mcp-gateway/gateway.py`, plain Python standard library.

`make mcp` creates a read-only Zabbix user `mcp` with an API token and a Grafana `mcp` service account (Viewer), generates the internal Grafana MCP token and `MCP_TOKEN`, stores them in `.env`, builds and starts the three containers, checks that requests without the token are refused and prints ready-to-paste client configs (`make mcp-config` prints them again).

- **No exposed ports:** only `mcp-gateway` publishes a port, on `127.0.0.1`, regardless of `BIND_ADDRESS`. It also rejects foreign `Host`/`Origin` headers (DNS rebinding).
- **One token for the assistant;** the Zabbix and Grafana tokens never leave the containers. The internal Grafana MCP still requires its own token.
- **Read-only:** Zabbix exposes only `*_get` tools (minus item keys, macros, interfaces and raw history); Grafana runs with `--disable-write` and only the dashboard, alerting, annotation, datasource and search tools. Every Zabbix call shows up in the Zabbix audit log as user `mcp`.
- On Zabbix 7.0 only the `grafana_*` tools are available.

Claude Code:

```bash
claude mcp add --transport http zabbix-grafana http://127.0.0.1:8765/mcp --header "Authorization: Bearer <MCP_TOKEN>"
```

Claude Desktop uses [`mcp-remote`](https://www.npmjs.com/package/mcp-remote) (needs Node.js); `make mcp-config` prints the `claude_desktop_config.json` block. ChatGPT and Claude on the web need a public HTTPS URL, which this local mode deliberately does not provide; OAuth plus an optional outbound tunnel is planned, as are cross-system tools (Zabbix, Grafana and Kubernetes).

**Kubernetes:** add `../../components/zabbix-8` and `../../components/mcp` under `components:` in your overlay. It runs one `mcp` pod with the gateway and, inside the pod on `127.0.0.1` only, the official Zabbix and Grafana MCP servers plus [`containers/kubernetes-mcp-server`](https://github.com/containers/kubernetes-mcp-server), which adds read-only `k8s_*` tools (pods, logs, events and resources) through a ServiceAccount bound to the `view` role in the `monitoring` namespace only (no Secrets). The Service is ClusterIP only and no other pod may reach it. The assistant token is `MCP_PASSWORD` in `kubernetes/base/secrets.env`; then run `make k8s-mcp` (port-forward to `127.0.0.1:8765`) and `make k8s-mcp-config`.

## Kubernetes on Linux

Any of these works on a Linux machine, and all ship a default StorageClass: [k3s](https://docs.k3s.io/quick-start) (a real Linux server; includes Traefik for the `ingress` overlay; NodePorts on `http://<server-ip>:30080` and `:30300`), [kind](https://kind.sigs.k8s.io/docs/user/quick-start/) (quick tests inside Docker; use port-forward) or [minikube](https://minikube.sigs.k8s.io/docs/start/) (`http://$(minikube ip):30080`). With k3s:

```bash
curl -sfL https://get.k3s.io | sh -                    # installs k3s (includes kubectl)
mkdir -p ~/.kube && sudo k3s kubectl config view --raw > ~/.kube/config && chmod 600 ~/.kube/config
make k8s-secrets
kubectl apply -k kubernetes/overlays/local
kubectl -n monitoring get pods -w
```

See [Kubernetes](#kubernetes) below for the overlays.

## Other platforms

### Windows

Recommended: Docker Desktop with WSL 2; open the Ubuntu (WSL) terminal, clone inside Linux (`~/projects`, not `/mnt/c/...`) and follow the Linux quick start from step 3. Without WSL (no `make`, no `sh`), create the `.env` with PowerShell instead: `powershell -ExecutionPolicy Bypass -File scripts\generate-secrets.ps1` (add `-Target k8s` for Kubernetes), then `docker compose up -d`. The Portuguese README, section "Usando no Windows", lists PowerShell equivalents for every `make` shortcut.

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
