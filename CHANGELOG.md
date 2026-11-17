# Changelog

Todas as mudanças notáveis neste projeto são documentadas neste arquivo.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/),
e este projeto adere ao [Semantic Versioning](https://semver.org/lang/pt-BR/).

## [1.0.0] - 2026-11-17

Primeira versão estável. O `cctl` passa a administrar um único container
`nginx-proxy` compartilhado (roteamento e certificados) e as instâncias de
projeto instaladas por ele, num host Linux único. Validada em VM local e em
servidor público com Let's Encrypt real.

### Mudanças incompatíveis com a 0.1.0
- **O `cctl` exige `sudo`.** Roda como usuário normal com permissão de sudo; o
  pre-flight do `install` confere isso antes de baixar imagens. O usuário
  também precisa estar no grupo `docker`.
- **Raiz única configurável.** Todo o estado fica sob `CCTL_BASE_DIR`
  (`cctl.conf`, default `/opt/cctl`): instâncias em `instances/`, vhosts em
  `nginx-proxy/vhosts.d/`, certificados em `nginx-proxy/certs/`. Só
  `/etc/cron.d` e `/etc/logrotate.d` continuam fixos. Instalações da 0.1.0 em
  `/etc/nginx-proxy/` ou `/var/docker/` não são migradas automaticamente.
- **Certificados dentro do container.** O `certbot` e a renovação periódica
  rodam dentro do `nginx-proxy` (autenticador `webroot`); o host não precisa
  mais do binário `certbot`. Há um único ponto de certificado, montado com
  escrita em `/etc/letsencrypt`.
- **Rede por projeto gerenciada pelo `cctl`.** Cada instância ganha a sua rede
  Docker, alocada em blocos `/24` dentro de `CCTL_NETWORK_RANGE` (default
  `10.240.0.0/16`) e consumida pelo compose como `external: true`. O vhost
  aponta para `<container>.<rede do projeto>`, o que corrige o roteamento com
  várias instâncias no mesmo host (antes todos os domínios podiam servir o
  mesmo site). `SUBNET_RANGE` saiu dos templates.
- **`MOODLE_SSL` saiu do núcleo.** O TLS na borda depende só de `HOST_SSL` e
  `SSL_MODE`; `MOODLE_SSL` passa a ser assunto do template `moodle`.
- **Falhas tardias param o `install`.** Falha ao instalar o cron em
  `/etc/cron.d`, no logrotate ou no hook `post-install` interrompe a
  instalação; o fallback para a crontab do usuário foi removido.

### Adicionado
- `cctl proxy` (`up`, `down`, `reload`, `test`, `logs`, `status`): o
  `nginx-proxy` sobe por um compose renderizado em
  `${CCTL_BASE_DIR}/nginx-proxy/`, com limites de memória e CPU configuráveis
  (`NGINX_MEMORY_LIMIT`, `NGINX_CPU_LIMIT`).
- `cctl ssl` (`status`, `issue`, `renew`) com quatro modos de `SSL_MODE`:
  `letsencrypt`, `self-signed`, `manual` (par de chaves conferido antes de
  qualquer escrita, aceita RSA, ECDSA e Ed25519) e `none`.
- `cctl rollout` (`bluegreen`, `rolling`, `status`): blue/green no mesmo host
  com healthcheck (`docker`, `http` ou `auto`), troca de tráfego só depois do
  healthcheck, restauração do vhost se o `nginx -t` falhar e rollback
  automático no `rolling`.
- `cctl build` com `--tag`, `--custom`, `--no-cache`, `--pull` e
  `--push [--registry]`; o token do registry é lido do ambiente e nunca passa
  por argumento nem por log.
- `cctl paths`: mostra a raiz em uso, cada caminho derivado ou fixo e se
  existe e é gravável.
- `cctl list` e inventário de instâncias: `init` e `install` registram cada
  instância, com estado `prepared`, `installed` ou `stale`.
- `cctl destroy`: remove a instância depois de uma única confirmação; EOF ou
  resposta vazia cancelam.
- Autocomplete Bash (`cctl-completion.bash`) para todos os subcomandos.
- Suíte de testes Bats (`tests/run_tests.sh`) com mocks de Docker, sem
  containers nem portas reais.

### Alterado
- Um único módulo escreve os vhosts (`lib/vhost.sh`), sempre na mesma ordem:
  backup, aplicação, `nginx -t` no container e reversão em caso de falha. O
  `install` deixou de apagar o vhost quando o teste falha.
- `cctl ssl renew` compara a validade do certificado do domínio antes e depois
  e diz se ele foi de fato renovado; a renovação em si é global para os
  certificados do proxy.
- `cctl rollout status` mostra a imagem real do container em tráfego, informa
  quando o container não tem `HEALTHCHECK` e diz se o slot anterior foi parado
  ou removido.
- O pre-flight do `install` recusa faixa de rede fora da RFC 1918 ou que
  colida com rota do host, e recusa `letsencrypt` com domínio local
  (`localhost`, `*.local`, `*.test`) antes de criar rede ou container. DNS não
  resolvido só é fatal em `letsencrypt`; nos outros modos vira aviso.
- O template `moodle` deixou de publicar o Postgres no host por padrão.

### Corrigido
- `install` não aborta mais quando uma imagem do compose existe só localmente;
  imagem realmente ausente continua sendo erro.
- Reinstalar com o mesmo `COMPOSE_PROJECT_NAME` não falha mais por rede órfã
  presa ao proxy.
- Projetos com prefixo comum (`moodle` e `moodle-lab`) não mexem mais em redes,
  volumes ou backups um do outro.
- `cctl build --push` não publica mais a imagem de uma dependência no lugar da
  do serviço pedido.
- `cctl backup` falha de forma visível quando o dump do banco falha.
- `cctl ssl status` encontra certificados em `live/` com permissão `0700` de
  root, e distingue "certificado ausente" de "consulta não executada".
- Consultas ao Docker distinguem recurso ausente de erro (daemon fora,
  permissão); o teardown informa quando não terminou em vez de declarar
  sucesso.
- `self-signed` e `manual` com domínio local voltaram a gerar o certificado
  antes de publicar o vhost HTTPS.
- `cctl status` soma o tamanho dos volumes respeitando a unidade.

### Limitações conhecidas
- O dreno do slot anterior no rollout é por tempo fixo (`--drain`), não por
  contagem de conexões; o `nginx -s reload` é graceful, então conexões já
  abertas terminam na configuração anterior.
- A imagem implantada por `cctl rollout` não é persistida: um `cctl up` ou
  `cctl update` posterior volta à imagem declarada no `.env` da instância.
- Os demais comandos não conhecem o slot green do rollout; `up
  --remove-orphans` pode derrubá-lo.
- A troca de alvo do vhost no rollout depende da linha `set $target ...;` no
  formato gerado pelos templates.
- `COMPOSE_FILES` com espaços no caminho não é suportado.

## [0.1.0] - 2026-04-01

### Adicionado
- Versão inicial do orquestrador `cctl` em Bash puro.
- Suporte a templates de deploy (Moodle, DSpace).
- Subcomandos de lifecycle (`init`, `install`, `up`, `down`, `start`, `stop`, `restart`, `status`, `ps`, `logs`, `config`).
- Gerenciamento de rede Docker, volumes e credenciais geradas localmente.
- Integração com proxy reverso compartilhado e suporte a SSL (`letsencrypt`, `manual`).

[1.0.0]: https://github.com/diegobianchetti/cctl/compare/v0.1.0...v1.0.0
[0.1.0]: https://github.com/diegobianchetti/cctl/releases/tag/v0.1.0
