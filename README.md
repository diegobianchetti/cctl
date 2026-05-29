# cctl — containers-control

Orquestrador Bash para ambientes Docker containerizados. Automatiza o ciclo
completo de um projeto: inicialização de diretório, deploy no servidor e operações
do dia a dia — sem dependências externas além do Docker.

## O que resolve

Manter múltiplos ambientes Docker (clientes, projetos, ambientes de homologação)
num mesmo servidor é trabalhoso: senhas geradas manualmente, subnets conflitantes,
vhosts criados à mão, crons esquecidos. O cctl codifica esse processo num único
fluxo reproduzível:

1. **`cctl init`** (local): cria um diretório standalone com os arquivos do template
   renderizados — `.env`, `project.conf`, `docker-compose.yaml` e vhost nginx
2. **`cctl install`** (servidor): gera senhas, aloca subnet, renderiza templates,
   sobe os containers, instala crons e registra o vhost no proxy reverso
3. **Operações do dia a dia**: `ps`, `logs`, `backup`, `connect`, `update` e mais

## Pré-requisitos

- Docker Engine 24+
- Docker Compose (plugin V2)
- Bash 5.x
- [nginx-proxy](https://github.com/diegobianchetti/nginx-proxy) em execução
  (necessário para `cctl install`)

## Instalação

```bash
git clone https://github.com/diegobianchetti/cctl.git
cd cctl

# Opcional: disponibilizar globalmente
sudo ln -s "$(pwd)/cctl" /usr/local/bin/cctl
source cctl-completion.bash   # autocomplete
```

## Fluxo de uso

### 1. Inicialização (na máquina local)

```bash
cctl init moodle moodle-acme
```

O comando solicita o diretório de destino (sugerindo `$(pwd)/moodle-acme/` e
`/opt/moodle-acme/`) e o domínio, depois gera o projeto com tudo preenchido:

```
/opt/moodle-acme/
  docker/
    docker-compose.yaml
    .env               ← CLIENT_NAME, COMPOSE_PROJECT_NAME e DOMAIN_NAME preenchidos
  nginx/
    site.conf.template
    site-nossl.conf.template
    moodle-acme.conf   ← vhost de referência (gerado se domínio informado)
  project.conf         ← manifest do projeto
  ...
```

Também aceita flags para uso não-interativo:

```bash
cctl init moodle moodle-acme \
  --domain moodle.acme.example.br \
  --dest /opt/moodle-acme
```

### 2. Instalação (no servidor)

```bash
cd /opt/moodle-acme

# Revisar e ajustar o .env antes de instalar
vi docker/.env

# Instalar
cctl install
```

O `install` gera as senhas, aloca uma subnet dedicada, sobe os containers,
instala os cron jobs e registra o vhost no nginx-proxy.

### 3. Operações

```bash
cctl ps               # lista containers e status
cctl logs             # últimas 50 linhas de log
cctl logs -100        # últimas 100 linhas
cctl logs -f          # segue em tempo real
cctl connect app      # shell no container da aplicação
cctl status           # resumo de saúde do ambiente
cctl backup           # executa backup do ambiente
cctl update           # pull de imagens e recria containers
```

## Referência de comandos

### Ciclo de vida

| Comando | Descrição |
|---------|-----------|
| `init <template> <nome>` | Inicializa diretório de projeto a partir de um template |
| `install` | Instala a instância no servidor |
| `up` | Cria containers e inicia o ambiente |
| `down` | Remove containers e rede (mantém volumes) |
| `start` | Inicia containers parados |
| `stop` | Para containers em execução |
| `restart` | Reinicia containers |
| `destroy` | Teardown completo da instância |

### Monitoramento

| Comando | Descrição |
|---------|-----------|
| `ps` | Lista containers do ambiente |
| `logs [serviço]` | Exibe logs. Sem args: últimas 50 linhas. `-N`: últimas N linhas. `-f`: segue |
| `status` | Resumo de saúde do ambiente |
| `network` | Detalhes da rede Docker (subnet, IPs) |
| `volumes` | Lista volumes e bind mounts |
| `list` | Lista instâncias instaladas no servidor |

### Manutenção

| Comando | Descrição |
|---------|-----------|
| `connect <serviço>` | Abre shell no container do serviço |
| `build` | Build/rebuild de imagens locais |
| `update` | Pull de imagens e recria containers |
| `backup` | Executa backup do ambiente |
| `config` | Exibe configuração resolvida |
| `db-check-config` | Verifica config customizada do banco |
| `db-update-config` | Aplica config customizada no banco |

### Limpeza (destrutivo)

| Comando | Descrição |
|---------|-----------|
| `clear-volumes` | Remove volumes (dados permanentes apagados) |
| `clear-all` | Remove tudo: containers, volumes, configs |

## Estrutura

```
cctl                    # Entry point e dispatcher
cctl.conf               # Defaults globais (registry, paths)
cctl-completion.bash    # Autocomplete para bash
lib/                    # Funções compartilhadas
  core.sh               # Detecção de contexto, variáveis globais
  colors.sh             # Cores e formatação de output
  log.sh                # Funções de log (msg_info, msg_error, etc.)
  env.sh                # Leitura e escrita do .env
  validate.sh           # Validações de pré-requisitos
  compose.sh            # Wrappers do docker compose
  network.sh            # Alocação de subnets
  nginx.sh              # Integração com nginx-proxy
commands/               # Um arquivo por subcomando
  init.sh               # Inicializa diretório de projeto
  install.sh            # Deploy completo no servidor
  logs.sh               # Exibe logs
  ps.sh                 # Lista containers
  ...                   # Demais comandos
templates/              # Um diretório por tipo de projeto
  moodle/               # Template para Moodle
  dspace/               # Template para DSpace
docs/
  TEMPLATE_GUIDE.md     # Como criar um novo template
```

## Detecção de contexto

O cctl detecta automaticamente onde está sendo executado e exibe apenas os
comandos disponíveis para aquele contexto:

| Contexto | Condição | Comandos disponíveis |
|----------|----------|----------------------|
| Repositório cctl | fora de projeto/instância | `init` |
| Diretório de projeto (pré-install) | `project.conf` presente, sem `.cctl-instance` | `install` |
| Instância instalada | `.cctl-instance` presente | todos os operacionais |

## Templates disponíveis

| Template | Aplicação | Documentação |
|----------|-----------|--------------|
| `moodle` | Moodle LMS | — |
| `dspace` | DSpace (repositório institucional) | — |

Para criar um novo template (ex: GitLab, WordPress, Nextcloud), consulte
[docs/TEMPLATE_GUIDE.md](docs/TEMPLATE_GUIDE.md).

## Decisões técnicas

### Por que Bash puro, sem yq, jq ou Python?

O cctl roda em servidores que muitas vezes têm apenas o mínimo instalado.
Dependências externas viram pré-requisito de instalação — e pré-requisito de
manutenção. Bash 5 + coreutils cobrem tudo que o cctl precisa: parsing de
variáveis, manipulação de strings, chamadas a `docker`. A única dependência
real é o Docker, que já é o pré-requisito do próprio workload.

### Por que um diretório por projeto em vez de branches git?

Branches no repositório do cctl exigem que cada usuário faça fork da ferramenta
para gerenciar seus projetos — o histórico do cliente fica misturado com o
histórico da ferramenta. Com o modelo de diretório standalone, `cctl init` gera
um diretório autocontido que o usuário pode ou não versionar, em qualquer
repositório git que queira. O cctl é apenas a ferramenta; o projeto é do usuário.

### Por que `{{DOUBLE_BRACES}}` nos templates nginx em vez de `$VARIAVEL`?

Templates com `$VAR` exigem `envsubst` e colidem com variáveis do nginx
(`$host`, `$uri`, `$remote_addr`). `{{DOUBLE_BRACES}}` não colide com shell,
nginx, nem com outros sistemas de template. A substituição é feita com `sed`,
tornando cada render explícito e auditável.

### Por que `_PLACEHOLDER_` no `.env.template`?

O arquivo `.env` é lido linha por linha via `read` — sem expansão de shell.
Placeholders com `_UNDERSCORES_` são visualmente distintos de variáveis reais,
improváveis de conflitar com valores legítimos, e seguros para substituição
com `sed`.

### Por que detecção de contexto em vez de subcomandos fixos?

O mesmo binário `cctl` serve tanto na máquina do desenvolvedor (onde faz sentido
`init`) quanto no servidor (onde faz sentido `install`, `ps`, `logs`). Expor
todos os comandos em todos os contextos gera confusão e risco de operação
errada. A detecção automática garante que o operador veja — e possa executar —
apenas o que faz sentido no ambiente onde está.

## Licença

MIT
