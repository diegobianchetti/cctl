# Guia de criação de templates — cctl

Um template descreve como implantar uma aplicação específica (Moodle, DSpace,
GitLab, Nextcloud, etc.) usando Docker Compose. O cctl copia o template para um
diretório standalone durante o `init` e usa o `project.conf` como manifest
durante o `install`.

## Estrutura de um template

```
templates/<nome>/
  project.conf              # manifest do projeto (obrigatório)
  docker/
    docker-compose.yaml     # serviços, redes, volumes (obrigatório)
    .env.template           # variáveis da instância, com _PLACEHOLDERS_ (obrigatório)
  nginx/
    site.conf.template      # vhost com SSL (opcional, recomendado)
    site-nossl.conf.template # vhost HTTP-only para lab/dev (opcional)
  cron/
    *.cron.template         # entradas cron para instalação no host (opcional)
  scripts/
    post-install.sh         # executado ao final do cctl install (opcional)
  custom-config/            # arquivos de configuração montados via volume (opcional)
```

## Arquivo obrigatório: `project.conf`

O `project.conf` é um script Bash sourceable. Declara tudo que o cctl precisa
saber para instalar e operar o projeto.

```bash
#!/bin/bash
# project.conf — Manifest para cctl

PROJECT_TYPE="gitlab"   # deve ser igual ao nome do diretório em templates/

# Preenchidos pelo cctl init (não editar manualmente)
CLIENT_NAME="_CLIENT_NAME_"
DOMAIN_NAME="_DOMAIN_NAME_"
COMPOSE_PROJECT_NAME="_COMPOSE_PROJECT_NAME_"

# Paths relativos à raiz da instância
ENV_FILE="docker/.env"
ENV_TEMPLATE="docker/.env.template"

# Compose files (ordem importa se usar override)
COMPOSE_FILES=("docker/docker-compose.yaml")

# Templates renderizados durante cctl install (src:dst)
# Placeholders: {{VARIAVEL}} substituídos pelos valores do .env
TEMPLATE_FILES=(
    "nginx/site.conf.template:nginx/site.conf"
    "nginx/site-nossl.conf.template:nginx/site-nossl.conf"
    "cron/gitlab-backup.cron.template:cron/gitlab-backup.cron"
)

# Senhas geradas automaticamente durante cctl install
# Substituem _VARNAME_ no .env
AUTO_PASSWORD_VARS=("GITLAB_ROOT_PASSWORD" "POSTGRES_PASSWORD")

# Variáveis obrigatórias (validadas antes do deploy)
REQUIRED_VARS=("GITLAB_ROOT_PASSWORD" "DOMAIN_NAME" "COMPOSE_PROJECT_NAME")

# Nginx reverse proxy no host
HOST_NGINX=true
HOST_SSL=true
SSL_MODE="letsencrypt"
CERTBOT_EMAIL=""

# Cron no host
HOST_CRON=true

# Banco de dados (para db-check-config e db-update-config)
DB_SERVICE="gitlab-db"
DB_TYPE="postgresql"

# Serviços acessíveis via cctl connect <serviço>
CONNECTABLE_SERVICES=("gitlab" "gitlab-db")

# Alocação de rede
SUBNET_RANGE="172.32.0.0/16"
SUBNET_PREFIX_LEN=24

# Backup
BACKUP_DIR="./backups"
BACKUP_RETENTION=3

# Hook executado ao final do cctl install (relativo a scripts/)
HOOK_POST_INSTALL="post-install.sh"
```

### Referência de variáveis do `project.conf`

