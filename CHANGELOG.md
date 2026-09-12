# Changelog

Todas as mudanças notáveis neste projeto serão documentadas neste arquivo.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/),
e este projeto adere ao [Semantic Versioning](https://semver.org/lang/pt-BR/).

## [Unreleased] - 2026-09-12 (Sprint 2 - Gauntlet Loop)

### Adicionado
- **Subcomando Oficial de Proxy Nativo (`cctl proxy`)**:
  - `commands/proxy.sh` com suporte a `up`, `down`, `reload`, `test`, `logs` e `status`.
  - Provisionamento e garantia da rede Docker global `cctl-proxy-net` (`PROXY_NETWORK`).
  - Execução gerenciada do container `nginx-proxy` (`ghcr.io/diegobianchetti/nginx-proxy`) com portas HTTP/HTTPS configuráveis, restart automático (`unless-stopped`) e privilégio de rede (`--cap-add NET_RAW`).
  - Montagem contratual exata dos vhosts em `/etc/nginx/conf.d/vhosts:ro` (preservando `block-injects.conf`, `default.conf` e `error-pages.conf` nativos da imagem), certificados SSL (`/etc/nginx/certs:ro`), Let's Encrypt (`/etc/letsencrypt:ro`) e ACME webroot (`/var/www/certbot:ro`).
  - Suporte a reload sem downtime (`cctl proxy reload`), teste de sintaxe (`cctl proxy test`) e streaming de logs (`cctl proxy logs -f`).
  - Disponibilidade global no core (`lib/core.sh`): comando `proxy` acessível em qualquer contexto (`template`, `project`, `instance`, `unknown`).
  - Autocomplete Bash em `cctl-completion.bash` para todos os subcomandos e flags de proxy.
- **Bateria de Testes Bats do Proxy (`tests/proxy.bats`)**:
  - 38 novos testes de unidade cobrindo todos os subcomandos, contratos exatos de montagem, tratamento de erros, pré-condições de container ausente e despacho de argumentos. Suíte expandida para **123 testes (100% passando)**.

### Modificado
- `lib/nginx.sh`: incorporadas as funções `nginx_proxy_*` e pré-condições amigáveis `_nginx_proxy_require_container`.
- `cctl.conf`: documentados os knobs `PROXY_NETWORK`, `NGINX_PROXY_IMAGE`, `PROXY_HTTP_PORT`, `PROXY_HTTPS_PORT` e `LETSENCRYPT_DIR`.

---

## [0.1.1] - 2026-09-11 (Sprint 1 - Gauntlet Loop)

### Adicionado
- **Suíte de Testes Unitários Bats (`tests/`)**:
  - 85 testes unitários cobrindo `core`, `env`, `init`, `network`, `nginx`, `ssl` e `validate`.
  - Framework Bats vendorizado (`tests/vendor/`) com tags pinadas (`bats-core@v1.11.1`, `bats-support@v0.3.0`, `bats-assert@v2.2.4`) e isolado no `.gitignore`.
  - Sistema de mocks em `tests/helpers/common.bash` (`docker`, `ss`, `host`, `sudo` com passthrough de `-n`) garantindo isolamento absoluto: zero containers criados e zero portas reais bindadas no host.
  - Script runner de testes `tests/run_tests.sh`.
- **Validação de Nomes de Projeto (`validate_project_name`)**:
  - Whitelist estrita `^[a-z0-9][a-z0-9_-]{1,62}$` em `lib/validate.sh` para blindar contra path traversal (`../`), injeção de comandos e quebra de delimitadores `sed` (`|`, `&`).
- **Gerenciamento Unificado de Privilégios (`core_priv_run`)**:
  - Função centralizada em `lib/core.sh` que avalia permissões por operação (`rm`, `cp`, `install`, `mkdir`).
  - Checagem de legibilidade na origem e gravabilidade no destino antes de invocar `sudo`.
  - Suporte não-interativo via `sudo -n` com mensagens de erro diagnósticas audíveis.
- **Configuração Centralizada em `cctl.conf`**:
  - Knobs documentados para `NGINX_CONTAINER_NAME`, `NGINX_VHOSTS_DIR`, `SSL_MODE`, `SSL_CERTS_DIR`, `LETSENCRYPT_LIVE_DIR`, `CERTBOT_WEBROOT_DIR` e `CERTBOT_EMAIL` usando `${VAR:-...}` para preservar overrides de ambiente.

### Modificado
- **Reaproveitamento de Diretórios no `cctl init` (`commands/init.sh`)**:
  - Aceita diretório pré-existente caso esteja vazio, viabilizando o workflow documentado de pré-criação de diretório em `/opt/<nome>` com `sudo mkdir` + `sudo chown`.
  - Rejeita com erro descritivo somente se o diretório contiver arquivos ou não tiver permissão de leitura/escrita.
- **Des-hardcodificação de Caminhos em `lib/ssl.sh` e `commands/list.sh`**:
  - Substituição de caminhos estáticos `/var/docker/...` por variáveis configuráveis com fallbacks compatíveis com `nginx-proxy`.
  - Instalação de chaves privadas migrada para `install -m 600`, eliminando janela de exposição entre criação e permissão.
- **Sudo Condicional no Nginx (`lib/nginx.sh`)**:
  - `_nginx_priv` refatorado como wrapper fino de `core_priv_run`.
  - `nginx_disable_site` migrado para diretórios de backup únicos e seguros via `mktemp -d`.

### Corrigido
- Eliminação de injeção de comandos via caminho de `--dest` no subshell de parsing do `project.conf` em `commands/init.sh`.
- Adição de checagens de retorno estritas (`|| return 1`) em todas as operações de disco (`mkdir -p`, `cp`, `sed`) em `commands/init.sh` e `lib/nginx.sh`.

---

## [0.1.0] - 2026-04-01

### Adicionado
- Versão inicial do orquestrador `cctl` em Bash puro.
- Suporte a templates de deploy (Moodle, DSpace).
- Subcomandos de lifecycle (`init`, `install`, `up`, `down`, `start`, `stop`, `restart`, `status`, `ps`, `logs`, `config`).
- Gerenciamento de rede Docker, volumes e credenciais geradas localmente.
- Integração com proxy reverso compartilhado e suporte a SSL (`letsencrypt`, `manual`).
