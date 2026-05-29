# cctl — containers-control

Orquestrador Bash para ambientes Docker containerizados. Automatiza o ciclo
completo de um projeto: inicialização de branch, deploy no servidor e operações
do dia a dia — sem dependências externas além do Docker e do git.

## O que resolve

Manter múltiplos ambientes Docker (clientes, projetos, ambientes de homologação)
num mesmo servidor é trabalhoso: senhas geradas manualmente, subnets conflitantes,
vhosts criados à mão, crons esquecidos. O cctl codifica esse processo num único
fluxo reproduzível:

1. **`cctl init`** (local): cria uma branch git isolada por cliente, copia o
   template correto e gera o vhost nginx para revisão
2. **`cctl install`** (servidor): gera senhas, aloca subnet, renderiza templates,
   sobe os containers, instala crons e registra o vhost no proxy reverso
3. **Operações do dia a dia**: `ps`, `logs`, `backup`, `connect`, `update` e mais

## Pré-requisitos

- Docker Engine 24+
- Docker Compose (plugin V2)
- git 2.x
- Bash 5.x
- [nginx-proxy](https://github.com/diegobianchetti/nginx-proxy) em execução
  (necessário para `cctl install`)

## Fluxo de uso

### 1. Inicialização (na máquina local)

```bash
# No repositório do cctl, na branch main
./cctl init --project moodle --client acme --domain moodle.acme.example.br
```

O `init` cria a branch `moodle-acme`, copia o template, preenche o `.env` com
dados não-sensíveis e faz o commit + push para o remote.

### 2. Instalação (no servidor)

```bash
# Clonar a branch do cliente no servidor
git clone --branch moodle-acme --single-branch <URL_DO_REPO> moodle-acme
cd moodle-acme

# Revisar e ajustar o .env antes de instalar
vi docker/.env

# Instalar
./cctl install
```

O `install` gera as senhas, aloca uma subnet dedicada, sobe os containers,
instala os cron jobs e registra o vhost no nginx-proxy.

### 3. Operações

```bash
./cctl ps               # lista containers e status
./cctl logs             # últimas 50 linhas de log
./cctl logs -100        # últimas 100 linhas
./cctl logs -f          # segue em tempo real
./cctl connect app      # shell no container da aplicação
./cctl status           # resumo de saúde do ambiente
./cctl backup           # executa backup do ambiente
./cctl update           # pull de imagens e recria containers
```

## Referência de comandos

### Ciclo de vida

| Comando | Descrição |
|---------|-----------|
| `init` | Cria branch de cliente a partir de um template |
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
  init.sh               # Cria branch de cliente
  install.sh            # Deploy completo no servidor
  logs.sh               # Exibe logs
  ps.sh                 # Lista containers
  ...                   # Demais comandos
templates/              # Um diretório por tipo de projeto
  moodle/               # Template para Moodle
  dspace/               # Template para DSpace
```

## Detecção de contexto

O cctl detecta automaticamente em qual contexto está sendo executado e exibe
apenas os comandos disponíveis para aquele contexto:

| Contexto | Condição | Comandos disponíveis |
|----------|----------|----------------------|
| Repositório de templates | `templates/` presente | `init` |
| Branch de cliente (pré-install) | `project.conf` sem `.cctl-instance` | `install` |
| Instância instalada | `.cctl-instance` presente | todos os operacionais |

## Decisões técnicas

### Por que Bash puro, sem yq, jq ou Python?

O cctl roda em servidores que muitas vezes têm apenas o mínimo instalado.
Dependências externas viram pré-requisito de instalação — e pré-requisito de
manutenção. Bash 5 + coreutils cobrem tudo que o cctl precisa: parsing de
variáveis, manipulação de strings, chamadas a `docker` e `git`. A única
dependência real é o Docker, que já é o pré-requisito do próprio workload.

### Por que uma branch git por cliente?

Cada cliente tem configurações distintas: domínio, senhas, limites de recurso,
customizações de aplicação. Uma branch por cliente mantém o histórico de
mudanças rastreável por cliente, permite rollback granular (`git checkout`),
e isola merges de atualizações de template — `git merge main` traz melhorias
do template sem tocar no `.env` do cliente.

A alternativa (um diretório por cliente num monorepo flat) perde o histórico
de cada um e dificulta aplicar atualizações de forma seletiva.

### Por que `{{DOUBLE_BRACES}}` nos templates em vez de `$VARIAVEL`?

Templates com `$VAR` exigem `envsubst` ou avaliação de shell — qualquer
variável de shell não definida no ambiente produz string vazia silenciosamente.
`{{DOUBLE_BRACES}}` não colide com variáveis de shell, com configurações do
nginx (`$host`, `$uri`, `$remote_addr`), nem com sintaxe de outros sistemas de
template. A substituição é feita com `sed`, tornando cada render explícito e
auditável.

### Por que detecção de contexto em vez de subcomandos fixos?

O mesmo binário `cctl` serve tanto na máquina do desenvolvedor (onde faz sentido
`init`) quanto no servidor (onde faz sentido `install`, `ps`, `logs`). Expor
todos os comandos em todos os contextos gera confusão e risco de operação
errada (`destroy` num branch local, `init` num servidor de produção). A detecção
automática garante que o operador veja — e possa executar — apenas o que faz
sentido no ambiente onde está.

## Licença

MIT
