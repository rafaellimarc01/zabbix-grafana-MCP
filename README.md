# Zabbix + Grafana: ambiente pronto (Docker e Kubernetes)

[English version](README.en.md)

Modelo pronto para subir um ambiente de monitoramento com **Zabbix** e **Grafana** em poucos minutos, tanto com **Docker Compose** quanto em **Kubernetes** (Kustomize). O Grafana já vem com o plugin do Zabbix instalado, a fonte de dados configurada e dashboards prontos.

Use como ponto de partida para o seu laboratório, para estudos ou como base de um ambiente real.

## O que vem no pacote

| Componente | Imagem | Para que serve |
|---|---|---|
| PostgreSQL | `postgres:16-alpine` | Banco de dados do Zabbix |
| Zabbix Server | `zabbix/zabbix-server-pgsql:alpine-7.0.32` | Coleta, triggers e alertas (Zabbix 7.0 LTS) |
| Zabbix Web | `zabbix/zabbix-web-nginx-pgsql:alpine-7.0.32` | Interface web e API do Zabbix |
| Zabbix Agent 2 | `zabbix/zabbix-agent2:alpine-7.0.32` | Monitora o host "Zabbix server" que já vem cadastrado |
| zabbix-init | `zabbix/zabbix-web-nginx-pgsql:alpine-7.0.32` | Tarefa única: troca a senha padrão do Admin, cria o usuário somente leitura do Grafana e liga o agente ao host |
| Grafana | `grafana/grafana:12.4.16` | Dashboards, com o plugin [Zabbix para Grafana](https://grafana.com/grafana/plugins/alexanderzobnin-zabbix-app/) |

Dashboards incluídos (pasta **Zabbix** no Grafana):

- **Zabbix - Visão geral dos hosts**: problemas ativos, CPU, memória, load, rede e disco, com filtro por grupo e host.
- **Zabbix - Saúde do servidor**: valores processados por segundo, filas e uso dos processos internos do Zabbix.

```
.
├── docker-compose.yml          # ambiente completo com Docker
├── .env.example                # variáveis (as senhas são geradas por make env)
├── grafana/
│   ├── provisioning/           # plugin, datasource e provedor de dashboards
│   └── dashboards/             # JSON dos dashboards (adicione os seus aqui)
├── kubernetes/
│   ├── base/                   # manifests (Kustomize)
│   └── overlays/
│       ├── local/              # NodePort, para kind/minikube/k3d/Docker Desktop
│       └── ingress/            # Ingress com domínios próprios
├── scripts/
│   ├── zabbix-init.sh          # configuração inicial via API do Zabbix
│   ├── generate-secrets.sh     # gera .env / secrets.env com senhas aleatórias
│   ├── check-secrets.sh        # recusa senhas vazias, curtas ou de exemplo
│   └── sync-k8s-files.sh       # copia grafana/ para o Kubernetes
├── SECURITY.md                 # o que já vem protegido e o que fica com você
└── Makefile                    # atalhos (make help)
```

## Requisitos

- **Docker:** Docker Engine 24+ com o plugin `docker compose` (ou Docker Desktop).
- **Kubernetes:** um cluster 1.27+ com StorageClass padrão e `kubectl` 1.27+ (já traz o Kustomize).
- Mínimo recomendado: 2 vCPU e 4 GB de RAM.
- Acesso à internet no primeiro start (o Grafana baixa o plugin do Zabbix de grafana.com).

## Início rápido com Docker Compose

```bash
git clone https://github.com/<seu-usuario>/zabbix-grafana-stack.git
cd zabbix-grafana-stack

make env                  # gera o .env com senhas aleatórias (sem make: ./scripts/generate-secrets.sh)
docker compose up -d
docker compose ps -a      # zabbix-init deve aparecer como "Exited (0)"
```

Ou tudo de uma vez: `make up` (gera o `.env` se não existir e confere as senhas). As senhas ficam no `.env`; guarde-as num cofre.

Depois de 1 a 2 minutos:

| Serviço | Endereço | Usuário | Senha |
|---|---|---|---|
| Zabbix | http://localhost:8080 | `Admin` | `ZABBIX_ADMIN_PASSWORD` do `.env` |
| Grafana | http://localhost:3000 | `GRAFANA_ADMIN_USER` | `GRAFANA_ADMIN_PASSWORD` do `.env` |
| Zabbix trapper (agentes externos) | `<ip-do-host>:10051` | | |

> Por segurança, o Zabbix web e o Grafana só aceitam conexões do próprio computador (`127.0.0.1`), porque falam HTTP sem criptografia. Para acessar de outra máquina, coloque um proxy reverso com HTTPS na frente ou mude `BIND_ADDRESS=0.0.0.0` no `.env`, ciente de que as senhas vão trafegar sem TLS.

> Se preencher as senhas à mão: mínimo de 12 caracteres, e a do Admin do Zabbix **não pode conter** "Admin" nem "Zabbix" (regra do próprio Zabbix). Se o `zabbix-init` falhar, veja `docker compose logs zabbix-init`.

### Comandos úteis

```bash
make help     # lista os atalhos
make logs     # acompanha os logs
make down     # para tudo, mantendo os dados
make reset    # para e APAGA os volumes (começa do zero)
```

## Início rápido com Kubernetes

Tudo é criado no namespace `monitoring`.

```bash
make k8s-secrets          # gera kubernetes/base/secrets.env com senhas aleatórias

# Cluster local (kind, minikube, k3d, Docker Desktop): expõe NodePorts
kubectl apply -k kubernetes/overlays/local

# Cluster com Ingress Controller: edite os domínios em
# kubernetes/overlays/ingress/ingress.yaml e aplique
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

- O overlay `ingress` já vem com HTTPS (`tls` + redirecionamento). Crie o Secret `zabbix-grafana-tls` com o seu certificado ou use o cert-manager (veja os comentários em `ingress.yaml`).
- O namespace usa Pod Security `baseline` e NetworkPolicies que só liberam o tráfego necessário (precisam de um CNI com suporte, como Calico ou Cilium).
- O PostgreSQL usa um volume de 10 Gi e o Grafana um de 2 Gi, na StorageClass padrão do cluster.
- O Job `zabbix-init` se apaga 10 minutos depois de terminar. Rodar `kubectl apply -k` de novo executa ele outra vez sem problemas (é idempotente).
- O Kustomize não lê arquivos fora da própria pasta, então `kubernetes/base/files/` tem uma cópia de `grafana/` e do script de init. Depois de mudar algo neles, rode `./scripts/sync-k8s-files.sh` (o CI acusa se esquecer).
- Para remover: `kubectl delete -k kubernetes/overlays/local`. Os PVCs do PostgreSQL ficam; apague-os à mão se quiser zerar os dados.

## Monitorando seus servidores

Instale o Zabbix Agent 2 nas máquinas que quer monitorar e aponte para o servidor:

```ini
# /etc/zabbix/zabbix_agent2.conf
Server=<ip-do-servidor-zabbix>
ServerActive=<ip-do-servidor-zabbix>:10051
Hostname=<nome-do-host>
```

Depois cadastre o host no Zabbix (**Coleta de dados → Hosts → Criar host**) com o template **Linux by Zabbix agent** (ou **Windows by Zabbix agent**). Ele aparece sozinho no dashboard do Grafana, no filtro de grupo e host.

Para monitorar o próprio cluster Kubernetes (nós, pods, API), use a [integração oficial do Zabbix com Kubernetes](https://www.zabbix.com/integrations/kubernetes) (Helm chart) junto com este ambiente.

## Personalizando

- **Versões:** troque as tags no `.env` (Docker) e no bloco `images:` de `kubernetes/base/kustomization.yaml` (Kubernetes). Para usar o Zabbix 8.0 LTS, por exemplo, use `alpine-8.0-latest`.
- **Novos dashboards:** exporte o JSON no Grafana, salve em `grafana/dashboards/` e reinicie o Grafana (no Kubernetes, adicione o arquivo também no `configMapGenerator` e rode `./scripts/sync-k8s-files.sh`). Na interface, use a fonte de dados **Zabbix** (uid `zabbix`).
- **Fuso horário:** `TZ` no `.env` e no `configMapGenerator` `zabbix-config`.
- **Portas:** `ZABBIX_WEB_PORT`, `GRAFANA_PORT` e `ZABBIX_SERVER_PORT` no `.env`.

## Segurança

O modelo já vem endurecido: nenhuma senha padrão, containers sem root e sem capabilities, banco isolado, Grafana lendo o Zabbix com um usuário somente leitura, NetworkPolicies e HTTPS no overlay `ingress`. A lista completa, e o que continua sendo responsabilidade sua (HTTPS, firewall do trapper, backups), está no [SECURITY.md](SECURITY.md).

- Nunca envie o `.env` ou o `secrets.env` para o GitHub (ambos estão no `.gitignore`).
- O Grafana acessa o Zabbix com o usuário `grafana`, que só lê dados e não entra na interface web. Ele recebe leitura nos grupos de hosts que existem quando o `zabbix-init` roda; ao criar grupos novos, rode `docker compose up zabbix-init` (ou `kubectl apply -k` de novo).
- Mudar `POSTGRES_PASSWORD` depois do primeiro start não altera a senha do banco já criado. Nesse caso, troque a senha dentro do PostgreSQL ou recrie os volumes (`make reset`).
- Para reportar uma vulnerabilidade, veja o [SECURITY.md](SECURITY.md).

## Problemas comuns

| Sintoma | Causa provável |
|---|---|
| `zabbix-init` termina com erro de senha | A senha do Admin contém "Admin"/"Zabbix" ou tem menos de 8 caracteres |
| Grafana não sobe e o log fala de `plugin not installed` | O container não conseguiu baixar o plugin de grafana.com (proxy ou firewall) |
| Host "Zabbix server" fica vermelho (ZBX) por alguns minutos | Normal no primeiro start; o Zabbix tenta de novo a cada minuto |
| Painéis do Grafana sem dados | Confira em **Connections → Data sources → Zabbix → Save & test** |
| Hosts de um grupo novo não aparecem no Grafana | Rode `docker compose up zabbix-init` para dar leitura ao usuário `grafana` no grupo novo |
| `make up` diz que a senha é de exemplo ou curta | Apague o `.env` e rode `make env` de novo (ou ajuste a senha à mão) |
| Não consigo abrir o Zabbix/Grafana de outra máquina | Por padrão eles só escutam em `127.0.0.1`; veja `BIND_ADDRESS` no `.env` |

## Contribuindo

Issues e pull requests são bem-vindos. Antes de abrir um PR, rode `make validate` (precisa de `docker`, `kubectl` e `yamllint`).

## Licença

[MIT](LICENSE)
