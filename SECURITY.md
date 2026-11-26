# Segurança

## Como reportar uma vulnerabilidade

Não abra uma issue pública. Use a aba **Security → Report a vulnerability**
deste repositório (GitHub Private Vulnerability Reporting). Responderemos assim
que possível e combinaremos a divulgação depois da correção.

Vulnerabilidades do próprio Zabbix, Grafana ou PostgreSQL devem ser reportadas
aos respectivos projetos.

## O que este modelo já faz por padrão

**Senhas**
- Nenhuma senha vem preenchida. `make env` / `make k8s-secrets` geram senhas
  aleatórias de 24 caracteres, em arquivos com permissão 600 que estão no
  `.gitignore`.
- O Docker Compose não sobe se faltar alguma senha; `make up` e `make k8s-apply`
  recusam senhas vazias, curtas (menos de 12) ou de exemplo. No Kubernetes, o
  Grafana também confere as senhas antes de iniciar.
- A senha padrão `zabbix` do Admin é trocada direto no banco antes de a
  interface web subir, então o Admin nunca fica acessível com ela.
- O Grafana acessa o Zabbix com um usuário próprio (`grafana`), **somente
  leitura** e **sem acesso à interface web**, nunca com o Admin.

**Rede**
- PostgreSQL sem porta publicada e numa rede sem saída para a internet.
- Docker: Zabbix web e Grafana escutam só em `127.0.0.1` por padrão.
- Kubernetes: NetworkPolicies negam toda entrada que não seja necessária. Nos
  overlays `gateway` e `ingress`, o Zabbix web e o Grafana só aceitam conexões
  do controlador de entrada; os dois overlays já vêm só com HTTPS.

**Containers**
- Todos rodam sem root (o PostgreSQL inclusive), sem capabilities do Linux e
  com `no-new-privileges` / `allowPrivilegeEscalation: false`.
  Exceção: o Zabbix server mantém só `NET_RAW`, para os pings ICMP (fping).
- Sistema de arquivos somente leitura no PostgreSQL, Grafana, zabbix-init e
  zabbix-admin-password.
- Kubernetes: `seccompProfile: RuntimeDefault`, sem token de ServiceAccount
  montado, limites de memória, e o namespace com Pod Security `baseline`
  (aviso para `restricted`).
- O job de init não baixa pacotes na hora: usa a imagem do Zabbix web, que já
  tem `curl` (o script só usa sh, curl, grep e sed).

**Grafana**
- Sem cadastro de usuários, sem acesso anônimo, sem criação de organizações,
  sem snapshots externos, sem Gravatar e sem telemetria. Cookie `SameSite=strict`
  e, atrás de HTTPS (overlays `gateway` e `ingress`), cookie `Secure`.

**MCP (opcional, make mcp)**
- A IA conecta só no `mcp-gateway`, que escuta apenas em `127.0.0.1` (mesmo
  com `BIND_ADDRESS=0.0.0.0`), exige o `MCP_TOKEN` e recusa `Host`/`Origin` de
  outros sites. Os MCPs oficiais do Zabbix e do Grafana ficam só na rede
  interna, sem porta publicada, e os tokens deles nunca chegam à IA.
- Somente leitura: no Zabbix só as ferramentas `*_get`, sem as que devolvem
  chaves de itens, macros, interfaces e histórico bruto; no Grafana,
  `--disable-write` e só ferramentas de dashboards, alertas, anotações,
  datasources e busca.
- Usuário `mcp` próprio no Zabbix (tipo User, sem interface web, auditado) e
  service account `mcp` Viewer no Grafana. Os dois exigem token; os tokens
  ficam no `.env` (permissão 600, fora do Git).
- Fica com você: não expor essa porta na rede e não colar os tokens em
  chats ou prints.

**CI**
- Token do GitHub só com leitura, Actions fixadas por SHA e atualizadas pelo
  Dependabot, binários baixados conferidos por SHA-256.
- O CI falha se os arquivos de exemplo trouxerem senhas ou se algum arquivo de
  segredo for versionado.
- Workflow `security` (em todo PR, push e toda segunda-feira):
  - **gitleaks** procura senhas e chaves em todo o histórico do git. Exceções
    aceitas ficam em `.gitleaksignore`.
  - **actionlint** e **zizmor** checam erros e riscos nos próprios workflows.
  - **Trivy config** analisa os manifests do Kubernetes já renderizados e falha
    em achados HIGH/CRITICAL. Exceções, cada uma presa a um recurso e com o
    motivo, ficam em `.github/trivy-ignore.rego`.
  - **Trivy image** lista CVEs HIGH/CRITICAL com correção disponível nas imagens
    do Zabbix, Grafana e PostgreSQL. Só avisa (resumo no job), porque a correção
    depende de uma imagem nova do projeto original: quando aparecer, atualize a
    tag (veja "Atualizações").

## O que fica com você

- **HTTPS.** Para acessar o Zabbix e o Grafana de outra máquina, coloque um
  proxy reverso com TLS na frente (Docker) ou use o overlay `gateway` (ou
  `ingress`) com um certificado válido (cert-manager, por exemplo). O
  ingress-nginx foi aposentado em março de 2026 e não recebe mais correções de
  segurança: não o use para expor este ambiente. Evite `BIND_ADDRESS=0.0.0.0`
  sem TLS.
- **Firewall do trapper (10051).** Ele precisa ficar aberto para os agentes
  ativos. Libere só as redes dos seus agentes e, de preferência, ative
  criptografia PSK ou certificado entre agentes e servidor
  ([documentação](https://www.zabbix.com/documentation/7.0/en/manual/encryption)).
  Atenção: as portas publicadas pelo Docker **passam por cima do UFW e do
  firewalld**. Filtre na chain `DOCKER-USER` ou use
  `ZABBIX_SERVER_BIND_ADDRESS`; o passo a passo está em "Protegendo a porta
  10051" no README.
- **Senhas.** Guarde as senhas geradas num cofre. Trocar `POSTGRES_PASSWORD`
  depois do primeiro start não muda a senha do banco já criado.
- **Kubernetes Secrets** ficam só em base64 no etcd. Em produção, ative a
  [criptografia em repouso](https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/)
  ou use Sealed Secrets / External Secrets.
- **Cópia dos backups para fora do servidor.** O backup automático do banco
  (`postgres-backup`) guarda os arquivos no mesmo host ou cluster. Copie-os
  para outro lugar (veja "Backup do banco" no README). Os arquivos têm todos os
  dados do Zabbix, inclusive os hashes de senha: guarde-os protegidos.
- **Novos grupos de hosts.** O usuário `grafana` recebe leitura nos grupos que
  existem quando o init roda. Ao criar grupos novos, rode o init de novo
  (`docker compose up zabbix-init`, ou
  `kubectl -n monitoring rollout restart deploy/grafana` no Kubernetes) ou
  adicione o grupo ao grupo de usuários "Grafana (somente leitura)".

## Atualizações

Siga os avisos de segurança do [Zabbix](https://www.zabbix.com/security_advisories),
do [Grafana](https://grafana.com/security/security-advisories/) e do PostgreSQL.
As versões das imagens ficam em `.env.example` (Docker) e no bloco `images:` de
`kubernetes/base/kustomization.yaml` (Kubernetes). O PostgreSQL usa a tag
`16-alpine`, que recebe as correções da versão 16 a cada `docker compose pull`.
