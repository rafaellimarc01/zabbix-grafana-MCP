# Zabbix + Grafana: ambiente pronto (Docker e Kubernetes)

[English version](README.en.md)

Modelo pronto para subir um ambiente de monitoramento com **Zabbix** e **Grafana** em poucos minutos, tanto com **Docker Compose** quanto em **Kubernetes** (Kustomize). O Grafana já vem com o plugin do Zabbix instalado, a fonte de dados configurada e dashboards prontos. O objetivo do projeto é facilitar a criação de monitoramentos em um ambiente seguro, escalável e com segurança.

Use como ponto de partida para o seu laboratório, para estudos ou como base de um ambiente real. A plataforma padrão é o **Linux**; macOS e Windows também funcionam (veja [Plataformas](#plataformas)).

## O que vem no pacote

| Componente | Imagem | Para que serve |
|---|---|---|
| PostgreSQL | `postgres:16-alpine` | Banco de dados do Zabbix |
| Zabbix Server | `zabbix/zabbix-server-pgsql:alpine-7.0.32` | Coleta, triggers e alertas (Zabbix 7.0 LTS) |
| Zabbix Web | `zabbix/zabbix-web-nginx-pgsql:alpine-7.0.32` | Interface web e API do Zabbix |
| Zabbix Agent 2 | `zabbix/zabbix-agent2:alpine-7.0.32` | Monitora o host "Zabbix server" que já vem cadastrado |
| zabbix-admin-password | `postgres:16-alpine` | Tarefa única: troca a senha padrão do Admin direto no banco, antes de a interface web subir |
| zabbix-init | `zabbix/zabbix-web-nginx-pgsql:alpine-7.0.32` | Tarefa única: cria o usuário somente leitura do Grafana e liga o agente ao host |
| postgres-backup | `postgres:16-alpine` | Backup automático diário do banco do Zabbix (`pg_dump`), com retenção de 7 dias |
| Grafana | `grafana/grafana:12.4.16` | Dashboards, com o plugin [Zabbix para Grafana](https://grafana.com/grafana/plugins/alexanderzobnin-zabbix-app/) |

Dashboards incluídos (pasta **Zabbix** no Grafana):

- **Zabbix - Visão geral dos hosts**: problemas ativos, CPU, memória, load, rede e disco, com filtro por grupo e host.
- **Zabbix - Saúde do servidor**: valores processados por segundo, filas e uso dos processos internos do Zabbix.

Alertas incluídos (pasta **Zabbix** em **Alerting → Alert rules**): host indisponível, CPU alta, memória alta, disco quase cheio e fila do Zabbix acumulada. Veja [Alertas](#alertas).

```
.
├── docker-compose.yml          # ambiente completo com Docker
├── .env.example                # variáveis (as senhas são geradas por make env)
├── grafana/
│   ├── provisioning/           # plugin, datasource, dashboards e regras de alerta
│   ├── alerting-examples/      # notificação por e-mail ou Telegram (ative um)
│   └── dashboards/             # JSON dos dashboards (adicione os seus aqui)
├── kubernetes/
│   ├── base/                   # manifests (Kustomize)
│   ├── tools/                  # pod temporário para copiar/restaurar backups
│   └── overlays/
│       ├── local/              # NodePort, para kind/minikube/k3d/Docker Desktop
│       ├── gateway/            # Gateway API com HTTPS (recomendado)
│       └── ingress/            # Ingress com HTTPS (Traefik por padrão)
├── scripts/
│   ├── zabbix-init.sh          # configuração inicial via API do Zabbix
│   ├── postgres-backup.sh      # backup automático e restauração do banco
│   ├── zabbix-admin-password.sh # troca a senha padrão do Admin no banco
│   ├── generate-secrets.sh     # gera .env / secrets.env com senhas aleatórias
│   ├── generate-secrets.ps1    # o mesmo, para o PowerShell do Windows
│   ├── check-secrets.sh        # recusa senhas vazias, curtas ou de exemplo
│   └── sync-k8s-files.sh       # copia grafana/ para o Kubernetes
├── SECURITY.md                 # o que já vem protegido e o que fica com você
└── Makefile                    # atalhos (make help)
```

## Plataformas

O ambiente foi feito para **Linux**, que é a plataforma padrão: os scripts são `sh`, os atalhos usam `make` e o CI sobe o ambiente completo (smoke test) no Ubuntu a cada mudança. Em produção, rode num servidor Linux.

| Plataforma | Situação | Onde ler |
|---|---|---|
| **Linux** (Ubuntu, Debian, Fedora, RHEL e derivados) | **Padrão**, testado de ponta a ponta no CI | [Início rápido no Linux](#início-rápido-no-linux-padrão) |
| macOS (Intel e Apple Silicon) | Alternativa, para estudo e testes; scripts testados no CI | [Usando no macOS](#usando-no-macos-intel-e-apple-silicon) |
| Windows 10/11 | Alternativa, para estudo e testes; script PowerShell testado no CI | [Usando no Windows](#usando-no-windows) |

## Requisitos

- **Docker:** Docker Engine 24+ com o plugin `docker compose`. No Mac e no Windows, o Docker Desktop.
- **Ferramentas:** `git` e `make` (o `make` é opcional; todo atalho tem o comando equivalente).
- **Kubernetes (opcional):** um cluster 1.27+ com StorageClass padrão e `kubectl` 1.27+ (já traz o Kustomize).
- Mínimo recomendado: 2 vCPU e 4 GB de RAM.
- Acesso à internet no primeiro start (o Grafana baixa o plugin do Zabbix de grafana.com).

## Início rápido no Linux (padrão)

Passo a passo num Linux recém-instalado. Os comandos usam `apt` (Ubuntu e Debian); no Fedora, RHEL, Rocky e Alma, troque por `dnf`.

### 1. Instale o Docker Engine, o git e o make

Siga o guia oficial da sua distribuição: [Ubuntu](https://docs.docker.com/engine/install/ubuntu/), [Debian](https://docs.docker.com/engine/install/debian/), [Fedora](https://docs.docker.com/engine/install/fedora/) ou [RHEL](https://docs.docker.com/engine/install/rhel/). Ele instala o Docker Engine junto com o plugin `docker compose`. Para um laboratório, o script oficial resolve em um comando:

```bash
curl -fsSL https://get.docker.com | sudo sh     # só para laboratório; em produção, use o guia da distribuição
sudo systemctl enable --now docker              # sobe o Docker agora e a cada boot

sudo apt install -y git make                    # Fedora/RHEL: sudo dnf install -y git make
```

Confira as versões:

```bash
docker --version            # 24 ou mais nova
docker compose version      # precisa responder; se der "unknown command", falta o plugin compose
```

> Evite o pacote `docker.io` da distribuição e o antigo `docker-compose` (com hífen): costumam vir desatualizados e sem o plugin `docker compose`. Os pacotes `docker-ce` e `docker-compose-plugin` do repositório oficial do Docker são os testados aqui.

### 2. Use o Docker sem sudo (opcional)

Por padrão, só o root fala com o Docker. Para rodar `docker` e `make` com o seu usuário:

```bash
sudo usermod -aG docker "$USER"
newgrp docker               # vale para este terminal; nos outros, saia e entre de novo na sessão
docker run --rm hello-world # deve funcionar sem sudo
```

> Quem está no grupo `docker` tem, na prática, poder de root na máquina. Num servidor compartilhado, prefira continuar com `sudo` ou use o [modo rootless do Docker](https://docs.docker.com/engine/security/rootless/).

### 3. Clone o repositório

```bash
mkdir -p ~/projetos && cd ~/projetos
git clone https://github.com/<seu-usuario>/zabbix-grafana-stack.git
cd zabbix-grafana-stack
```

### 4. Gere as senhas

```bash
make env                    # cria o .env com senhas aleatórias (sem make: ./scripts/generate-secrets.sh)
```

O `.env` é criado com permissão `600` (só o seu usuário lê) e nunca é sobrescrito. As senhas ficam nele; guarde-as num cofre.

### 5. Suba o ambiente

```bash
make up                     # gera o .env se faltar, confere as senhas e roda docker compose up -d
docker compose ps -a        # zabbix-admin-password e zabbix-init devem aparecer como "Exited (0)"
```

O primeiro start leva de 1 a 2 minutos (o Zabbix cria o banco e o Grafana baixa o plugin). Para acompanhar: `make logs`.

### 6. Acesse

| Serviço | Endereço | Usuário | Senha |
|---|---|---|---|
| Zabbix | http://localhost:8080 | `Admin` | `ZABBIX_ADMIN_PASSWORD` do `.env` |
| Grafana | http://localhost:3000 | `GRAFANA_ADMIN_USER` | `GRAFANA_ADMIN_PASSWORD` do `.env` |
| Zabbix trapper (agentes externos) | `<ip-do-servidor>:10051` | | |

Para ver as senhas: `grep -E 'ADMIN_(USER|PASSWORD)' .env`.

> Por segurança, o Zabbix web e o Grafana só aceitam conexões do próprio computador (`127.0.0.1`), porque falam HTTP sem criptografia. Num servidor sem interface gráfica, abra um túnel SSH a partir do seu computador (`ssh -L 8080:localhost:8080 -L 3000:localhost:3000 usuario@servidor`) e acesse os mesmos endereços acima. Para acesso direto pela rede, coloque um proxy reverso com HTTPS na frente ou mude `BIND_ADDRESS=0.0.0.0` no `.env`, ciente de que as senhas vão trafegar sem TLS.

> Se preencher as senhas à mão: mínimo de 12 caracteres, e a do Admin do Zabbix **não pode conter** "Admin" nem "Zabbix" (regra do próprio Zabbix). Se algo falhar no primeiro start, veja `docker compose logs zabbix-admin-password zabbix-init`.

> A senha padrão `zabbix` do Admin é trocada direto no banco **antes** de a interface web subir (serviço `zabbix-admin-password`). Assim o Admin nunca fica acessível com a senha padrão, nem por alguns segundos.

### 7. Monitore o próprio servidor (opcional)

O container `zabbix-agent` monitora o próprio container, não o Linux onde o Docker roda. Para monitorar o servidor, instale o Zabbix Agent 2 nele pelo [repositório oficial do Zabbix](https://www.zabbix.com/download?zabbix=7.0&components=agent_2) e, no `/etc/zabbix/zabbix_agent2.conf`, use `Server=127.0.0.1,172.16.0.0/12` (as redes do Docker) e `ServerActive=127.0.0.1:10051`. Depois cadastre o host no Zabbix com o IP do servidor na rede local, porta `10050`, e o template **Linux by Zabbix agent** (veja [Monitorando seus servidores](#monitorando-seus-servidores)). Se o firewall do host bloquear a porta 10050, libere-a para `172.16.0.0/12`.

### Comandos úteis

```bash
make help     # lista os atalhos
make logs     # acompanha os logs
make backup   # faz um backup do banco agora (veja "Backup do banco")
make down     # para tudo, mantendo os dados
make reset    # para e APAGA os volumes (começa do zero)
```

O ambiente volta sozinho depois de um reboot (os containers usam `restart: unless-stopped` e o Docker sobe com o sistema por causa do `systemctl enable`).

### Kubernetes no Linux

Para testar os manifests numa máquina Linux, qualquer um destes clusters serve. Todos já vêm com uma StorageClass padrão.

| Cluster | Bom para | Acesso com o overlay `local` |
|---|---|---|
| [k3s](https://docs.k3s.io/quick-start) | Um servidor Linux de verdade (leve, já traz o Traefik para o overlay `ingress`) | `http://<ip-do-servidor>:30080` e `:30300` |
| [kind](https://kind.sigs.k8s.io/docs/user/quick-start/) | Testes rápidos e CI, roda dentro do Docker | port-forward (abaixo) |
| [minikube](https://minikube.sigs.k8s.io/docs/start/) | Estudo, com addons prontos | `http://$(minikube ip):30080` e `:30300` |

Exemplo com o k3s, do zero:

```bash
curl -sfL https://get.k3s.io | sh -                       # instala o k3s como serviço (já traz o kubectl)
mkdir -p ~/.kube
sudo k3s kubectl config view --raw > ~/.kube/config       # deixa o kubectl usar o k3s sem sudo
chmod 600 ~/.kube/config

make k8s-secrets                                          # gera kubernetes/base/secrets.env
kubectl apply -k kubernetes/overlays/local
kubectl -n monitoring get pods -w                         # espere todos ficarem Running/Completed
```

Com o kind: `kind create cluster`, depois os mesmos `make k8s-secrets` e `kubectl apply -k kubernetes/overlays/local`, e acesse por port-forward. Os detalhes dos overlays e do acesso estão em [Início rápido com Kubernetes](#início-rápido-com-kubernetes).

## Outras plataformas

O Linux é o caminho padrão. As seções abaixo explicam o que muda para usar o modelo no Mac ou no Windows, normalmente em estudo e testes.

### Usando no macOS (Intel e Apple Silicon)

O modelo funciona igual no Mac. Todas as imagens (Zabbix, Grafana e PostgreSQL) têm versão nativa para `arm64`, então nos Macs M1/M2/M3/M4 nada roda emulado.

1. Instale o [Docker Desktop para Mac](https://docs.docker.com/desktop/setup/install/mac-install/) (ou [OrbStack](https://orbstack.dev) / [Colima](https://github.com/abiosoft/colima)). Em **Settings → Resources**, deixe pelo menos 4 GB de memória para o Docker.
2. Instale o `make` e o `git` com as ferramentas de linha de comando da Apple: `xcode-select --install`. Os scripts usam só comandos que já vêm no macOS (testado no CI em `macos-latest`).
3. Clone o repositório **dentro da sua pasta de usuário** (ex.: `~/projetos`). O Docker Desktop só compartilha `/Users`, `/Volumes`, `/private` e `/tmp` com os containers; fora disso o Grafana e o `zabbix-init` falham com `mounts denied`. Para usar outra pasta, adicione-a em **Settings → Resources → File sharing**.
4. Siga o [início rápido](#início-rápido-no-linux-padrão) a partir do passo 3 (clonar): `make up`.

Bom saber:

- O container `zabbix-agent` monitora a máquina virtual Linux do Docker Desktop, não o seu Mac. Para monitorar o Mac, instale o [Zabbix Agent para macOS](https://www.zabbix.com/download_agents) com `Server=127.0.0.1,172.16.0.0/12`, `ServerActive=127.0.0.1:10051` e cadastre o host no Zabbix com a interface `host.docker.internal`, porta `10050`, e o template **macOS by Zabbix agent**.
- O Finder cria arquivos `.DS_Store` nas pastas. Eles já estão no `.gitignore` e o `sync-k8s-files.sh` ignora todos eles.
- Para o Kubernetes, o cluster do Docker Desktop (**Settings → Kubernetes**) serve: com o overlay `local`, os NodePorts ficam em `http://localhost:30080` e `http://localhost:30300`. Ele não aplica NetworkPolicies, então use só para testes.
- Para rodar o `make validate`: `brew install shellcheck yamllint kubectl`.

### Usando no Windows

O modelo funciona no Windows 10/11 com o [Docker Desktop](https://docs.docker.com/desktop/setup/install/windows-install/) (backend WSL 2). Há dois caminhos:

**Com WSL (recomendado).** Abra o terminal do Ubuntu (WSL), clone o repositório dentro do Linux (ex.: `~/projetos`, não em `/mnt/c/...`, que é bem mais lento) e siga o [início rápido](#início-rápido-no-linux-padrão) normalmente, com `make`. Instale o `make` se faltar: `sudo apt install make`.

**Só com PowerShell (sem WSL e sem `make`).** O `make` e os scripts `.sh` não rodam no PowerShell nem no CMD, então use o script PowerShell para gerar as senhas:

```powershell
git clone https://github.com/<seu-usuario>/zabbix-grafana-stack.git
cd zabbix-grafana-stack

powershell -ExecutionPolicy Bypass -File scripts\generate-secrets.ps1   # gera o .env com senhas aleatórias
docker compose up -d
docker compose ps -a
```

Para o Kubernetes: `powershell -ExecutionPolicy Bypass -File scripts\generate-secrets.ps1 -Target k8s` e depois `kubectl apply -k kubernetes/overlays/local`.

Equivalentes dos atalhos do `make` no PowerShell:

| `make` | PowerShell |
|---|---|
| `make env` | `powershell -ExecutionPolicy Bypass -File scripts\generate-secrets.ps1` |
| `make up` | `docker compose up -d` |
| `make logs` | `docker compose logs -f --tail=100` |
| `make backup` | `docker compose exec postgres-backup sh /postgres-backup.sh once` |
| `make backup-list` | `docker compose exec postgres-backup sh /postgres-backup.sh list` |
| `make down` | `docker compose down` |
| `make reset` | `docker compose down -v` |

Bom saber:

- O `.gitattributes` mantém os scripts com fim de linha LF mesmo no Windows. Se você editar `.env` ou scripts, configure o editor para LF (no VS Code, canto inferior direito); com CRLF os scripts falham dentro dos containers.
- O script PowerShell grava o `.env` em UTF-8 sem BOM e com LF, e deixa o arquivo acessível só para o seu usuário.
- O container `zabbix-agent` monitora a máquina virtual do Docker Desktop, não o Windows. Para monitorar o Windows, instale o [Zabbix Agent 2 para Windows](https://www.zabbix.com/download_agents) e cadastre o host com o template **Windows by Zabbix agent**.

## Início rápido com Kubernetes

Tudo é criado no namespace `monitoring`.

```bash
make k8s-secrets          # gera kubernetes/base/secrets.env com senhas aleatórias

# Cluster local (k3s, kind, minikube, k3d, Docker Desktop): expõe NodePorts
kubectl apply -k kubernetes/overlays/local

# Produção, com Gateway API (recomendado): edite a classe e os domínios em
# kubernetes/overlays/gateway/gateway.yaml e aplique
kubectl apply -k kubernetes/overlays/gateway

# Ou com Ingress (Traefik por padrão): edite kubernetes/overlays/ingress/ingress.yaml
kubectl apply -k kubernetes/overlays/ingress

kubectl -n monitoring get pods -w
```

Overlay `local` (só para laboratório: publica HTTP sem TLS em todos os nós):

| Serviço | Endereço |
|---|---|
| Zabbix | `http://<ip-do-nó>:30080` |
| Grafana | `http://<ip-do-nó>:30300` |
| Zabbix trapper | `<ip-do-nó>:30051` |

Sem NodePort acessível (ex.: kind sem port mapping), use port-forward:

```bash
kubectl -n monitoring port-forward svc/zabbix-web 8080:8080
kubectl -n monitoring port-forward svc/grafana 3000:3000
```

Observações:

- O overlay `gateway` usa a [Gateway API](https://gateway-api.sigs.k8s.io/), com HTTPS e redirecionamento de HTTP para HTTPS. Precisa de um controlador instalado (Envoy Gateway, Traefik, Cilium, Istio, NGINX Gateway Fabric...): troque o `gatewayClassName` (`kubectl get gatewayclass`) e os domínios em `gateway.yaml`.
- O overlay `ingress` vem pronto para o Traefik (padrão do k3s), atendendo só em HTTPS. Para outro controlador, troque a classe e as anotações em `ingress.yaml`. O ingress-nginx foi aposentado em março de 2026 e não recebe mais correções de segurança; se ainda usa, planeje a troca.
- Nos dois overlays, crie o Secret `zabbix-grafana-tls` com o seu certificado ou use o cert-manager (veja os comentários nos arquivos).
- O namespace usa Pod Security `baseline` e NetworkPolicies que só liberam o tráfego necessário (precisam de um CNI com suporte, como Calico ou Cilium; o Kubernetes do Docker Desktop não aplica NetworkPolicies). Nos overlays `gateway` e `ingress`, o Zabbix web e o Grafana só aceitam conexões do controlador de entrada, reconhecido pelo namespace (`envoy-gateway-system`, `traefik`, `kube-system`, `nginx-gateway`, `istio-ingress`, `istio-system`, `haproxy-controller`, `ingress-nginx`). Se o seu controlador estiver em outro namespace, rotule-o: `kubectl label namespace <namespace> zabbix-grafana/ingress-controller=true`. Sem isso, o acesso dá erro 502/504.
- O PostgreSQL usa um volume de 10 Gi e o Grafana um de 2 Gi, na StorageClass padrão do cluster.
- A senha padrão do Admin é trocada no banco por um init container do `zabbix-web`, antes de a interface subir. O resto da configuração (usuário `grafana` e agente) roda num init container do Grafana a cada start do pod, então `kubectl apply -k` pode ser repetido quantas vezes quiser. Para rodar de novo sem mudar nada: `kubectl -n monitoring rollout restart deploy/grafana`.
- O Kustomize não lê arquivos fora da própria pasta, então `kubernetes/base/files/` tem uma cópia de `grafana/` e dos scripts. Depois de mudar algo neles, rode `./scripts/sync-k8s-files.sh` (o CI acusa se esquecer).
- Para remover: `kubectl delete -k kubernetes/overlays/local`. Os PVCs do PostgreSQL ficam; apague-os à mão se quiser zerar os dados.

## Backup do banco

O banco do Zabbix (hosts, templates, histórico, usuários) tem backup automático com `pg_dump` nos dois modos de instalação. Os arquivos ficam no formato custom do PostgreSQL (`zabbix-AAAAMMDD-HHMMSS.dump`, já comprimido) e cada backup é conferido com `pg_restore --list` antes de ser guardado. Os mais antigos que a retenção são apagados, mas só depois de um backup novo dar certo, então o último sempre fica.

O Grafana não entra no backup: a fonte de dados e os dashboards vêm dos arquivos de `grafana/`, que já estão no Git. Se você criar dashboards pela interface, exporte o JSON para `grafana/dashboards/`.

> O backup fica no mesmo servidor (ou cluster) do banco. Para se proteger de perder a máquina, copie os arquivos para fora dela de vez em quando (veja abaixo).

### Docker Compose

O serviço `postgres-backup` sobe junto com o resto. Ele faz um backup logo ao iniciar (se não houver um das últimas 24 h) e depois todo dia às `BACKUP_TIME`, guardando `BACKUP_KEEP_DAYS` dias no volume `postgres-backups`. Os dois ficam no `.env` (padrão: `02:00` e `7`). O serviço aparece como `healthy` enquanto houver um backup das últimas 25 h.

Os comandos abaixo funcionam no Linux, no macOS e no Windows com WSL. No PowerShell, use os comandos sem `make` que estão nos comentários (o `docker compose` funciona igual em todos):

```bash
# Backup agora (sem make: docker compose exec postgres-backup sh /postgres-backup.sh once)
make backup

# Lista os backups (sem make: docker compose exec postgres-backup sh /postgres-backup.sh list)
make backup-list

# Copia todos os backups para a pasta ./backups do seu computador
docker compose cp postgres-backup:/var/lib/postgresql/backups ./backups

# Acompanha o que o serviço fez
docker compose logs postgres-backup
```

**Restaurar** (substitui todos os dados atuais do Zabbix pelos do backup):

```bash
# 1. Pare quem usa o banco
docker compose stop zabbix-server zabbix-web grafana

# 2. Restaure um backup do volume (o nome sai do "make backup-list")
docker compose exec postgres-backup sh /postgres-backup.sh restore zabbix-20260101-020000.dump

# 3. Suba tudo de novo
docker compose up -d
```

Para restaurar um arquivo que está no seu computador (por exemplo, vindo de outra máquina), copie-o para o volume e rode a restauração com `-u 0`, porque o arquivo copiado chega com outro dono:

```bash
docker compose cp zabbix-20260101-020000.dump postgres-backup:/var/lib/postgresql/backups/
docker compose exec -u 0 postgres-backup sh /postgres-backup.sh restore zabbix-20260101-020000.dump
```

As senhas do banco não mudam com a restauração. Para restaurar em outra instalação, ela precisa estar na mesma versão do Zabbix (ou mais nova: o Zabbix atualiza o banco sozinho ao iniciar).

### Kubernetes

O CronJob `postgres-backup` roda todo dia às 02:00 (`timeZone` em `kubernetes/base/postgres-backup.yaml`) e guarda 7 dias (`BACKUP_KEEP_DAYS`) no PVC `postgres-backups`, de 10 Gi. A NetworkPolicy do PostgreSQL só libera os pods com o rótulo `app.kubernetes.io/name: postgres-backup`.

```bash
# Backup agora
kubectl -n monitoring create job --from=cronjob/postgres-backup backup-manual
kubectl -n monitoring logs -f job/backup-manual

# Últimas execuções
kubectl -n monitoring get jobs -l app.kubernetes.io/name=postgres-backup
```

Para listar, copiar ou restaurar, crie o pod temporário `postgres-backup-shell`, que monta o PVC dos backups e se encerra sozinho em 1 hora. Como o PVC é `ReadWriteOnce`, evite fazer isso no horário do backup.

```bash
kubectl -n monitoring apply -f kubernetes/tools/postgres-backup-shell.yaml
kubectl -n monitoring wait --for=condition=Ready pod/postgres-backup-shell

# Listar e copiar para o seu computador
kubectl -n monitoring exec postgres-backup-shell -- ls -lh /backups
kubectl -n monitoring cp postgres-backup-shell:/backups/zabbix-20260101-020000.dump ./zabbix-20260101-020000.dump

# Restaurar (para quem usa o banco antes e volta depois)
kubectl -n monitoring scale deploy zabbix-server zabbix-web grafana --replicas=0
kubectl -n monitoring exec postgres-backup-shell -- pg_restore --clean --if-exists --no-owner \
  --single-transaction --exit-on-error -d zabbix /backups/zabbix-20260101-020000.dump
kubectl -n monitoring scale deploy zabbix-server zabbix-web grafana --replicas=1

kubectl -n monitoring delete pod postgres-backup-shell
```

Para restaurar um arquivo do seu computador, envie-o antes com `kubectl -n monitoring cp ./arquivo.dump postgres-backup-shell:/backups/arquivo.dump`.

## Monitorando seus servidores

Instale o Zabbix Agent 2 nas máquinas que quer monitorar e aponte para o servidor:

```ini
# /etc/zabbix/zabbix_agent2.conf
Server=<ip-do-servidor-zabbix>
ServerActive=<ip-do-servidor-zabbix>:10051
Hostname=<nome-do-host>
```

Depois cadastre o host no Zabbix (**Coleta de dados → Hosts → Criar host**) com o template **Linux by Zabbix agent** (ou **Windows by Zabbix agent**). Ele aparece sozinho no dashboard do Grafana, no filtro de grupo e host.

### Protegendo a porta 10051 (trapper)

A porta 10051 fica aberta para os agentes ativos e proxies, e por padrão o tráfego vai sem criptografia. Dois cuidados:

**1. Firewall: o Docker passa por cima do UFW e do firewalld.** As portas publicadas pelo Docker são liberadas direto no iptables, antes das regras do UFW/firewalld, então um `ufw deny 10051` **não** bloqueia nada. Use uma destas opções:

- Escute só na interface da rede dos agentes: `ZABBIX_SERVER_BIND_ADDRESS=<ip-do-servidor-nessa-rede>` no `.env`.
- Ou filtre na chain `DOCKER-USER`, que o Docker respeita (troque a rede e a interface):

  ```bash
  sudo iptables -I DOCKER-USER -i eth0 -p tcp --dport 10051 ! -s 10.0.0.0/8 -j DROP
  ```

  Guarde a regra para sobreviver a reinicializações (ex.: `iptables-persistent`). Veja a [documentação do Docker](https://docs.docker.com/engine/network/packet-filtering-firewalls/).

**2. Criptografia com PSK.** Com PSK, só agentes que conhecem a chave conversam com o servidor, e os dados vão criptografados. Não precisa mudar nada no servidor; é por host:

1. No host monitorado, gere a chave: `openssl rand -hex 32 | sudo tee /etc/zabbix/zabbix_agent2.psk` (e `sudo chmod 640` nela, dono `zabbix`).
2. No `zabbix_agent2.conf`: `TLSConnect=psk`, `TLSAccept=psk`, `TLSPSKIdentity=<nome-unico>` e `TLSPSKFile=/etc/zabbix/zabbix_agent2.psk`. Reinicie o agente.
3. No Zabbix, no host: aba **Criptografia**, marque **PSK** em "Conexões com o host" e "Conexões do host", e preencha a mesma identidade e a chave.

Detalhes na [documentação de criptografia do Zabbix](https://www.zabbix.com/documentation/7.0/en/manual/encryption/using_pre_shared_keys).

Para monitorar o próprio cluster Kubernetes (nós, pods, API), use a [integração oficial do Zabbix com Kubernetes](https://www.zabbix.com/integrations/kubernetes) (Helm chart) junto com este ambiente.

## Alertas

O Grafana já sobe com 5 regras de alerta prontas, em `grafana/provisioning/alerting/zabbix-rules.yaml`. Elas leem os dados do Zabbix e valem para todo host com os templates padrão (**Linux by Zabbix agent** e **Zabbix server health**), gerando um alerta separado por host (e por disco):

| Regra | Item do Zabbix | Dispara quando | Severidade |
|---|---|---|---|
| Host indisponível | `Zabbix agent availability` | agente indisponível por 3 min | `critical` |
| CPU alta | `CPU utilization` | média de 10 min acima de 90% por 5 min | `warning` |
| Memória alta | `Memory utilization` | média de 10 min acima de 90% por 5 min | `warning` |
| Disco quase cheio | `FS [*]: Space: Used, in %` | acima de 90% por 10 min | `warning` |
| Fila do Zabbix acumulada | `Queue over 10 minutes` | mais de 100 itens atrasados por 10 min | `warning` |

Se o Grafana não conseguir consultar o Zabbix, as regras também alertam (estado `Error`), para a falha não passar em branco.

Sem configurar nada, os alertas aparecem só na tela do Grafana (**Alerting → Alert rules**). Para receber notificações, ative **um** dos exemplos de `grafana/alerting-examples/`:

**E-mail**

1. No `.env`, preencha `GRAFANA_SMTP_HOST` (ex.: `smtp.gmail.com:587`), `GRAFANA_SMTP_USER`, `GRAFANA_SMTP_PASS`, `GRAFANA_SMTP_FROM` e `ALERT_EMAIL_TO` (vários destinatários separados por `;`), e mude `GRAFANA_SMTP_ENABLED=true`.
2. `cp grafana/alerting-examples/email.yaml grafana/provisioning/alerting/`
3. `docker compose up -d grafana`

**Telegram**

1. Crie um bot com o [@BotFather](https://t.me/BotFather), adicione-o ao grupo e descubra o id do chat em `https://api.telegram.org/bot<TOKEN>/getUpdates`.
2. No `.env`, preencha `TELEGRAM_BOT_TOKEN`.
3. `cp grafana/alerting-examples/telegram.yaml grafana/provisioning/alerting/` e, na cópia, troque `COLOQUE_O_CHAT_ID_AQUI` pelo id do chat (entre aspas; o Grafana não aceita esse id vindo de variável de ambiente).
4. `docker compose up -d grafana`

Preencha `GRAFANA_ROOT_URL` com o endereço em que você abre o Grafana, para os links das notificações funcionarem. As cópias ativadas (`email.yaml` e `telegram.yaml` dentro de `grafana/provisioning/alerting/`) estão no `.gitignore`, para o id do seu chat não ir parar no GitHub.

**No Kubernetes:** preencha as mesmas variáveis no `kubernetes/base/secrets.env` (veja o `secrets.env.example`), copie o exemplo para `grafana/provisioning/alerting/`, acrescente o arquivo na lista do `configMapGenerator` `grafana-alerting` em `kubernetes/base/kustomization.yaml`, rode `./scripts/sync-k8s-files.sh` e `kubectl apply -k` de novo.

**Ajustes:**

- **Limites:** mude o número em `params` do passo `C` de cada regra e reinicie o Grafana. Regras provisionadas não podem ser editadas pela tela; para testar outro limite antes, duplique a regra no Grafana.
- **Desligar uma regra:** `isPaused: true` na regra.
- **Trocar de contato:** ao tirar um exemplo de `grafana/provisioning/alerting/`, o contato antigo continua salvo no banco do Grafana. Apague-o em **Alerting → Contact points** depois de remover a política, ou use `deleteContactPoints` no arquivo (veja a [documentação do Grafana](https://grafana.com/docs/grafana/latest/alerting/set-up/provision-alerting-resources/file-provisioning/)).
- Os triggers do próprio Zabbix continuam funcionando; os alertas do Grafana são uma camada a mais, útil para quem já centraliza notificações no Grafana.

## Personalizando

- **Versões:** troque as tags no `.env` (Docker) e no bloco `images:` de `kubernetes/base/kustomization.yaml` (Kubernetes). Para usar o Zabbix 8.0 LTS, por exemplo, use `alpine-8.0-latest`.
- **Novos dashboards:** exporte o JSON no Grafana, salve em `grafana/dashboards/` e reinicie o Grafana (no Kubernetes, adicione o arquivo também no `configMapGenerator` e rode `./scripts/sync-k8s-files.sh`). Na interface, use a fonte de dados **Zabbix** (uid `zabbix`).
- **Fuso horário:** `TZ` no `.env` e no `configMapGenerator` `zabbix-config`.
- **Portas:** `ZABBIX_WEB_PORT`, `GRAFANA_PORT` e `ZABBIX_SERVER_PORT` no `.env`.

## Segurança

O modelo já vem endurecido: nenhuma senha padrão, containers sem root e sem capabilities, banco isolado, Grafana lendo o Zabbix com um usuário somente leitura, NetworkPolicies e HTTPS nos overlays `gateway` e `ingress`. A lista completa, e o que continua sendo responsabilidade sua (HTTPS, firewall do trapper, cópia dos backups para fora do servidor), está no [SECURITY.md](SECURITY.md).

- Nunca envie o `.env` ou o `secrets.env` para o GitHub (ambos estão no `.gitignore`).
- O Grafana acessa o Zabbix com o usuário `grafana`, que só lê dados e não entra na interface web. Ele recebe leitura nos grupos de hosts que existem quando o `zabbix-init` roda; ao criar grupos novos, rode `docker compose up zabbix-init` (no Kubernetes, `kubectl -n monitoring rollout restart deploy/grafana`).
- Mudar `POSTGRES_PASSWORD` depois do primeiro start não altera a senha do banco já criado. Nesse caso, troque a senha dentro do PostgreSQL ou recrie os volumes (`make reset`).
- Para reportar uma vulnerabilidade, veja o [SECURITY.md](SECURITY.md).

## Problemas comuns

| Sintoma | Causa provável |
|---|---|
| `zabbix-admin-password` ou `zabbix-init` termina com erro de senha | A senha do Admin contém "Admin"/"Zabbix" ou tem menos de 8 caracteres |
| `zabbix-web` não sobe e o `zabbix-admin-password` diz que o banco não ficou pronto | O Zabbix server não criou o banco em 10 min; veja `docker compose logs zabbix-server` |
| Grafana não sobe e o log fala de `plugin not installed` | O container não conseguiu baixar o plugin de grafana.com (proxy ou firewall) |
| Host "Zabbix server" fica vermelho (ZBX) por alguns minutos | Normal no primeiro start; o Zabbix tenta de novo a cada minuto |
| Painéis do Grafana sem dados | Confira em **Connections → Data sources → Zabbix → Save & test** |
| Hosts de um grupo novo não aparecem no Grafana | Rode `docker compose up zabbix-init` para dar leitura ao usuário `grafana` no grupo novo |
| No Linux, `permission denied while trying to connect to the Docker daemon socket` | Seu usuário não está no grupo `docker`; use `sudo` ou veja o [passo 2](#2-use-o-docker-sem-sudo-opcional) |
| No Linux, `docker: 'compose' is not a docker command` | Falta o plugin compose; instale o `docker-compose-plugin` pelo [passo 1](#1-instale-o-docker-engine-o-git-e-o-make) |
| `make up` diz que a senha é de exemplo ou curta | Apague o `.env` e rode `make env` de novo (ou ajuste a senha à mão) |
| No Mac, `mounts denied` ou `path is not shared` ao subir | A pasta do repositório está fora de `/Users`; mova-a ou libere em **Docker Desktop → Settings → Resources → File sharing** |
| No Windows, `make` ou `./scripts/...` não são reconhecidos | Use o WSL ou os comandos de [Usando no Windows](#usando-no-windows) |
| No Kubernetes, Zabbix/Grafana dão 502/504 pelo Gateway ou Ingress | A NetworkPolicy não reconheceu o namespace do controlador; rotule-o com `zabbix-grafana/ingress-controller=true` |
| `make: command not found` no Mac | Rode `xcode-select --install` (ou use `./scripts/generate-secrets.sh` e `docker compose up -d`) |
| `postgres-backup` aparece como `unhealthy` | Nenhum backup nas últimas 25 h; veja `docker compose logs postgres-backup` (disco cheio ou senha do banco errada) |
| Não consigo abrir o Zabbix/Grafana de outra máquina | Por padrão eles só escutam em `127.0.0.1`; veja `BIND_ADDRESS` no `.env` |

## Contribuindo

Issues e pull requests são bem-vindos. Antes de abrir um PR, rode `make validate` (precisa de `docker`, `kubectl`, `shellcheck` e `yamllint`; no Ubuntu/Debian: `sudo apt install -y shellcheck yamllint`, e o `kubectl` pelo [guia oficial](https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/)).

Abra o PR para a branch `develop`, nunca para a `main`. A `main` só recebe a `develop` (o CI recusa PR de outra branch para a `main`), e as duas branches são protegidas: nada de push direto, e o merge só sai com o CI verde.

## Licença

[MIT](LICENSE)
