# Changelog

Mudanças notáveis do projeto. Formato baseado em
[Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/); versões seguem o
[Semantic Versioning](https://semver.org/lang/pt-BR/).

## [1.0.0] - 2026-11-17

Primeira versão estável. O `cctl` administra um container `nginx-proxy`
compartilhado, que cuida do roteamento e dos certificados, e as instâncias de
projeto instaladas por ele num mesmo host Linux.

### Mudanças incompatíveis com a 0.1.0
- **Exige `sudo` e o grupo `docker`.** O `cctl` roda como usuário comum com
  permissão de sudo; o `install` confere isso antes de baixar imagens.
- **Raiz única configurável.** Todo o estado fica sob `CCTL_BASE_DIR` (default
  `/opt/cctl`): `instances/`, `nginx-proxy/vhosts.d/` e `nginx-proxy/certs/`.
  Só `/etc/cron.d` e `/etc/logrotate.d` continuam fixos. Instalações da 0.1.0
  em `/etc/nginx-proxy/` ou `/var/docker/` não são migradas.
- **Certificados dentro do container.** O `certbot` e a renovação rodam no
  `nginx-proxy`, com autenticador `webroot`; o host não precisa mais do
  `certbot`. Os certificados ficam num único diretório, montado em
  `/etc/letsencrypt`.
- **Uma rede Docker por projeto, criada pelo `cctl`.** As redes saem de blocos
  `/24` de `CCTL_NETWORK_RANGE` (default `10.240.0.0/16`) e o compose as usa
  como `external: true`. `SUBNET_RANGE` saiu dos templates.
- **`MOODLE_SSL` saiu do núcleo.** O TLS na borda depende só de `HOST_SSL` e
  `SSL_MODE`; `MOODLE_SSL` ficou no template `moodle`.
- **Template `dspace` só para dev/teste.** Vem em HTTP (`SSL_MODE="none"`), sem
  backup de banco agendado e sem as customizações de Solr e do
  `dspace-angular` da 0.1.0.
- **Falha no cron, no logrotate ou no hook `post-install` interrompe o
  `install`.** Não há mais fallback para a crontab do usuário.

### Adicionado
- `cctl proxy` (`up`, `down`, `reload`, `test`, `logs`, `status`), com limites
  de memória e CPU configuráveis (`NGINX_MEMORY_LIMIT`, `NGINX_CPU_LIMIT`).
- `cctl ssl` (`status`, `issue`, `renew`) com os modos `letsencrypt`,
  `self-signed`, `manual` e `none`. No `manual`, o par de chaves é conferido
  antes de qualquer escrita (RSA, ECDSA ou Ed25519).
- `cctl rollout` (`bluegreen`, `rolling`, `status`): a troca de tráfego só
  acontece depois do healthcheck; se o `nginx -t` falhar, o vhost anterior
  volta; o `rolling` faz rollback sozinho.
- `cctl paths`: mostra a raiz em uso e cada caminho, com existência e
  permissão de escrita.
- Inventário de instâncias: `init` e `install` registram cada uma, e o
  `cctl list` mostra se está `prepared`, `installed` ou `stale`.
- Suíte de testes Bats (`tests/run_tests.sh`), que roda sem Docker.

### Alterado
- `cctl build` ganhou `--tag`, `--custom`, `--no-cache`, `--pull` e
  `--push [--registry]`. O token do registry vem do ambiente e nunca aparece em
  argumento nem em log.
- `cctl destroy` pede uma única confirmação; EOF ou resposta vazia cancelam.
- O autocomplete Bash cobre todos os subcomandos.
- Toda escrita de vhost segue a mesma ordem: backup, aplicação, `nginx -t` e
  reversão se falhar. O `install` não apaga mais o vhost quando o teste falha.
- `cctl ssl renew` diz se o certificado do domínio foi de fato renovado. A
  renovação vale para todos os certificados do proxy.
- `cctl rollout status` mostra a imagem que está em tráfego, avisa quando o
  container não tem `HEALTHCHECK` e diz se o slot anterior foi parado ou
  removido.
- O `install` recusa, antes de criar qualquer coisa, faixa de rede fora da RFC
  1918 ou que colida com rota do host, e `letsencrypt` com domínio local
  (`localhost`, `*.local`, `*.test`). DNS sem resolução só barra o
  `letsencrypt`; nos outros modos vira aviso.
- O template `moodle` não publica mais o Postgres no host por padrão.

### Corrigido
- Com várias instâncias no mesmo host, cada domínio passou a servir o próprio
  site. Antes, o proxy podia mandar todos para o mesmo container.
- `install` não aborta quando uma imagem existe só localmente; imagem que não
  existe em lugar nenhum continua sendo erro.
- Reinstalar com o mesmo `COMPOSE_PROJECT_NAME` não falha mais por rede órfã.
- Projetos com prefixo comum (`moodle` e `moodle-lab`) não mexem mais em redes,
  volumes ou backups um do outro.
- `cctl build --push` não publica mais a imagem de uma dependência no lugar da
  do serviço pedido.
- `cctl backup` acusa erro quando o dump do banco falha.
- `cctl ssl status` encontra certificados em `live/` com permissão `0700` de
  root e diferencia "sem certificado" de "não consegui consultar".
- Erro do Docker (daemon fora, permissão) não é mais lido como "recurso
  ausente"; o teardown avisa quando não terminou.
- `self-signed` e `manual` com domínio local voltaram a gerar o certificado
  antes de publicar o vhost HTTPS.
- `cctl status` soma o tamanho dos volumes respeitando a unidade.

### Limitações conhecidas
- O dreno do slot anterior no rollout é por tempo fixo (`--drain`). Conexões
  já abertas terminam na configuração anterior.
- A imagem implantada pelo `rollout` não é gravada: um `cctl up` ou
  `cctl update` depois volta à imagem do `.env` da instância.
- Os outros comandos não conhecem o slot green; `up --remove-orphans` pode
  derrubá-lo.
- O rollout só reconhece a linha `set $target ...;` no formato gerado pelos
  templates.
- `COMPOSE_FILES` com espaço no caminho não é suportado.

## [0.1.0] - 2026-06-03

### Adicionado
- Versão inicial do `cctl` em Bash puro, com templates Moodle e DSpace.
- Ciclo de vida: `init`, `install`, `up`, `down`, `start`, `stop`, `restart`,
  `status`, `ps`, `logs`, `config`.
- Operação: `build`, `backup`, `volumes`, `clear-volumes`, `network`,
  `connect`, `update`, `db-check-config`, `db-update-config`, `list`,
  `destroy`, `clear-all` e autocomplete Bash.
- Rede Docker, volumes e credenciais geradas localmente.
- Integração com proxy reverso compartilhado e SSL (`letsencrypt`, `manual`).

[1.0.0]: https://github.com/diegobianchetti/cctl/compare/v0.1.0...v1.0.0
[0.1.0]: https://github.com/diegobianchetti/cctl/releases/tag/v0.1.0