| Variável | Tipo | Obrigatória | Descrição |
|----------|------|-------------|-----------|
| `PROJECT_TYPE` | string | sim | Identificador do template. Deve ser igual ao nome do diretório. |
| `CLIENT_NAME` | string | sim | Nome do cliente/instância. Preenchido pelo `cctl init`. |
| `DOMAIN_NAME` | string | sim | Domínio da instância. Preenchido pelo `cctl init`. |
| `COMPOSE_PROJECT_NAME` | string | sim | Prefixo dos recursos Docker. Preenchido pelo `cctl init`. |
| `ENV_FILE` | path | não | Path do `.env` relativo à raiz. Default: `docker/.env` |
| `ENV_TEMPLATE` | path | não | Path do `.env.template`. Default: `docker/.env.template` |
| `COMPOSE_FILES` | array | sim | Lista de compose files na ordem de carregamento. |
| `TEMPLATE_FILES` | array | não | Pares `src:dst` renderizados durante `install`. |
| `AUTO_PASSWORD_VARS` | array | não | Variáveis de senha geradas automaticamente. |
| `REQUIRED_VARS` | array | não | Variáveis validadas antes do deploy. |
| `HOST_NGINX` | bool | não | Habilita vhost nginx no host. Default: `false` |
| `HOST_SSL` | bool | não | Habilita certificado SSL via Certbot. Default: `false` |
| `SSL_MODE` | string | não | Modo SSL: `letsencrypt` ou `manual`. Default: `letsencrypt` |
| `CERTBOT_EMAIL` | string | não | Email para notificações do Let's Encrypt. |
| `HOST_CRON` | bool | não | Instala entradas cron no host. Default: `false` |
| `DB_SERVICE` | string | não | Nome do serviço de banco de dados no compose. |
| `DB_TYPE` | string | não | Tipo de banco: `postgresql` ou `mysql`. |
| `DB_CUSTOM_CONFIG` | path | não | Path do arquivo de config customizado do banco. |
| `DB_CONFIG_PATH` | path | não | Destino do arquivo dentro do container do banco. |
| `CONNECTABLE_SERVICES` | array | não | Serviços disponíveis em `cctl connect`. |
| `SUBNET_RANGE` | CIDR | não | Pool de subnets para alocação. Default: `172.32.0.0/16` |
| `SUBNET_PREFIX_LEN` | int | não | Tamanho do prefixo da subnet alocada. Default: `24` |
| `BACKUP_DIR` | path | não | Diretório dos backups. Default: `./backups` |
| `BACKUP_RETENTION` | int | não | Dias de retenção dos backups. Default: `3` |
| `HOOK_POST_INSTALL` | string | não | Nome do script em `scripts/` executado pós-install. |

## Arquivo obrigatório: `docker/.env.template`

Contém todas as variáveis do ambiente. Variáveis com `_PLACEHOLDER_` são
substituídas pelo `cctl init` ou `cctl install`.

```bash
#####################################################################
## configuracoes do projeto - configurado via cctl init/install    ##
#####################################################################
CLIENT_NAME=_CLIENT_NAME_
COMPOSE_PROJECT_NAME=_COMPOSE_PROJECT_NAME_
DOMAIN_NAME=_DOMAIN_NAME_
GITLAB_ROOT_PASSWORD=_GITLAB_ROOT_PASSWORD_
POSTGRES_PASSWORD=_POSTGRES_PASSWORD_
## configurado via cctl install ##
COMPOSE_PROJECT_SUBNET=172.32.1.0/24

##########################
## container gitlab      ##
##########################
GITLAB_IMAGE=gitlab/gitlab-ce
GITLAB_TAG=17.0.0-ce.0
GITLAB_HTTP_PORT=8080
GITLAB_HTTPS_PORT=8443
GITLAB_SSH_PORT=2222
GITLAB_MEMORY_LIMIT=4G
GITLAB_CPU_LIMIT=2

##########################
## container gitlab-db   ##
##########################
GITLAB_DB_IMAGE=postgres
GITLAB_DB_TAG=16-alpine
GITLAB_DB_MEMORY_LIMIT=1G
```

### Convenção de placeholders

| Contexto | Formato | Onde usar |
|----------|---------|-----------|
| `.env.template` e `project.conf` | `_NOME_` (underscores) | Variáveis substituídas por `cctl init` e `cctl install` |
| Templates nginx, cron e outros | `{{NOME}}` (double braces) | Arquivos em `TEMPLATE_FILES`, renderizados por `cctl install` |

O formato `_PLACEHOLDER_` evita conflito com variáveis de shell. O formato
`{{PLACEHOLDER}}` evita conflito com variáveis do nginx (`$host`, `$uri`) e
com outros sistemas de template.

## Arquivo opcional: `nginx/site.conf.template`

Vhost renderizado durante `cctl install` se `HOST_NGINX=true` e
`HOST_SSL=true`. Use `{{DOMAIN_NAME}}` e `{{COMPOSE_PROJECT_NAME}}` como
placeholders — ambos são substituídos a partir do `.env`.

```nginx
server {
    listen 80;
    server_name {{DOMAIN_NAME}};
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name {{DOMAIN_NAME}};

    ssl_certificate     /etc/letsencrypt/live/{{DOMAIN_NAME}}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/{{DOMAIN_NAME}}/privkey.pem;

    location / {
        proxy_pass http://{{COMPOSE_PROJECT_NAME}}_gitlab_1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

## Arquivo opcional: `nginx/site-nossl.conf.template`

Vhost HTTP-only, usado quando `MOODLE_SSL=false` (ou equivalente no template).
Útil para ambientes de lab e desenvolvimento sem certificado SSL real.

```nginx
server {
    listen 80;
    server_name {{DOMAIN_NAME}};

    location / {
        proxy_pass http://{{COMPOSE_PROJECT_NAME}}_gitlab_1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
    }
}
```

## Arquivo opcional: `scripts/post-install.sh`

Executado ao final do `cctl install` se `HOOK_POST_INSTALL` estiver definido.
Roda no contexto do diretório da instância com o `.env` já carregado.

```bash
#!/bin/bash
# scripts/post-install.sh — Configurações pós-deploy

