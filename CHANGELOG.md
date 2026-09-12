# Changelog

Todas as mudanças notáveis neste projeto serão documentadas neste arquivo.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/),
e este projeto adere ao [Semantic Versioning](https://semver.org/lang/pt-BR/).

## [Unreleased] - 2026-09-12 (Sprint 3 - Gauntlet Loop)

### Adicionado
- **Matriz Completa de SSL (`self-signed`, `letsencrypt`, `manual`, `none`) em `lib/ssl.sh`**:
  - Modo `self-signed`: geração imediata de par RSA-2048 via OpenSSL com Subject Alternative Name (SAN: `DNS:${domain},DNS:*.${domain}`), instalação atômica com permissões restritas (`install -m 600/644`) e recarregamento sem downtime.
  - Modo `letsencrypt`: pré-validação de DNS com fallbacks múltiplos (`host` → `getent` → `nslookup`), emissão automatizada via Certbot webroot e bootstrap de vhost HTTP temporário.
  - Modo `manual`: validação estrita de par de chaves agnóstica de algoritmo (suporta RSA, ECDSA, Ed25519) comparando hashes SHA-256 das chaves públicas DER antes de qualquer alteração no disco; suporte a chaves privadas `0600 root` via leitura privilegiada.
  - Modo `none`: fallback puramente HTTP que não falha nem gera vhosts com diretivas vazias.
  - Resolução de caminhos internos do container via `ssl_get_cert_path` e `ssl_get_key_path`.
  - Suporte a `ssl_status` e `ssl_renew` (com regeneração efetiva de novos pares no modo `self-signed`).
- **Subcomando Oficial `cctl ssl` (`commands/ssl.sh`)**:
  - Ações: `status`, `issue`, `renew`, ajuda/uso, liberado em contexto `instance` e `project`.
- **Location ACME nos Templates Nginx**:
  - Adicionado `location /.well-known/acme-challenge/ { root /var/www/certbot; }` e placeholders `{{SSL_CERT_PATH}}` e `{{SSL_KEY_PATH}}` em `templates/moodle/nginx/site.conf.template` e `templates/dspace/nginx/site.conf.template`.
- **Bateria de Testes Bats (`tests/ssl.bats` e `tests/install.bats`)**:
  - `tests/ssl.bats` ampliada para 54 testes cobrindo todos os 4 modos, pares ECDSA reais e rejeição de incompatibilidade de chaves.
  - `tests/install.bats` (novo, 10 testes) cobrindo o bootstrap isolado do ACME, preservação do vhost final HTTPS, cenários `SSL_MODE=none` com/sem template dedicado e propagação de falhas.
  - Total da suíte: **173 testes (100% passando)**.

### Modificado
- `commands/install.sh`: ordem de bootstrap ajustada (`_install_ssl` antes de `_install_nginx`), checagens estritas de retorno (`|| return 1`) e seleção automática de `site-nossl.conf.template` quando `SSL_MODE=none` ou `HOST_SSL=false`.
- `commands/install.sh`: `_install_bootstrap_letsencrypt_http_vhost` refatorada para usar vhost temporário isolado (`./nginx/.acme-bootstrap.conf`) com rota ACME dedicada, sem jamais sobrescrever o `nginx/site.conf` final.
- `lib/ssl.sh`: novo helper `_ssl_strip_empty_cert_directives()` para remover diretivas `ssl_certificate[_key] ;` vazias em vhosts sem SSL.
- `commands/init.sh`: vhost de referência renderiza caminhos SSL de forma consistente sem deixar diretivas vazias no modo `none`.
- `lib/nginx.sh`: `nginx_test_and_reload` refatorado para delegar a `nginx_proxy_reload`.
- `templates/dspace/project.conf`: `SSL_MODE` alinhado para `"none"`.

### Limitações conhecidas
- `_ssl_strip_empty_cert_directives` remove apenas diretivas `ssl_certificate` vazias; um template customizado de terceiro que declare `listen 443 ssl;` sem certificado correspondente continuará reprovando no `nginx -t`. Nos templates embarcados (`moodle` com `site-nossl` dedicado e `dspace` HTTP puro) esse caminho é inalcançável.
- Os testes de `tests/install.bats` operam com o mock de `docker` retornando sucesso, de modo que `nginx -t` nunca reprova na suíte: ela prova qual vhost foi aplicado, não que seu conteúdo é sintaticamente válido.

---

## [0.1.2] - 2026-09-12 (Sprint 2 - Gauntlet Loop)

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
