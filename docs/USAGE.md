# cctl — Guia de Uso

Orquestrador generico para ambientes Docker containerizados.
Unifica o gerenciamento de projetos DSpace e Moodle.

---

## Sumario

1. [Requisitos](#requisitos)
2. [Conceitos](#conceitos)
3. [Fluxo completo](#fluxo-completo)
4. [Referencia de comandos](#referencia-de-comandos)
5. [Exemplos por projeto](#exemplos-por-projeto)
6. [Estrutura de um template](#estrutura-de-um-template)
7. [Customizacao](#customizacao)
8. [Troubleshooting](#troubleshooting)

---

## Requisitos

- Docker >= 24.0 com Docker Compose v2
- Bash >= 4.4
- Git
- Acesso sudo no servidor (para nginx, cron, SSL)
- Acesso ao registry configurado em `DOCKER_OWNER` para pull das imagens

---

## Conceitos

### Contextos

O `cctl` detecta automaticamente onde esta sendo executado e libera apenas os comandos validos para aquele contexto:

| Contexto | Deteccao | Comandos disponiveis |
|----------|----------|---------------------|
| **template** | Diretorio `templates/` presente | `init`, `help` |
| **client_branch** | `project.conf` presente, sem `.cctl-instance` | `install`, `help` |
| **instance** | `.cctl-instance` presente | Todos os operacionais (up, down, logs, backup...) |

### Manifest (project.conf)

Cada template tem um `project.conf` que declara tudo sobre o projeto: compose files, variaveis obrigatorias, senhas auto-geradas, configuracao de nginx/cron/SSL, etc. O `cctl` le esse arquivo para saber como operar.

### Placeholders

- **`_PLACEHOLDER_`** (underscores) — usados no `.env.template`, substituidos durante `init` e `install`
- **`{{PLACEHOLDER}}`** (double braces) — usados em templates de config (nginx, cron), substituidos durante `install`

---

## Fluxo completo

### Passo 1: Inicializar (maquina local)

Roda no repositorio de templates (branch `main`):

```bash
cd /caminho/do/repo/containers-control

./cctl init --project <tipo> --client <nome> --domain <dominio>
```

O que acontece:
1. Cria branch git `<tipo>-<nome>` a partir de `main`
2. Copia o template escolhido para a raiz da branch
3. Remove o diretorio `templates/`
4. Preenche `CLIENT_NAME`, `DOMAIN_NAME` e `COMPOSE_PROJECT_NAME` no `.env`
5. Commit + push automatico

Ao final, imprime as instrucoes para instalar no servidor.

### Passo 2: Instalar (servidor)

No servidor de producao:

```bash
cd /var/docker
git clone --branch <tipo>-<nome> --single-branch <URL_DO_REPO> <tipo>-<nome>
cd <tipo>-<nome>
./cctl install
```

O que acontece:
1. Gera senhas automaticas (definidas em `AUTO_PASSWORD_VARS`)
2. Aloca subnet Docker livre no range configurado
3. Renderiza templates (nginx, cron) com as variaveis do `.env`
4. Valida pre-requisitos (docker, disco, portas)
5. Pull das imagens do registry
6. Sobe os containers (`docker compose up -d`)
7. Configura nginx no host (se `HOST_NGINX=true`)
8. Emite certificado SSL (se `HOST_SSL=true`)
9. Instala cron jobs (se `HOST_CRON=true`)
10. Executa hook pos-instalacao
11. Grava `.cctl-instance` (marca como instalado)

### Passo 3: Operar (servidor)

Apos instalado, todos os comandos operacionais ficam disponiveis:

```bash
./cctl ps          # containers rodando
./cctl logs        # ver logs
./cctl status      # saude do ambiente
```

---

## Referencia de comandos

### Inicializacao

| Comando | Descricao |
|---------|-----------|
| `cctl init --project <tipo> --client <nome> --domain <dominio>` | Cria branch de cliente a partir de um template |
| `cctl install` | Instala a instancia no servidor (deploy completo) |

### Ciclo de vida

| Comando | Descricao |
|---------|-----------|
| `cctl up` | Cria containers e inicia o ambiente |
| `cctl down` | Remove containers e rede (mantem volumes) |
| `cctl start` | Inicia containers parados |
| `cctl stop` | Para containers em execucao |
| `cctl restart` | Reinicia containers |

### Monitoramento

| Comando | Descricao |
|---------|-----------|
| `cctl ps` | Lista containers do ambiente |
| `cctl logs [servico]` | Exibe logs (todos ou de um servico especifico) |
| `cctl status` | Resumo de saude (containers, rede, disco, SSL) |
| `cctl network` | Detalhes da rede Docker (subnet, IPs alocados) |
| `cctl volumes` | Lista volumes e bind mounts |
| `cctl config` | Exibe configuracao resolvida |

### Acesso e manutencao

| Comando | Descricao |
|---------|-----------|
| `cctl connect <servico>` | Abre shell (bash) no container |
| `cctl build` | Build/rebuild de imagens locais |
| `cctl update` | Pull de imagens atualizadas e recria containers |
| `cctl backup` | Executa backup (dump do banco + volumes) |
| `cctl list` | Lista instancias instaladas no servidor |

### Banco de dados

| Comando | Descricao |
|---------|-----------|
| `cctl db-check-config` | Verifica se config customizada do banco esta aplicada |
| `cctl db-update-config` | Aplica config customizada no banco |

### Limpeza (destrutivos)

| Comando | Descricao |
|---------|-----------|
| `cctl clear-volumes` | Remove volumes (dados permanentes!) |
| `cctl clear-all` | Remove tudo: containers, volumes, rede, nginx, cron |
| `cctl destroy` | Teardown completo + apaga o diretorio da instancia |

### Opcoes globais

| Opcao | Descricao |
|-------|-----------|
| `--version`, `-v` | Exibe a versao do cctl |
| `--help`, `-h` | Exibe ajuda (contextual) |
| `--verbose` | Saida detalhada com debug |

---

## Exemplos por projeto

### DSpace

```bash
# Local — criar branch para o cliente:
./cctl init --project dspace --client acme --domain repositorio.acme.example.com

# Servidor — instalar:
cd /var/docker
git clone --branch dspace-acme --single-branch git@github.com:usuario/cctl.git dspace-acme
cd dspace-acme
./cctl install

# Operacao:
./cctl ps
./cctl logs dspace           # logs do backend
./cctl logs dspace-angular   # logs do frontend
./cctl connect dspacedb      # shell no PostgreSQL
./cctl backup
```

Servicos DSpace: `dspace` (backend), `dspace-angular` (frontend), `dspacedb` (PostgreSQL), `dspacesolr` (Solr)

### Moodle

```bash
# Local:
./cctl init --project moodle --client acme --domain moodle.acme.example.com

# Servidor:
cd /var/docker
git clone --branch moodle-acme --single-branch git@github.com:usuario/cctl.git moodle-acme
cd moodle-acme
./cctl install

# Operacao:
./cctl ps
./cctl logs moodle-app
./cctl connect moodle-db
./cctl db-check-config       # verifica custom-postgresql.conf
./cctl backup
```

Servicos Moodle: `moodle-app`, `moodle-db`

---

## Estrutura de um template

Cada template em `templates/<tipo>/` segue esta estrutura:

```
templates/<tipo>/
  project.conf              # Manifest (obrigatorio)
  docker/
    .env.template           # Variaveis de ambiente
    docker-compose.yaml     # Compose principal
  nginx/
    site.conf.template      # Config nginx (opcional)
  cron/
    *.template              # Cron jobs (opcional)
  scripts/
    post-install.sh         # Hook pos-install (opcional)
  custom-config/            # Configs especificas do projeto
```

### Campos do project.conf

| Campo | Descricao | Exemplo |
|-------|-----------|---------|
| `PROJECT_TYPE` | Tipo do projeto | `"dspace"` |
| `ENV_FILE` | Caminho do .env | `"docker/.env"` |
| `ENV_TEMPLATE` | Caminho do template do .env | `"docker/.env.template"` |
| `COMPOSE_FILES` | Array de compose files | `("docker/docker-compose.yaml")` |
| `TEMPLATE_FILES` | Templates a renderizar (src:dst) | `("nginx/site.conf.template:nginx/site.conf")` |
| `AUTO_PASSWORD_VARS` | Senhas geradas automaticamente | `("POSTGRES_PASSWORD")` |
| `REQUIRED_VARS` | Vars validadas antes do deploy | `("DOMAIN_NAME" "POSTGRES_PASSWORD")` |
| `HOST_NGINX` | Configura nginx no host | `true` / `false` |
| `HOST_SSL` | Emite certificado SSL | `true` / `false` |
| `SSL_MODE` | Tipo de SSL | `"letsencrypt"` / `"manual"` |
| `HOST_CRON` | Instala cron jobs no host | `true` / `false` |
| `DB_SERVICE` | Nome do servico de banco | `"dspacedb"` |
| `DB_TYPE` | Tipo do banco | `"postgresql"` |
| `CONNECTABLE_SERVICES` | Servicos que aceitam `cctl connect` | `("dspace" "dspacedb")` |
| `SUBNET_RANGE` | Range para alocacao de subnet | `"10.88.0.0/16"` |
| `HOOK_POST_INSTALL` | Script pos-install | `"post-install.sh"` |

---

## Customizacao

### Ajustar limites de recursos

Edite o `.env` da instancia (ou `.env.template` no template) e altere os valores de memoria e CPU:

```bash
DSPACE_MEMORY_LIMIT=4G
DSPACE_CPU_LIMIT=4
POSTGRESQL_MEMORY_LIMIT=1G
```

Depois aplique com:

```bash
./cctl down && ./cctl up
```

### SSL manual (certificado proprio)

No `project.conf`, configure:

```bash
HOST_SSL=true
SSL_MODE="manual"
```

No `.env`, informe os caminhos:

```bash
SSL_CERT_FILE="/caminho/do/certificado.pem"
SSL_KEY_FILE="/caminho/da/chave.key"
```

### Adicionar novo template

1. Crie `templates/<novo>/` com `project.conf`, `.env.template`, compose, etc.
2. Siga a estrutura dos templates existentes como referencia
3. O template ficara automaticamente disponivel no `cctl init`

---

## Troubleshooting

### "Este nao e um diretorio de instancia"

Voce esta rodando um comando operacional fora do diretorio da instancia. Navegue ate o diretorio correto:

```bash
cd /var/docker/<projeto>-<cliente>
```

### "Instancia ja instalada"

O `cctl install` so pode ser executado uma vez. Use `cctl up/down/restart` para operar.

### Containers nao sobem

```bash
./cctl logs              # ver erros
./cctl status            # checar saude geral
./cctl config            # verificar variaveis resolvidas
```

### Problemas com nginx

```bash
# Testar config manualmente:
docker compose -p nginx exec nginx nginx -t

# Ver logs:
docker compose -p nginx exec nginx tail -f /var/log/nginx/error-<dominio>.log
```

### Reset completo (perda de dados!)

```bash
./cctl clear-all         # remove containers, volumes, nginx, cron
./cctl install           # reinstala do zero
```

### Destruir instancia

```bash
./cctl destroy           # pede confirmacao digitando o nome do projeto
```