# Aguarda GitLab inicializar (pode demorar ~2 minutos)
echo "Aguardando GitLab inicializar..."
timeout 180 bash -c \
    "until docker exec ${COMPOSE_PROJECT_NAME}_gitlab_1 gitlab-rake gitlab:check SANITIZE=true &>/dev/null; do sleep 10; done"

echo "GitLab inicializado."
```

## Exemplo completo: template gitlab

### 1. Crie o diretório

```bash
cd ~/oogway/cctl
mkdir -p templates/gitlab/docker
mkdir -p templates/gitlab/nginx
mkdir -p templates/gitlab/cron
mkdir -p templates/gitlab/scripts
```

### 2. Crie o `docker/docker-compose.yaml`

```yaml
services:
  gitlab:
    image: ${GITLAB_IMAGE}:${GITLAB_TAG}
    container_name: ${COMPOSE_PROJECT_NAME}-gitlab
    restart: unless-stopped
    environment:
      GITLAB_OMNIBUS_CONFIG: |
        external_url 'https://${DOMAIN_NAME}'
        gitlab_rails['db_adapter'] = 'postgresql'
        gitlab_rails['db_host'] = '${COMPOSE_PROJECT_NAME}-db'
        gitlab_rails['db_password'] = '${POSTGRES_PASSWORD}'
    ports:
      - "${GITLAB_SSH_PORT}:22"
    volumes:
      - gitlab-config:/etc/gitlab
      - gitlab-logs:/var/log/gitlab
      - gitlab-data:/var/opt/gitlab
    networks:
      - frontend
      - backend
    depends_on:
      gitlab-db:
        condition: service_healthy
    deploy:
      resources:
        limits:
          memory: ${GITLAB_MEMORY_LIMIT}
          cpus: "${GITLAB_CPU_LIMIT}"

  gitlab-db:
    image: ${GITLAB_DB_IMAGE}:${GITLAB_DB_TAG}
    container_name: ${COMPOSE_PROJECT_NAME}-db
    restart: unless-stopped
    environment:
      POSTGRES_DB: gitlabhq_production
      POSTGRES_USER: gitlab
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - gitlab-db-data:/var/lib/postgresql/data
    networks:
      - backend
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U gitlab -d gitlabhq_production"]
      interval: 10s
      timeout: 5s
      retries: 5
    deploy:
      resources:
        limits:
          memory: ${GITLAB_DB_MEMORY_LIMIT}

networks:
  frontend:
    name: ${COMPOSE_PROJECT_NAME}-frontend
    ipam:
      config:
        - subnet: ${COMPOSE_PROJECT_SUBNET}
  backend:
    name: ${COMPOSE_PROJECT_NAME}-backend
    internal: true

volumes:
  gitlab-config:
    name: ${COMPOSE_PROJECT_NAME}-config
  gitlab-logs:
    name: ${COMPOSE_PROJECT_NAME}-logs
  gitlab-data:
    name: ${COMPOSE_PROJECT_NAME}-data
  gitlab-db-data:
    name: ${COMPOSE_PROJECT_NAME}-db-data
```

### 3. Crie o `docker/.env.template`

(conforme exemplo na seção acima)

### 4. Crie o `nginx/site.conf.template` e `nginx/site-nossl.conf.template`

(conforme exemplos nas seções acima)

### 5. Crie o `project.conf`

(conforme exemplo na seção acima, com `PROJECT_TYPE="gitlab"`)

### 6. Teste

```bash
./cctl init gitlab meu-gitlab --domain gitlab.oogway.com.br --dest /tmp/meu-gitlab
ls /tmp/meu-gitlab/
cat /tmp/meu-gitlab/docker/.env
```

Esperado: `.env` com `CLIENT_NAME`, `COMPOSE_PROJECT_NAME` e `DOMAIN_NAME`
preenchidos; `_GITLAB_ROOT_PASSWORD_` e `_POSTGRES_PASSWORD_` intocados
(serão gerados pelo `cctl install`).

## Dicas

- **Nomes de serviço no compose**: use `${COMPOSE_PROJECT_NAME}-<serviço>` como
  `container_name` para evitar colisão entre instâncias no mesmo servidor.
- **Rede `internal: true`**: marque redes que não precisam de saída para a
  internet (banco de dados, cache) — protege por design, não por convenção.
- **`depends_on condition: service_healthy`**: use em toda a cadeia para garantir
  ordem de inicialização — `condition: service_started` não verifica se o serviço
  está pronto, só que o container iniciou.
- **Senhas**: nunca coloque senhas fixas no template. Liste a variável em
  `AUTO_PASSWORD_VARS` e use `_VARNAME_` como placeholder no `.env.template`.
- **Tags de imagem**: nunca use `latest`. Defina a tag no `.env.template` para
  que upgrades sejam decisões explícitas, não surpresas.
