# Changelog

Todas as mudanças notáveis neste projeto serão documentadas neste arquivo.

O formato é baseado em [Keep a Changelog](https://keepachangelog.com/pt-BR/1.0.0/),
e este projeto adere ao [Semantic Versioning](https://semver.org/lang/pt-BR/).

## [Unreleased] - 2026-09-13 (Frente 1 + Frente 2 do Gauntlet Loop — install/rede/volumes, diagramas e documentação)

### Corrigido (Frente 1 — commit `2a28cce`, Gauntlet 6 aprovado)
- **P1 — `cctl install` abortava quando uma imagem do compose existia apenas localmente** (ex.: construída por `cctl build`, sem registry): `docker compose pull` retornava rc=1 ("pull access denied") e, sob `set -e`, o `install` morria no passo de pull. `compose_pull` (`lib/compose.sh`) passou a fazer pull por serviço: se falhar e a imagem existir localmente, avisa e segue; se não existir, erro duro nomeando a imagem — nunca silencia imagem realmente ausente.
- **P2 — reinstalação com o mesmo `COMPOSE_PROJECT_NAME` falhava** com o `nginx-proxy` preso na rede antiga do projeto ("network ... has active endpoints"). `cctl down` desconecta o proxy antes do `compose down`, e o início do `install` limpa rede órfã.
- **Classe sistêmica de colisão de prefixo**: `docker network/volume ls --filter "name=<proj>"` casa por substring — com `moodle` e `moodle-lab` no mesmo host, um projeto mexia nos recursos do outro (7 sítios afetados, 3 deles destrutivos, incluindo `xargs sudo docker volume rm` apagando volume alheio). Corrigido com label exato do compose (`com.docker.compose.project`) mais filtro por nome com prefixo literal (awk `index()`), em união dos dois ramos — a união importa porque um recurso órfão sem label deixaria de ser coberto, inclusive pelo backup.
- **`compose_service_image` resolvia a imagem da dependência, não a do serviço pedido** — `docker compose config --images <svc>` inclui as dependências e não aceita `--no-deps`. Afetava a decisão de tolerância do P1 (tomada sobre a imagem errada) e o retag/push do `cctl build`, que podia publicar a imagem de uma dependência. Corrigido para parsear o bloco do serviço por indentação (mesma técnica de `compose_buildable_services`).
- **`lib/backup.sh`**: `_backup_rotate` usava glob `<proj>-*`, que casava e apagava backups de outro projeto de prefixo comum; agora exige a forma do timestamp e a remoção de prefixo é literal, sem nome de projeto interpolado em regex.
- **`commands/status.sh`**: soma de tamanho normalizada por unidade (B/kB/MB/GB/TB) — antes somava o número cru e rotulava tudo como MB (2GB virava "2.0MB").
- Qualidade: 313 → 356 testes Bats (0 falhas), `shellcheck -S warning` limpo, bash puro. 6 baterias novas: `compose`, `volumes`, `down`, `clear-all`, `backup`, `status`.

### Adicionado (Frente 2 — diagramas, commit `f39ab3f`)
- Diagramas de arquitetura e workflow refeitos em dark 1440x900 com `animation: "trace"` e preset `blueprint`: `sistema-instalado.architecture.json` → `arquitetura-instalado.html`, `init.workflow.json` → `fluxo-init.html`, `install.workflow.json` → `fluxo-install.html` (workflow de instalação dividido em dois diagramas, antes um único de 12 nós em 3 lanes).
- GIFs animados (`docs/diagramas/*.dark.gif`) embutidos no `README.md`/`docs/USAGE.md` — o GitHub não executa HTML/JS em Markdown, então o embed usa GIF; os HTMLs interativos ficam referenciados para quem clonar o repositório.

### Corrigido (Frente 2 — documentação x código, sessão dedicada)
- **`README.md`**: seção "Referência de comandos" não mencionava `cctl proxy` (Sprint 2), `cctl ssl` (Sprint 3), `cctl rollout` (Sprint 5) nem o ciclo de `cctl build --push` (Sprint 4) — três subcomandos inteiros e o ciclo de build estavam ausentes da referência. Adicionadas as seções correspondentes com os nomes/flags reais conferidos em `commands/*.sh` e `commands/help.sh`.
- **`README.md`**: a seção "Ambiente completo de teste/homologação" ensinava a subir o `nginx-proxy` manualmente (`git clone` + `docker compose up -d`); reescrita para usar `cctl proxy up` (com a ordem dos passos ajustada — clonar o `cctl` antes de subir o proxy).
- **`README.md`**: "Por que Bash puro, sem yq, jq ou Python?" afirmava algo que ainda não era literalmente verdade (`cctl volumes` usava `jq` de forma opcional) — corrigido junto da remoção do `jq` (ver abaixo).
- **`docs/USAGE.md`**: a seção inteira de inicialização documentava uma forma inexistente do comando (`cctl init --project <tipo> --client <nome> --domain <dominio>`) e um fluxo de automação de git que nunca existiu no código (branch `<tipo>-<nome>` a partir de `main`, commit/push automático, `git clone --branch` no servidor). Reescrita com a forma real (`cctl init <template> <nome> [--domain <dominio>] [--dest <caminho>]`, conferida em `commands/init.sh`) e deixando explícito que **não há automação de git nenhuma** — o `init` só copia o template e renderiza `.env`/`project.conf`/vhost. Also corrigidos a tabela "Contextos" (nome do contexto é `project`, não `client_branch`) e os exemplos DSpace/Moodle (removida a criação de branch/`git clone --branch`).
- Este item estava registrado como "observado, não corrigido" na entrada de 2026-09-12 (Sprint 5, revisão C) abaixo — **corrigido nesta rodada**.

### Corrigido (bash puro — último uso opcional de `jq`)
- **`lib/volumes.sh` (`volumes_list`)** usava `jq` de forma opcional para listar bind mounts do compose (`compose_exec config --format json | jq -r '...'`), com fallback "(jq não disponível para listar bind mounts)" quando ausente — o único uso de `jq` em todo o projeto, o que impedia o claim de "bash puro" ser literal. Substituído por `_volumes_bind_mounts` (novo, `lib/volumes.sh`): parseia o YAML resolvido de `docker compose config` (sem `--format json`) por indentação, a mesma heurística que `compose_buildable_services`/`compose_service_image` (`lib/compose.sh`) já usam para achar serviços com `build:` e resolver a imagem de um serviço. `docker inspect` dos containers foi avaliado e descartado: também exigiria `jq` (ou um parser Go-template mais frágil) e só cobre containers *up* no momento, enquanto `cctl volumes` precisa funcionar contra o compose resolvido mesmo com o ambiente parado.
- `grep -rn "jq\|yq\|python" lib/*.sh commands/*.sh cctl` não retorna nenhum uso real (só comentários explicando a decisão acima e a heurística de `compose.sh`).

## [Unreleased] - 2026-09-13 (Sprint 5 - Gauntlet Loop, revisao C - achados do revisor sobre a revisao B)

### Corrigido (bug real de escopo, aprovacao com zero blockers mas 11 observacoes)
- **`rollout_rolling` gravava `LIVE_SLOT="blue"` as cegas, ignorando o slot live real (`lib/rollout.sh`)** — sem checar o slot em trafego, a sequencia `bluegreen` (trafego → green) → `rolling` recriava o container BASE (fora de trafego, no-op silencioso), sondava o alias errado e gravava um state file mentiroso (`LIVE_SLOT="blue"` com o vhost apontando para `<svc>-green`); o `bluegreen` seguinte morria em "Nao foi possivel determinar o alvo atual do vhost". Corrigido: `rollout_rolling` agora resolve o slot live via `_rollout_resolve_live_slot` e **recusa** com erro claro quando o slot live e green — nada e recriado e o state file nao e tocado; o operador deve rodar `bluegreen` (que alterna os slots) antes de usar `rolling` de novo. `tests/rollout.bats` ganhou testes para a recusa (via state file e via inferencia do vhost) e para a sequencia `bluegreen` → `rolling` → `bluegreen` partindo de `LIVE_SLOT="green"`, provando que ela nao termina em erro e que o state file fica coerente a cada passo.
- **`cctl rollout status --service x` descartava a flag em silencio (`commands/rollout.sh`)** — `status) rollout_status ;;` ignorava `"$@"`. Corrigido: `rollout_status` agora aceita `--service <svc>` (com precedencia sobre `ROLLOUT_SERVICE`) e recusa qualquer outro argumento com erro claro, em vez de ignorar em silencio.

### Corrigido (documentacao/testes que afirmavam algo que o disco nao confirmava)
- `CHANGELOG.md` afirmava "`tests/rollout.bats`, novo, 61 testes" — a contagem real conferida no disco e outra (ver nota abaixo do total da suite).
- Dois testes que o `CHANGELOG.md` afirmava existir nao existiam: "state file apontando slot cujo container nao existe" e um teste dedicado para o mock `DOCKER_RM_FAIL` (so `DOCKER_STOP_FAIL` tinha teste; `DOCKER_RM_FAIL` so aparecia no `setup()`). Escritos os dois testes reais em vez de so corrigir o texto.
- A explicacao entre parenteses do bullet do `trap ... RETURN` (e o cabeçalho da secao correspondente em `tests/rollout.bats`) afirmava uma segunda mecanica de disparo do trap ("dispara uma vez com o `local` ainda em escopo") incompativel com o proprio fato relatado (se fosse assim, o `rm` nunca rodaria). Corrigido para descrever so o fato observado (rc=1 sob `set -u` no retorno da funcao) e marcar como hipotese nao confirmada o resto.
- `tests/rollout.bats`: teste "ordem das operacoes e switch -> estado -> dreno" calculava as posicoes de switch/dreno em arquivos de log DIFERENTES e nunca comparava — reescrito para unificar os tres eventos (switch, gravacao do estado via `date -Iseconds` remockado, dreno) num unico log e comparar as posicoes de verdade.
- `tests/rollout.bats` (healthcheck http com 200): assercao vacua (`grep -q ... || true`) reescrita para uma assercao real — revelou que a assercao original conferia o container errado (candidato, quando a sonda roda via `docker exec` no proxy).
- `tests/rollout.bats`: duas secoes numeradas "20" — a segunda (cleanup do override via `trap ... RETURN`) renumerada para "21".
- Comentario adicionado na secao dos testes `_run_strict` avisando para nao "simplifica-los" para `run` (semantica de trap diferente sob o `-E`/`-T` do bats).

### Observado, nao corrigido
- **`docs/USAGE.md`** documenta `cctl init --project <tipo> --client <nome> --domain <dominio>`, incluindo um fluxo inteiro de criacao de branch git + commit/push automatico. Conferido em `commands/init.sh`: a forma real e `cctl init <template> <nome> [--domain <dominio>] [--dest <caminho>]`, e **nao ha nenhuma automacao de git** (branch/commit/push) no codigo — e so copia de template + render de `.env`/`project.conf`/vhost. A divergencia e maior do que so a sintaxe da flag (pre-existente, fora do escopo desta sprint); corrigir so a linha de comando deixaria a prosa ao redor (que descreve o fluxo de git) ainda contradizendo o codigo, entao nao foi mexido — fica registrado aqui para uma sessao dedicada a `docs/USAGE.md`. **Corrigido** na sessao dedicada de documentacao registrada na entrada mais recente deste changelog (topo do arquivo).
- Trap `EXIT`/`INT`/`TERM` para o override de compose (O10): nao implementado nesta rodada — ver "Limitacoes conhecidas".

## [Unreleased] - 2026-09-12 (Sprint 5 - Gauntlet Loop, revisao B - auditoria critica)

### Corrigido (auditoria critica pos-release, 6 blockers levantados e verificados empiricamente)
- **`--image` nao chegava ao slot candidato green (`lib/rollout.sh`, `_rollout_bring_up_candidate`)** — `extends:` resolve o servico a partir do arquivo de `extends.file` de forma independente do merge dos outros `-f`; um `image:` emitido sob o bloco base (`${service}:`) nunca chegava ao candidato green (medido com `docker compose ... config` real: o green resolvia a imagem ANTIGA). O healthcheck passava porque era a versao ja em producao, o trafego era trocado e o state file gravava a imagem nova — mentindo sobre a versao em trafego. Corrigido: quando o slot e green, `image:` e emitido DENTRO do bloco `${service}-green:` (chave local sobrescreve o `extends`); no caminho blue a imagem continua sob `${service}:`.
- **Green candidato nao era recriado, um green orfao podia ser adotado como "versao nova"** — o caminho green de `_rollout_bring_up_candidate` usava `up -d --no-deps` sem `--force-recreate`; `docker compose up -d` reaproveita um container existente cuja definicao resolvida nao mudou, entao um green deixado para tras (`--keep-old`, ou um `_rollout_discard_candidate` cujo `docker rm` falhou silenciosamente) seria adotado como candidato em vez de recriado. Adicionado `--force-recreate` — seguro porque o green nunca esta em trafego no momento em que sobe.
- **Falha do `cp` que aplica o vhost descartava o backup sem restaurar (`_rollout_switch_vhost`)** — no ramo de falha do `cp "${tmpfile}" "${vhost}"`, o backup era removido (`rm -rf "${backup_dir}"`) sem antes tentar restaurar; como `cp` trunca o destino antes de escrever, uma falha no meio (ENOSPC, EIO, ticket do `sudo -n` perdido) podia deixar o vhost vivo vazio/truncado sem backup para recuperar. Corrigido: o ramo de falha agora restaura do backup antes de descarta-lo, e preserva o backup (nao remove) se a propria restauracao tambem falhar.
- **Defesa preventiva (nao correcao de bug real):** o backup do vhost em `_rollout_switch_vhost` passou a usar `cp` sem `-p` — medido na VM alvo (Ubuntu 24.04) que `cp -p` de um arquivo `root:root 644` para um diretorio do usuario NAO falha (ao contrario do que uma hipotese de EPERM sugeria); o modo final do vhost e preservado de qualquer forma porque a restauracao sempre escreve por cima de um arquivo ja existente.
- **`set -euo pipefail` em producao matava caminhos de erro que a suite de testes (sourceada sem esses flags) nao enxergava** — auditoria linha a linha de `lib/rollout.sh` sob a semantica real do `set -e`/`pipefail` do entry point `cctl` (linha 14). Adicionado `|| true` (ou tratamento explicito) em toda substituicao de comando/pipeline cuja falha e tolerada por projeto: `prev_image` (`docker inspect` de container inexistente), todas as leituras via `_rollout_state_get` (chave ausente em state file truncado), as tres pipelines `grep|head|sed`/`grep|tail|grep` de `_rollout_vhost_target`, `docker stop`/`docker rm` de `_rollout_discard_candidate`/`_rollout_drain`, `compose_exec stop` do dreno, a resolucao de `project_network`/`network_connect_nginx`, a segunda chamada a `nginx_test_and_reload` na restauracao do vhost, e a chamada de `_rollout_bring_up_candidate` do rollback do `rolling`. Sem essa correcao, cenarios legitimos (container ja removido, state file legado, vhost sem a chave esperada) matavam o shell **antes** de qualquer mensagem de erro ou limpeza (o override runtime ficava para tras). `tests/rollout.bats` ganhou uma bateria dedicada (`_run_strict`, secao 18) que roda os caminhos de erro num subprocesso com `set -euo pipefail` de verdade.
- **Estado gravado so DEPOIS do dreno — falha no dreno fazia o proximo rollout recriar o slot VIVO** — a ordem em `rollout_bluegreen` era switch do vhost → drain → grava estado; se o dreno falhasse, o container antigo continuava existindo e, sem o estado atualizado, o proximo rollout tomava o slot ANTIGO (na verdade o vivo) como candidato — outage. Corrigido: o estado agora e gravado imediatamente apos o switch do vhost retornar 0, ANTES do dreno; falha do dreno vira aviso (`msg_warn`), nunca falha do rollout inteiro (o trafego ja trocou com sucesso).

### Corrigido (observacoes nao-bloqueantes da mesma auditoria)
- `cctl rollout rolling --health-mode http` sem vhost e sem `--health-port` agora falha cedo, ANTES de recriar o servico, com mensagem clara pedindo `--health-port` ou um vhost existente — antes montava uma URL com porta vazia, falhava por construcao, recriava duas vezes (incluindo o rollback) e acusava "ROLLBACK FALHOU" sem causa real.
- `ROLLOUT_HEALTH_INTERVAL` passou a ser validado (inteiro >= 1) no inicio de `_rollout_parse_args` — com `0` o loop de healthcheck degenerava numa unica tentativa; um valor nao-numerico quebrava a aritmetica do loop com erro obscuro.
- Modo de healthcheck `docker` agora detecta candidato `exited`/`dead`/`removing`/inexistente e falha de imediato, em vez de esperar o timeout inteiro para um container que nunca vai ficar `healthy`.
- `--image` e `--health-path` agora sao validados (`validate_image_ref`/`validate_health_path`, novos em `lib/validate.sh`): charset restrito para a referencia de imagem (sem espacos/quebras de linha — antes um `--image $'x\n    privileged: true'` escrevia YAML arbitrario no override gerado) e `--health-path` precisa comecar com `/` e nao conter espaco/quebra de linha.
- `_rollout_resolve_live_slot` passou a ler o vhost via `core_priv_run cat` (como `_rollout_vhost_target`) em vez de `grep` direto no arquivo — unifica o caminho de leitura e evita que um vhost sem permissao de leitura para o usuario corrente caia silenciosamente em "blue".
- `tests/rollout.bats`: teste vacuo de "proxy ausente" (usava `run` dentro de um `||` que nunca reprovava o teste) reescrito para uma assercao real; mocks `DOCKER_STOP_FAIL`/`DOCKER_RM_FAIL` (ja existiam, nunca exercitados) agora tem testes dedicados; novos testes para green orfao recriado (B2), state file apontando slot cujo container nao existe, e limpeza do override em caminho de erro tolerado (B5).
- `docs/USAGE.md`: corrigido "`cctl rollout rolling` no serve" → "**nao** serve"; adicionada a linha `cctl rollout help` na tabela de comandos; documentadas as duas limitacoes de escopo do rollout (imagem nao persistida — reversao silenciosa num `up`/`update` seguinte; resto do `cctl` nao conhece o slot green — risco com `--remove-orphans`).
- `.gitignore`: adicionadas `.cctl-rollout` e `docker-compose.rollout.yaml` (estado/override runtime do rollout, nunca versionados) junto de `.env`/`.cctl-instance`.

### Corrigido (E2E real na VM de lab — defeito que os mocks nao reproduzem)
- **`trap ... RETURN` x variavel `local`: rollout BEM-SUCEDIDO retornava rc=1** — o cleanup do override de compose lia um `local` (`${override_file}`) que **ja saiu de escopo** quando o `trap ... RETURN` dispara, no retorno da funcao de rollout; sob `set -u` isso virava `unbound variable` e fazia o comando terminar com rc=1 **depois** de trocar o trafego com sucesso — o defeito aparecia apenas no codigo de saida, silencioso para quem le a tela (por que o override ainda aparecia removido apesar do erro nao foi instrumentado/confirmado; sem `functrace`/`set -T` um `trap ... RETURN` dispara uma unica vez, entao nao afirmamos aqui uma segunda mecanica de disparo do trap — so o fato comprovado: o rc=1 sob `set -u` no retorno da funcao). Agora o caminho do override vive num global (`_ROLLOUT_OVERRIDE_TMP`), o cleanup e uma funcao unica e idempotente (`_rollout_cleanup_override`) chamada explicitamente no fim do caminho feliz, com o trap mantido como rede de seguranca para saidas antecipadas. **Achado apenas no E2E real** (docker/compose de verdade, `cctl proxy up` do zero → `install` → blue/green): a suite com mocks nao reproduz o timing de escopo do `trap ... RETURN`, e o teste estrito de fluxo feliz que ja existia passava com o defeito presente. `tests/rollout.bats` ganhou 4 testes que travam o invariante (cleanup a partir de frame sem os `local`, idempotencia, e ausencia de resíduo/`unbound` nos fluxos felizes de `bluegreen` e `rolling` sob `set -euo pipefail`).

## [Unreleased] - 2026-09-12 (Sprint 5 - Gauntlet Loop)

### Adicionado
- **`cctl rollout` (`commands/rollout.sh` + `lib/rollout.sh`, novos)** — estrategias de rollout em single-host:
  - `cctl rollout bluegreen [--service <svc>] [--image <ref>] [--health-mode auto|docker|http] [--timeout <s>] [--health-path <p>] [--health-port <p>] [--drain <s>] [--keep-old]`: sobe a versao candidata num slot paralelo ("green", container `${COMPOSE_PROJECT_NAME}-<svc>-green` gerado por um override de compose runtime com `extends:` do compose base), aguarda o healthcheck, so entao reescreve a linha `set $target` do vhost live (preservando porta/indentacao) e recarrega o nginx (`nginx -t` + `nginx -s reload`), e drena o slot anterior apos `ROLLOUT_DRAIN_SECONDS` (salvo `--keep-old`). Falha de healthcheck **nunca** toca o vhost; falha do `nginx -t` apos o switch restaura o backup do vhost e recarrega de novo — em ambos os casos o candidato e descartado e o trafego permanece no slot anterior.
  - `cctl rollout rolling [mesmas flags, exceto --drain/--keep-old]`: recreate seguro do mesmo alias (`--force-recreate`, sem trocar trafego); falha de healthcheck aciona rollback automatico recriando com a imagem anterior (capturada via `docker inspect` antes do deploy) e reporta `ROLLBACK EXECUTADO`/`ROLLBACK FALHOU`.
  - `cctl rollout status`: slot live, container, status/saude, alvo do vhost, imagem em uso e data do ultimo rollout — tolerante a ausencia de estado/container (avisos, nao erro fatal).
  - Resolucao do slot live: arquivo de estado (`ROLLOUT_STATE_FILE`, default `.cctl-rollout`, formato `CHAVE="valor"` sourceable mas lido por parsing, nunca por `source` direto) com fallback para inferencia a partir do `set $target` do vhost quando o estado nao existe/nao bate.
  - Healthcheck com timeout/intervalo configuraveis: modo `docker` (`docker inspect` do `.State.Health.Status`), modo `http` (sonda `curl`/`wget`, com auto-deteccao, executada via `docker exec` no container de sonda — default o proxy nginx — sucesso = HTTP 2xx), e `auto` (detecta `healthcheck:` no candidato e escolhe entre os dois). Nunca faz `sleep` as cegas alem do tempo restante ate o timeout.
  - `lib/compose.sh`: `compose_exec_override` (wrapper sobre `compose_exec` para o `-f` do override runtime gerado pelo rollout).
  - `ROLLOUT_SERVICE` (string simples) documentado e adicionado aos templates `moodle` (`moodle-app`) e `dspace` (`dspace-angular`, explicito porque o vhost do dspace tem dois `set $target`).
  - Knobs em `cctl.conf`: `ROLLOUT_HEALTH_MODE`, `ROLLOUT_HEALTH_TIMEOUT`, `ROLLOUT_HEALTH_INTERVAL`, `ROLLOUT_HEALTH_PATH`, `ROLLOUT_HEALTH_PORT`, `ROLLOUT_DRAIN_SECONDS`, `ROLLOUT_STATE_FILE`, `ROLLOUT_PROBE_CONTAINER`.
- **Bateria de testes Bats (`tests/rollout.bats`)**: cobre o fluxo feliz do Blue/Green, falha de healthcheck (vhost byte-identico ao original, candidato removido), falha de `nginx -t` apos o switch (restauracao do backup), os tres modos de healthcheck (incluindo auto-deteccao curl→wget e ausencia de ambos), propagacao de `--image` para os servicos green/blue no override gerado, o arquivo de `COMPOSE_FILES` que define o servico (caso de dois arquivos, ex. `dspace`), alternancia de slot live via arquivo de estado, validacao de flags (inteiros invalidos/negativos, flags exclusivas do bluegreen usadas em `rolling`), servico inexistente, proxy ausente, `--keep-old`, rollback do `rolling` (com verificacao de ordem dos comandos), `rollout status` com/sem estado, remocao do override em todos os caminhos de erro, o cleanup do override sob `set -euo pipefail` real (secao 21: invariante do global, idempotencia, sem `unbound variable`), e um teste dedicado de ordenacao garantindo que o vhost so e tocado apos o healthcheck passar. Contagem conferida no disco em 2026-09-13 (fim da Sprint 5, apos as rodadas 3 e 4 do Gauntlet): **97 `@test` em `tests/rollout.bats`, 313 testes na suíte inteira do repositorio (100% passando)** — números que envelhecem a cada sprint; confira `grep -c '^@test' tests/rollout.bats` e a primeira linha de `tests/run_tests.sh` para o valor corrente.
- Documentacao atualizada: `docs/USAGE.md` (secao "Rollout (Blue/Green)" com modelo de slots, exemplo com dominio ficticio e limitacoes), `docs/TEMPLATE_GUIDE.md` (`ROLLOUT_SERVICE` e convencao de healthcheck), `commands/help.sh` e `cctl-completion.bash` (acoes e flags de `rollout`).

### Corrigido (revisao de integracao com Docker Compose real, antes do release)
- **`extends.file` do override de compose runtime** — o Docker Compose resolve `extends.file` relativo ao diretorio do arquivo de OVERRIDE, nao ao CWD; escrever o path completo de `COMPOSE_FILES[0]` (ex.: `docker/docker-compose.yaml`) quebrava 100% das instalacoes reais (`no such file or directory`, path duplicado). Corrigido: novo `_rollout_compose_file_for_service` localiza o arquivo de `COMPOSE_FILES` que efetivamente DEFINE o servico (nao necessariamente o primeiro — ex. template `dspace`, onde `dspace-angular` esta no segundo arquivo), o override e gerado no mesmo diretorio desse arquivo e `extends.file` passa a ser sempre o basename (nunca um caminho com `/`).
- **Sonda HTTP indisponivel (sem `curl`/`wget`)** — `_rollout_health_wait` tratava `_rollout_probe_http` como booleano, entao o rc=2 (sonda indisponivel) era engolido e o loop continuava tentando ate estourar o timeout total. Agora o rc e capturado explicitamente: rc=2 aborta a espera de imediato (sem novas tentativas/sleeps), preservando o erro claro que ja era logado.
- **Porta gravada no estado do rollout** — `LIVE_TARGET` usava a porta de `--health-port` (porta da sonda), que pode divergir da porta real do servico/vhost; `rollout status` chegava a exibir a porta errada. Agora grava sempre a porta do vhost (`--health-port` fica restrito a sonda de saude).
- **`max-time` da sonda HTTP** podia ultrapassar o timeout total do rollout quando `--health-mode http`/intervalo eram maiores que o tempo restante; agora e limitado a `min(intervalo, timeout - decorrido)`, minimo 1s.

### Limitações conhecidas
- O dreno do slot anterior e por tempo fixo (`--drain`/`ROLLOUT_DRAIN_SECONDS`), nao por contagem de conexoes ativas.
- **O `nginx -s reload` e graceful: a troca de trafego nao e instantanea para um cliente que conecte imediatamente apos o `cctl rollout bluegreen` retornar** — conexoes **ja estabelecidas** (inclusive keep-alive reutilizado) continuam sendo servidas com a configuracao anterior ate terminarem. Observado no E2E real na VM, no caminho `--keep-old` (que por definicao nao espera o dreno): uma requisicao disparada no mesmo instante da troca foi atendida pelo slot ANTERIOR e a requisicao seguinte, segundos depois, pelo slot NOVO — comprovado pelos logs de acesso dos dois containers. No caminho default o `--drain` (`ROLLOUT_DRAIN_SECONDS`, 10s) **mantém o slot anterior atendendo durante esse intervalo — o que evita erro de conexao, nao torna a troca instantanea**: `_rollout_drain` dorme antes de parar o slot anterior, e e por isso que esse default existe. Quem precisar de garantia mais forte deve validar conteudo/health apos o rollout (em vez de assumir troca instantanea) e/ou aumentar `--drain`.
- A sonda HTTP roda de dentro da rede do projeto via `docker exec` no container de sonda (default: o proxy nginx); sem `curl`/`wget` la dentro, o modo `http` falha com erro claro em vez de degradar silenciosamente (a espera aborta de imediato, sem esperar o timeout total).
- O override de compose runtime depende de `extends:` (recurso do `docker compose` file format) — validado com `docker compose` real na VM de lab (herança de `depends_on`, `--no-deps` subindo somente o candidato); a suite de testes automatizados continua usando mocks e nao pode atestar o `extends:` em si.
- `_rollout_vhost_target`/`_rollout_switch_vhost` usam `grep`/`sed` sobre o texto do vhost (bash puro, sem parser de Nginx) — dependem da linha `set $target <alias>:<porta>;` aparecer exatamente nesse formato (o gerado pelos templates atuais); um vhost editado manualmente fora dessa convencao pode nao ser reconhecido.
- `cctl rollout rolling` nao usa um segundo slot: o candidato e sempre o proprio servico do compose recriado (`--force-recreate`), o que implica uma breve janela sem esse container durante a recriacao (aceitavel para o caso de uso "recreate seguro", diferente do Blue/Green).
- **O switch do Blue/Green reescreve o vhost VIVO em `NGINX_VHOSTS_DIR` (`/etc/nginx-proxy/vhosts.d/<projeto>.conf`), nao o `./nginx/site.conf` da instancia** — este ultimo continua sendo o render base do `cctl install` e nao reflete o slot ativo apos um rollout. `cctl rollout status` (ou o proprio vhost vivo) e a fonte da verdade sobre o slot em trafego, nunca o `site.conf` da instancia.
- **A imagem do rollout nao e persistida em lugar nenhum** — o override runtime e efemero (sempre removido ao final); o `.env`/compose da instancia continuam declarando a imagem antiga, entao um `cctl up`/`cctl update` posterior **reverte silenciosamente** a versao em producao. O rollout e o mecanismo de troca de trafego/recreate seguro, nao de persistencia — atualize o `.env` da instancia para tornar a nova versao permanente.
- **O resto do `cctl` nao conhece o slot green** — `cctl ps`/`stop`/`down`/`up` operam so sobre o compose base, sem o override do rollout; o container `<svc>-green` aparece pra eles como orfao, e `up --remove-orphans` pode derruba-lo mesmo em trafego.
- **Nao ha `trap EXIT`/`INT`/`TERM` para o override de compose** — um `Ctrl-C` durante o `docker compose up` do candidato deixa `docker-compose.rollout.yaml` no disco. Dano cosmetico, nao funcional: o arquivo esta no `.gitignore` e o compose base nao o carrega (so o proprio comando de rollout usa `-f` explicito nele). Decisao desta sprint: nao implementar — o `trap ... RETURN` (rede de seguranca para os `return 1` de dentro da funcao) ja cobre os caminhos de erro normais, e um `trap EXIT/INT/TERM` tornaria `_ROLLOUT_OVERRIDE_TMP` estado de PROCESSO (nao mais so de funcao), exigindo prova de que uma execucao aninhada/concorrente do rollout nao apaga o override de outra — escopo maior do que o cosmetico do problema justifica nesta rodada.

---

## [Unreleased] - 2026-09-12 (Sprint 4 - Gauntlet Loop)

### Adicionado
- **Ciclo completo de `cctl build` (`commands/build.sh`)**:
  - Build de todas as imagens com `build:` do compose (comportamento anterior preservado) ou de servicos especificos, com validacao previa via `compose_service_exists` (erro claro listando servicos disponiveis para nome invalido, sem chamar o Docker).
  - Flags `--no-cache` e `--pull` repassadas ao `docker compose build`.
  - `-t`/`--tag <tag>`: retagueia as imagens construidas via `docker tag` com referencia sanitizada (minusculas) montada por `registry_image_ref`.
  - `--custom <servico>`: build de Dockerfile customizado do projeto fora do compose, convencao `docker/custom/<servico>/Dockerfile` (override via `CUSTOM_BUILD_DIR`).
  - `--push [--registry <url>]`: publica as imagens construidas/taggeadas apos build bem-sucedido.
  - `--help`/`-h` e erro de uso sintetico para flags invalidas.
- **`lib/registry.sh` (novo)** — ciclo de autenticacao e push:
  - `registry_login`: `docker login --password-stdin` lendo token de `CCTL_REGISTRY_TOKEN`/`GHCR_TOKEN`/`DOCKER_TOKEN` — token nunca passa por argumento de linha de comando nem e logado; sem token no ambiente, reaproveita sessao existente em `~/.docker/config.json` ou falha com erro claro (nunca tenta login as cegas).
  - `registry_image_ref`: monta a referencia completa da imagem (`${registry}/${projeto}-${servico}:${tag}`), sanitizada em minusculas.
  - `registry_push` e `registry_logout`.
  - `core_bootstrap` (`lib/core.sh`) atualizado para carregar a nova lib.
- **Helpers em `lib/compose.sh`**: `compose_service_exists`, `compose_list_services`, `compose_service_image` (resolucao da imagem efetiva pos-build) e `compose_build_service` (build de servicos especificos); `compose_build` existente passou a checar retorno e propagar erro.
- **`CUSTOM_BUILD_DIR`** documentado em `cctl.conf` (default `docker/custom`).
- **Bateria de Testes Bats (`tests/build.bats`, novo)**: cobre build sem args, build de servico especifico, servico inexistente, `--no-cache`/`--pull`, `--tag` (sanitizacao), `--custom` (Dockerfile presente/ausente), `--push` (login+push na ordem correta, falha sem credenciais/sessao), `registry_image_ref`, propagacao de falha de `docker compose build`, e um teste dedicado de seguranca garantindo que o token nunca aparece nos argumentos/log do `docker login`.
- Documentacao atualizada: `docs/USAGE.md` (secao de customizacao/build e referencia de comandos), `docs/TEMPLATE_GUIDE.md` (convencao `docker/custom/<servico>/Dockerfile`), `commands/help.sh` e `cctl-completion.bash` (flags do `build`).

### Limitações conhecidas
- `compose_buildable_services` identifica serviços buildáveis por heurística de indentação sobre a saída de `docker compose config` (bloco `services:` em profundidade 2, `build:` em profundidade 4). Compatível com a saída padrão do Docker Compose; formatos exóticos podem exigir ajuste.
- `compose_build_service` e `_build_custom` devolvem resultados por nameref (`local -n`), exigindo Bash ≥ 4.3.
- `_registry_has_session` faz `grep -qF` no arquivo `~/.docker/config.json` inteiro (não apenas no bloco `auths`); uma chave `"<host>":` em `credHelpers` também casa. A checagem é deliberadamente permissiva — sem parser JSON, não é possível consultar um credential helper externo.
- `_compose_file_args` (`lib/compose.sh`) ainda devolve os argumentos por `echo` e `compose_exec` os expande sem quotes (`SC2086`); quebra com `COMPOSE_FILES` contendo espaços. Dívida pré-existente à Sprint 4, registrada para correção futura.

---

## [0.1.3] - 2026-09-12 (Sprint 3 - Gauntlet Loop)

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
