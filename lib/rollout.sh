#!/bin/bash
# lib/rollout.sh — Estrategias de rollout em single-host (Blue/Green, Rolling)
#
# Modelo de slots:
#   slot blue  = container gerenciado pelo compose: "${COMPOSE_PROJECT_NAME}-<svc>",
#                alias de rede "<svc>"
#   slot green = container paralelo (override de compose runtime):
#                "${COMPOSE_PROJECT_NAME}-<svc>-green", alias "<svc>-green"
#
# O slot live alterna a cada rollout bem-sucedido. Um rollout sempre sobe a
# versao nova no slot que NAO esta live e so troca o trafego (set $target do
# vhost) apos o healthcheck do candidato passar.

# Knobs (defaults visiveis mesmo sem cctl.conf — ex. baterias de teste que
# sourceiam esta lib isoladamente)
ROLLOUT_HEALTH_MODE="${ROLLOUT_HEALTH_MODE:-auto}"
ROLLOUT_HEALTH_TIMEOUT="${ROLLOUT_HEALTH_TIMEOUT:-60}"
ROLLOUT_HEALTH_INTERVAL="${ROLLOUT_HEALTH_INTERVAL:-2}"
ROLLOUT_HEALTH_PATH="${ROLLOUT_HEALTH_PATH:-/}"
ROLLOUT_HEALTH_PORT="${ROLLOUT_HEALTH_PORT:-}"
ROLLOUT_DRAIN_SECONDS="${ROLLOUT_DRAIN_SECONDS:-10}"
ROLLOUT_STATE_FILE="${ROLLOUT_STATE_FILE:-.cctl-rollout}"
ROLLOUT_PROBE_CONTAINER="${ROLLOUT_PROBE_CONTAINER:-}"

# Path do override de compose gerado em runtime (docker-compose.rollout.yaml).
#
# GLOBAL DE PROPOSITO — nao use `local` para isto. O cleanup do override roda
# via `trap ... RETURN`, que dispara no retorno da funcao de rollout: nesse
# instante as variaveis `local` do corpo da funcao JA sairam de escopo, e uma
# leitura de `${override_file}` ali vira "unbound variable" sob `set -u`
# (o cctl roda com `set -euo pipefail`), fazendo um rollout BEM-SUCEDIDO
# retornar rc=1. Achado no E2E real na VM de lab (compose/docker de verdade);
# os mocks nao reproduzem essa semantica de escopo do trap.
_ROLLOUT_OVERRIDE_TMP=""

# --- Uso -------------------------------------------------------------------

_rollout_usage() {
    echo -e "${BOLD}Uso:${RESET} cctl rollout <bluegreen|rolling|status|help> [opcoes]"
    echo ""
    echo "  bluegreen [--service <svc>] [--image <ref>] [--health-mode auto|docker|http]"
    echo "            [--timeout <s>] [--health-path <p>] [--health-port <p>]"
    echo "            [--drain <s>] [--keep-old]"
    echo "  rolling   [--service <svc>] [--image <ref>] [--health-mode auto|docker|http]"
    echo "            [--timeout <s>] [--health-path <p>] [--health-port <p>]"
    echo "            (recusa se o slot live for 'green' — rode 'bluegreen' antes)"
    echo "  status    Mostra o estado atual do rollout (slot live, saude, imagem)"
    echo "  help      Exibe esta ajuda"
}

# --- Parsing de argumentos ---------------------------------------------------
#
# Define (sem 'local' — deliberado): RO_SERVICE, RO_IMAGE, RO_HEALTH_MODE,
# RO_TIMEOUT, RO_INTERVAL, RO_HEALTH_PATH, RO_HEALTH_PORT, RO_DRAIN,
# RO_KEEP_OLD. Uso: _rollout_parse_args <bluegreen|rolling> "$@"
_rollout_parse_args() {
    local mode="$1"
    shift

    RO_SERVICE=""
    RO_IMAGE=""
    RO_HEALTH_MODE="${ROLLOUT_HEALTH_MODE:-auto}"
    RO_TIMEOUT="${ROLLOUT_HEALTH_TIMEOUT:-60}"
    RO_INTERVAL="${ROLLOUT_HEALTH_INTERVAL:-2}"
    RO_HEALTH_PATH="${ROLLOUT_HEALTH_PATH:-/}"
    RO_HEALTH_PORT="${ROLLOUT_HEALTH_PORT:-}"
    RO_DRAIN="${ROLLOUT_DRAIN_SECONDS:-10}"
    RO_KEEP_OLD=false

    # ROLLOUT_HEALTH_INTERVAL nao tem flag propria (so env/cctl.conf) mas
    # participa diretamente da aritmetica de _rollout_health_wait — com "0" o
    # loop degenera numa unica tentativa (sem retentativa real) e um valor
    # nao-numerico quebra a aritmetica ($(( interval < remaining )) etc.) com
    # erro obscuro. Validar aqui, uma vez, com mensagem clara.
    if [[ ! "${RO_INTERVAL}" =~ ^[0-9]+$ ]] || (( RO_INTERVAL < 1 )); then
        log_error "ROLLOUT_HEALTH_INTERVAL invalido: '${RO_INTERVAL}' (esperado inteiro >= 1)"
        return 1
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --service)
                if [[ -z "${2:-}" ]]; then
                    log_error "Opcao '--service' requer um valor."
                    _rollout_usage
                    return 1
                fi
                RO_SERVICE="$2"
                shift 2
                ;;
            --image)
                if [[ -z "${2:-}" ]]; then
                    log_error "Opcao '--image' requer um valor."
                    _rollout_usage
                    return 1
                fi
                RO_IMAGE="$2"
                validate_image_ref "${RO_IMAGE}" || return 1
                shift 2
                ;;
            --health-mode)
                if [[ -z "${2:-}" ]]; then
                    log_error "Opcao '--health-mode' requer um valor."
                    _rollout_usage
                    return 1
                fi
                case "$2" in
                    auto|docker|http) ;;
                    *)
                        log_error "--health-mode invalido: '$2' (use auto|docker|http)"
                        return 1
                        ;;
                esac
                RO_HEALTH_MODE="$2"
                shift 2
                ;;
            --timeout)
                if [[ -z "${2:-}" ]]; then
                    log_error "Opcao '--timeout' requer um valor."
                    _rollout_usage
                    return 1
                fi
                if [[ ! "$2" =~ ^[0-9]+$ ]]; then
                    log_error "--timeout invalido: '$2' (esperado inteiro nao-negativo)"
                    return 1
                fi
                RO_TIMEOUT="$2"
                shift 2
                ;;
            --health-path)
                if [[ -z "${2:-}" ]]; then
                    log_error "Opcao '--health-path' requer um valor."
                    _rollout_usage
                    return 1
                fi
                RO_HEALTH_PATH="$2"
                validate_health_path "${RO_HEALTH_PATH}" || return 1
                shift 2
                ;;
            --health-port)
                if [[ -z "${2:-}" ]]; then
                    log_error "Opcao '--health-port' requer um valor."
                    _rollout_usage
                    return 1
                fi
                if [[ ! "$2" =~ ^[0-9]+$ ]]; then
                    log_error "--health-port invalido: '$2' (esperado porta inteira nao-negativa)"
                    return 1
                fi
                RO_HEALTH_PORT="$2"
                shift 2
                ;;
            --drain)
                if [[ "${mode}" != "bluegreen" ]]; then
                    log_error "Opcao '--drain' nao suportada em 'rollout ${mode}'."
                    _rollout_usage
                    return 1
                fi
                if [[ -z "${2:-}" ]]; then
                    log_error "Opcao '--drain' requer um valor."
                    _rollout_usage
                    return 1
                fi
                if [[ ! "$2" =~ ^[0-9]+$ ]]; then
                    log_error "--drain invalido: '$2' (esperado inteiro nao-negativo)"
                    return 1
                fi
                RO_DRAIN="$2"
                shift 2
                ;;
            --keep-old)
                if [[ "${mode}" != "bluegreen" ]]; then
                    log_error "Opcao '--keep-old' nao suportada em 'rollout ${mode}'."
                    _rollout_usage
                    return 1
                fi
                RO_KEEP_OLD=true
                shift
                ;;
            -*)
                log_error "Opcao desconhecida: $1"
                _rollout_usage
                return 1
                ;;
            *)
                log_error "Argumento posicional inesperado: $1"
                _rollout_usage
                return 1
                ;;
        esac
    done

    return 0
}

# --- Helpers de slot ----------------------------------------------------------

# Alias de rede do slot. Uso: _rollout_slot_alias <servico> <blue|green>
_rollout_slot_alias() {
    local service="$1" slot="$2"
    if [[ "${slot}" == "blue" ]]; then
        echo "${service}"
    else
        echo "${service}-green"
    fi
}

# Nome do container do slot. Uso: _rollout_slot_container <servico> <blue|green>
_rollout_slot_container() {
    local service="$1" slot="$2"
    if [[ "${slot}" == "blue" ]]; then
        echo "${COMPOSE_PROJECT_NAME}-${service}"
    else
        echo "${COMPOSE_PROJECT_NAME}-${service}-green"
    fi
}

# Le um campo do arquivo de estado (formato CHAVE="valor" sourceable) sem dar
# source nele (evita executar conteudo arbitrario). Uso: _rollout_state_get
# <arquivo> <CHAVE>
_rollout_state_get() {
    local state_file="$1" key="$2"
    [[ -f "${state_file}" ]] || return 1
    grep -E "^${key}=" "${state_file}" 2>/dev/null | head -1 | sed -E "s/^${key}=\"?([^\"]*)\"?\$/\1/"
}

# Resolve o slot live: (1) o vhost e a fonte da verdade sobre o TRAFEGO — se
# for legivel e tiver um alvo ("set $target") para o alias deste servico
# (blue OU green), decide e retorna direto; (2) so cai para o state file
# quando o vhost nao permitir decidir (ilegivel, ausente, ou sem alvo para
# ESTE servico especifico), e mesmo assim so aceita o slot gravado se o
# container daquele slot ainda existir; (3) sem nenhuma das duas, "blue".
#
# N1 (revisao Sprint 5, rodada 3): antes desta correcao a ordem era invertida
# (state file primeiro) — um switch de 'bluegreen' bem-sucedido (vhost ja
# aponta pro slot novo) seguido de uma gravacao de estado que falha/atrasa
# (disco cheio/ro, restauracao de backup do .cctl-rollout, copia manual do
# diretorio) fazia o state file antigo "vencer" sempre que o container do
# slot antigo ainda existisse (--keep-old ou dreno falho) — 'resolve'
# devolvia o slot ERRADO, 'rolling' nao recusava (recriava fora de trafego,
# no-op silencioso) e o proximo 'bluegreen' morria em "Nao foi possivel
# determinar o alvo atual do vhost".
#
# Cuidado com templates com mais de um "set $target" no mesmo vhost (ex.
# dspace): os padroes abaixo sao ancorados no alias do SERVICO alvo
# ("${service}:" / "${service}-green:", com ':' logo apos o alias) — nunca
# casam com o alias de outro servico, entao a primeira linha "set $target"
# que aparecer no arquivo nao interfere na decisao.
#
# Uso: _rollout_resolve_live_slot <servico>
_rollout_resolve_live_slot() {
    local service="$1"
    local state_file="${ROLLOUT_STATE_FILE:-.cctl-rollout}"

    # Leitura via caminho privilegiado (core_priv_run cat), nao `grep` direto
    # no arquivo: unifica com _rollout_vhost_target e evita que um vhost sem
    # permissao de leitura para o usuario corrente faca a inferencia cair
    # silenciosamente em "blue" (falso-negativo indistinguivel de "vhost
    # aponta para blue"). `|| true`: uma leitura que falha (vhost ilegivel)
    # nao pode matar o shell sob `set -euo pipefail` — so degrada para o
    # fallback do state file.
    local vhost="${NGINX_VHOSTS_DIR}/${COMPOSE_PROJECT_NAME}.conf"
    local vhost_content=""
    if [[ -f "${vhost}" ]]; then
        vhost_content="$(core_priv_run cat "${vhost}" 2>/dev/null)" || true
    fi
    if [[ -n "${vhost_content}" ]]; then
        if printf '%s\n' "${vhost_content}" | grep -qE "^[[:space:]]*set [\$]target[[:space:]]+${service}-green:"; then
            echo "green"
            return 0
        fi
        if printf '%s\n' "${vhost_content}" | grep -qE "^[[:space:]]*set [\$]target[[:space:]]+${service}:"; then
            echo "blue"
            return 0
        fi
    fi

    # Vhost nao permitiu decidir (ilegivel/ausente/sem alvo para este
    # servico) — cai para o state file, mas so aceita se o container do slot
    # gravado ainda existir.
    if [[ -f "${state_file}" ]]; then
        local st_service st_slot
        # `|| true`: sob `set -e` de producao, uma chave ausente/state file
        # truncado faz _rollout_state_get retornar 1 — sem isso, a
        # substituicao de comando mata o shell aqui (o "-> return normal NAO
        # acontece" do set -e), muito antes de qualquer aviso.
        st_service="$(_rollout_state_get "${state_file}" SERVICE)" || true
        st_slot="$(_rollout_state_get "${state_file}" LIVE_SLOT)" || true
        if [[ "${st_service}" == "${service}" && -n "${st_slot}" ]]; then
            local container
            container="$(_rollout_slot_container "${service}" "${st_slot}")"
            if docker inspect "${container}" >/dev/null 2>&1; then
                echo "${st_slot}"
                return 0
            fi
        fi
    fi

    echo "blue"
}

# Le, do vhost, alias:porta e esquema do bloco correspondente a um alias.
# Saida (stdout, uma linha): "<scheme> <port>". Uso:
# _rollout_vhost_target <vhost> <alias>
_rollout_vhost_target() {
    local vhost="$1" alias="$2"
    local content
    content="$(core_priv_run cat "${vhost}")" || return 1

    # `|| true` em cada pipeline: sob pipefail de producao, um `grep` sem
    # match no meio do pipe (alias ausente do vhost) faz a pipeline inteira
    # retornar rc!=0 (o rightmost nonzero) — sem a defesa, a atribuicao mata o
    # shell antes do `[[ -z ... ]] && return 1` seguinte sequer rodar.
    local line_num
    line_num="$(printf '%s\n' "${content}" | grep -nE "^[[:space:]]*set [\$]target[[:space:]]+${alias}:" | head -1 | cut -d: -f1)" || true
    [[ -z "${line_num}" ]] && return 1

    local port
    port="$(printf '%s\n' "${content}" | sed -n "${line_num}p" | grep -oE ':[0-9]+;' | head -1 | tr -d ':;')" || true
    [[ -z "${port}" ]] && return 1

    local scheme
    scheme="$(printf '%s\n' "${content}" | tail -n +"${line_num}" | grep -m1 -oE 'proxy_pass[[:space:]]+(https?):' | grep -oE 'https?')" || true
    [[ -z "${scheme}" ]] && return 1

    echo "${scheme} ${port}"
}

# Reescreve SO as linhas "set $target <alias-antigo>:" para o alias novo
# (preserva porta/indentacao), testa e recarrega o nginx. Em falha do teste,
# restaura o backup e recarrega de novo. Uso: _rollout_switch_vhost <vhost>
# <alias-antigo> <alias-novo>
_rollout_switch_vhost() {
    local vhost="$1" old_alias="$2" new_alias="$3"

    local backup_dir
    backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/cctl_rollout_backup.XXXXXX")" || {
        log_error "Falha ao criar diretorio de backup temporario"
        return 1
    }

    # Backup so precisa do CONTEUDO (nao de -p): o vhost final so e tocado por
    # `cp` (sem -p) escrevendo por cima de um arquivo ja existente, entao
    # dono/modo do vhost em producao (root:root 644) nunca dependem do que o
    # backup preservou. Medido na VM alvo (Ubuntu 24.04): `cp -p` de um
    # arquivo root:root 644 para um diretorio do proprio usuario tambem
    # funciona (rc=0) — a troca para "sem -p" e defesa preventiva de baixo
    # custo, nao correcao de um bug real observado.
    if ! core_priv_run cp "${vhost}" "${backup_dir}/"; then
        log_error "Falha ao criar backup do vhost ${vhost}"
        rm -rf "${backup_dir}"
        return 1
    fi

    local content tmpfile
    content="$(core_priv_run cat "${vhost}")" || {
        log_error "Falha ao ler o vhost ${vhost}"
        rm -rf "${backup_dir}"
        return 1
    }

    tmpfile="$(mktemp)" || {
        log_error "Falha ao criar arquivo temporario"
        rm -rf "${backup_dir}"
        return 1
    }

    printf '%s\n' "${content}" | sed -E "s/^([[:space:]]*set [\$]target[[:space:]]+)${old_alias}:/\1${new_alias}:/" > "${tmpfile}"

    if ! core_priv_run cp "${tmpfile}" "${vhost}"; then
        # `cp` trunca o destino antes de escrever: uma falha aqui (ENOSPC,
        # EIO, ticket do `sudo -n` perdido, sinal) pode deixar o vhost vivo
        # meio-escrito ou vazio. Restaurar do backup ANTES de descarta-lo —
        # nunca apagar o unico backup sem antes tentar recuperar o vhost.
        log_error "Falha ao aplicar a nova configuracao no vhost ${vhost} — restaurando backup..."
        rm -f "${tmpfile}"
        if ! core_priv_run cp "${backup_dir}/$(basename "${vhost}")" "${vhost}"; then
            log_error "Falha ao restaurar vhost de backup para ${vhost} — vhost pode estar em estado inconsistente. Backup preservado em: ${backup_dir}"
            return 1
        fi
        log_warn "Vhost restaurado a partir do backup apos falha ao aplicar a nova configuracao."
        rm -rf "${backup_dir}"
        return 1
    fi
    rm -f "${tmpfile}"

    if nginx_test_and_reload; then
        rm -rf "${backup_dir}"
        return 0
    fi

    log_error "Configuracao nginx invalida apos o switch! Restaurando vhost anterior..."
    if ! core_priv_run cp "${backup_dir}/$(basename "${vhost}")" "${vhost}"; then
        log_error "Falha ao restaurar vhost de backup para ${vhost} — vhost pode estar em estado inconsistente. Backup preservado em: ${backup_dir}"
        return 1
    fi
    nginx_test_and_reload || true
    rm -rf "${backup_dir}"
    return 1
}

# Percorre COMPOSE_FILES e devolve (via stdout) o arquivo que DEFINE o
# servico indicado — necessario porque o Docker Compose resolve
# `extends.file` relativamente ao diretorio do arquivo de OVERRIDE, entao o
# override runtime precisa ficar no mesmo diretorio do arquivo que de fato
# declara o servico (nem sempre o primeiro de COMPOSE_FILES — ex.: template
# dspace, onde `dspace-angular` esta no segundo arquivo). Heuristica de
# indentacao em awk, mesmo estilo de compose_buildable_services (lib/compose.sh):
# entra no bloco top-level "services:", aceita nomes de servico com 2 espacos
# de indentacao, encerra o bloco na proxima chave top-level. Fallback:
# COMPOSE_FILES[0] (ou docker-compose.yml) se nenhum arquivo casar ou nenhum
# existir no disco. Uso: _rollout_compose_file_for_service <servico>
_rollout_compose_file_for_service() {
    local service="$1"
    local f
    for f in "${COMPOSE_FILES[@]}"; do
        [[ -f "${f}" ]] || continue
        if awk -v svc="${service}" '
            /^services:[[:space:]]*$/ { in_services = 1; next }
            in_services && /^[A-Za-z0-9_-]+:[[:space:]]*$/ { in_services = 0 }
            in_services && /^  [A-Za-z0-9._-]+:[[:space:]]*$/ {
                name = $1
                sub(/:$/, "", name)
                if (name == svc) found = 1
            }
            END { exit (found ? 0 : 1) }
        ' "${f}"; then
            echo "${f}"
            return 0
        fi
    done
    echo "${COMPOSE_FILES[0]:-docker-compose.yml}"
    return 0
}

# --- Override de compose runtime ---------------------------------------------
#
# Remove o override de compose gerado em runtime e zera o global. Idempotente,
# seguro a partir de qualquer frame (inclusive do `trap ... RETURN`) e sem
# depender de variaveis `local` — ver o comentario em _ROLLOUT_OVERRIDE_TMP.
_rollout_cleanup_override() {
    if [[ -n "${_ROLLOUT_OVERRIDE_TMP:-}" && -f "${_ROLLOUT_OVERRIDE_TMP}" ]]; then
        rm -f "${_ROLLOUT_OVERRIDE_TMP}"
    fi
    _ROLLOUT_OVERRIDE_TMP=""
    return 0
}

# Gera (se necessario) docker-compose.rollout.yaml no mesmo diretorio do
# arquivo de COMPOSE_FILES que efetivamente DEFINE o servico (ver
# _rollout_compose_file_for_service) e sobe o slot indicado. O `extends.file`
# do override e sempre o basename desse arquivo (nunca um caminho com "/")
# porque o Compose resolve extends.file relativo ao diretorio do PROPRIO
# override, nao ao CWD. Devolve o path do override gerado (ou string vazia
# se nenhum foi necessario) via nameref (4o argumento) — nunca por stdout,
# para nao colidir com a saida do 'docker compose up'. Uso:
# _rollout_bring_up_candidate <servico> <blue|green> <imagem-ou-vazio> <nome-var-saida>
_rollout_bring_up_candidate() {
    local service="$1" slot="$2" image="$3"
    local -n _rbc_out="$4"
    _rbc_out=""

    local compose_base
    compose_base="$(_rollout_compose_file_for_service "${service}")"
    local override_dir
    override_dir="$(dirname -- "${compose_base}")"
    local override_path="${override_dir}/docker-compose.rollout.yaml"
    local extends_file
    extends_file="$(basename -- "${compose_base}")"

    local need_green=false
    [[ "${slot}" == "green" ]] && need_green=true

    # Onde a chave "image:" e emitida importa: `extends:` resolve o servico a
    # partir do arquivo indicado em extends.file, independentemente do merge
    # dos outros `-f` — o green NUNCA herda um `image:` declarado sob o bloco
    # do servico base (isso sobe o candidato green com a imagem ANTIGA,
    # confirmado com `docker compose ... config` real). Por isso, quando o
    # slot e green, "image:" vai DENTRO do bloco "${service}-green:" (chave
    # local sobrescreve o extends); quando o slot e blue, a imagem vai sob
    # "${service}:" normalmente (e o que a recriacao usa).
    local wrote=false
    {
        echo "services:"
        if [[ -n "${image}" && "${need_green}" != "true" ]]; then
            echo "  ${service}:"
            echo "    image: ${image}"
            wrote=true
        fi
        if [[ "${need_green}" == "true" ]]; then
            echo "  ${service}-green:"
            echo "    extends:"
            echo "      file: ${extends_file}"
            echo "      service: ${service}"
            echo "    container_name: ${COMPOSE_PROJECT_NAME}-${service}-green"
            echo "    hostname: ${service}-green"
            if [[ -n "${image}" ]]; then
                echo "    image: ${image}"
            fi
            wrote=true
        fi
    } > "${override_path}"

    if [[ "${wrote}" != "true" ]]; then
        rm -f "${override_path}"
        override_path=""
    fi

    local rc=0
    if [[ "${slot}" == "green" ]]; then
        # --force-recreate e seguro aqui: o slot green nunca esta em trafego
        # no momento em que sobe (o candidato e sempre o slot NAO-live) — sem
        # essa flag, um green orfao deixado para tras (--keep-old, ou um
        # _rollout_discard_candidate que falhou) e ADOTADO como se fosse a
        # versao nova, porque `up -d` reaproveita um container existente cuja
        # definicao resolvida nao mudou.
        compose_exec_override "${override_path}" up -d --no-deps --force-recreate "${service}-green" || rc=$?
    else
        compose_exec_override "${override_path}" up -d --no-deps --force-recreate "${service}" || rc=$?
    fi

    if [[ ${rc} -ne 0 ]]; then
        [[ -n "${override_path}" ]] && rm -f "${override_path}"
        return 1
    fi

    _rbc_out="${override_path}"
    return 0
}

# --- Healthcheck --------------------------------------------------------------

# Detecta curl/wget dentro do container de sonda e sonda a URL. Sucesso =
# HTTP 2xx. Uso: _rollout_probe_http <container-sonda> <url> <max-time-s>
_rollout_probe_http() {
    local probe="$1" url="$2" max_time="$3"

    if docker exec "${probe}" sh -c 'command -v curl' >/dev/null 2>&1; then
        local code
        code="$(docker exec "${probe}" curl -sS -k --max-time "${max_time}" -o /dev/null -w '%{http_code}' "${url}" 2>/dev/null)"
        [[ "${code}" =~ ^2[0-9][0-9]$ ]]
        return $?
    fi

    if docker exec "${probe}" sh -c 'command -v wget' >/dev/null 2>&1; then
        docker exec "${probe}" wget -q -O /dev/null --no-check-certificate -T "${max_time}" "${url}"
        return $?
    fi

    log_error "Nem curl nem wget disponiveis no container de sonda '${probe}' — healthcheck http impossivel."
    return 2
}

# Aguarda o container ficar saudavel, com timeout/intervalo configuraveis.
# Nunca faz sleep as cegas alem do tempo restante. Uso: _rollout_health_wait
# <container> <alias> <porta> <scheme> <path> <timeout> <interval> <mode> <probe>
_rollout_health_wait() {
    local container="$1" alias="$2" port="$3" scheme="$4" path="$5"
    local timeout="$6" interval="$7" mode="$8" probe="$9"

    local resolved_mode="${mode}"
    if [[ "${resolved_mode}" == "auto" ]]; then
        local has_health
        has_health="$(docker inspect -f '{{if .State.Health}}yes{{end}}' "${container}" 2>/dev/null)" || true
        if [[ "${has_health}" == "yes" ]]; then
            resolved_mode="docker"
        else
            resolved_mode="http"
        fi
    fi

    local elapsed=0 attempt=1
    while true; do
        local remaining=$(( timeout - elapsed ))
        (( remaining < 0 )) && remaining=0

        case "${resolved_mode}" in
            docker)
                local status
                status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "${container}" 2>/dev/null)" || true
                [[ "${status}" == "healthy" ]] && return 0

                # Container morto/removido nao vai ficar saudavel esperando o
                # timeout inteiro — falha rapido com diagnostico claro em vez
                # de so acusar timeout genérico ao final.
                local container_state
                container_state="$(docker inspect -f '{{.State.Status}}' "${container}" 2>/dev/null)" || true
                case "${container_state}" in
                    exited|dead|removing|"")
                        log_error "Container ${container} esta em estado '${container_state:-inexistente}' — abortando healthcheck (modo docker) sem aguardar o timeout."
                        return 1
                        ;;
                esac
                ;;
            http)
                # max-time da sonda nunca ultrapassa o tempo restante ate o
                # timeout total (senao uma unica chamada de curl/wget poderia
                # estourar o timeout global) — minimo de 1s.
                local probe_max_time=$(( interval < remaining ? interval : remaining ))
                (( probe_max_time < 1 )) && probe_max_time=1
                local url="${scheme}://${alias}:${port}${path}"
                local probe_rc=0
                _rollout_probe_http "${probe}" "${url}" "${probe_max_time}" || probe_rc=$?
                if [[ ${probe_rc} -eq 0 ]]; then
                    return 0
                elif [[ ${probe_rc} -eq 2 ]]; then
                    # Sonda indisponivel (nem curl nem wget) — erro claro ja
                    # foi logado por _rollout_probe_http; abortar de imediato
                    # em vez de continuar tentando ate estourar o timeout.
                    return 1
                fi
                ;;
            *)
                log_error "Modo de healthcheck invalido: ${resolved_mode}"
                return 1
                ;;
        esac

        if (( elapsed >= timeout )); then
            break
        fi

        local wait_for=$(( interval < remaining ? interval : remaining ))
        if (( wait_for <= 0 )); then
            break
        fi

        msg_info "Healthcheck (tentativa ${attempt}, modo ${resolved_mode}): aguardando ${wait_for}s (decorrido ${elapsed}s/${timeout}s)..."
        sleep "${wait_for}"
        elapsed=$(( elapsed + wait_for ))
        attempt=$(( attempt + 1 ))
    done

    return 1
}

# Derruba o candidato apos falha de healthcheck ou de switch (tolerante a
# erro). Uso: _rollout_discard_candidate <servico> <blue|green>
_rollout_discard_candidate() {
    local service="$1" slot="$2"
    local container
    container="$(_rollout_slot_container "${service}" "${slot}")"
    # `|| true`: sob `set -e` de producao, um `docker stop`/`docker rm` que
    # falha (container ja parado/removido, ou nunca chegou a existir) mata o
    # shell ANTES do `return 0` — o `trap ... RETURN` que limpa o override do
    # compose nunca dispara, deixando docker-compose.rollout.yaml para tras.
    docker stop "${container}" >/dev/null 2>&1 || true
    docker rm "${container}" >/dev/null 2>&1 || true
    return 0
}

# Drena o slot anterior (aguarda ROLLOUT_DRAIN_SECONDS, salvo --keep-old).
# Uso: _rollout_drain <blue|green> <servico> <segundos> <keep_old:true|false>
_rollout_drain() {
    local slot="$1" service="$2" drain_seconds="$3" keep_old="$4"

    if [[ "${keep_old}" == "true" ]]; then
        msg_info "Mantendo o slot anterior (${slot}) no ar (--keep-old)."
        return 0
    fi

    msg_info "Drenando o slot anterior (${slot}) — aguardando ${drain_seconds}s..."
    sleep "${drain_seconds}"

    # Todas as falhas aqui sao toleradas por projeto (o estado do rollout ja
    # foi gravado ANTES do dreno — ver B6 em rollout_bluegreen — entao um
    # dreno mal-sucedido nunca deve deixar o rollout inteiro como falha, nem
    # matar o shell sob `set -e` antes do aviso abaixo).
    if [[ "${slot}" == "green" ]]; then
        local container
        container="$(_rollout_slot_container "${service}" "green")"
        docker stop "${container}" >/dev/null 2>&1 || true
        docker rm "${container}" >/dev/null 2>&1 || true
    else
        compose_exec stop "${service}" || {
            log_warn "Falha ao parar o slot anterior (${slot}/${service}) via compose — verifique manualmente."
            return 1
        }
    fi

    msg_success "Slot anterior (${slot}) drenado."
}

# --- Estado --------------------------------------------------------------------

_rollout_write_state() {
    local service="$1" live_slot="$2" live_target="$3" previous_target="$4" image="$5"
    local state_file="${ROLLOUT_STATE_FILE:-.cctl-rollout}"

    cat > "${state_file}" <<EOF
SERVICE="${service}"
LIVE_SLOT="${live_slot}"
LIVE_TARGET="${live_target}"
PREVIOUS_TARGET="${previous_target}"
IMAGE="${image}"
UPDATED_AT="$(date -Iseconds)"
EOF
}

# --- Preflight -------------------------------------------------------------

# Uso: _rollout_preflight <servico> <exigir-vhost:true|false>
_rollout_preflight() {
    local service="$1" require_vhost="${2:-true}"

    if [[ -n "${CCTL_CONTEXT:-}" && "${CCTL_CONTEXT}" != "instance" ]]; then
        log_error "rollout requer uma instancia instalada (.cctl-instance)."
        return 1
    fi

    if [[ -z "${service}" ]]; then
        log_error "Servico alvo do rollout nao definido. Use --service <svc> ou defina ROLLOUT_SERVICE no project.conf."
        return 1
    fi

    _nginx_proxy_require_container || return 1

    if [[ -z "${COMPOSE_PROJECT_NAME:-}" ]]; then
        log_error "COMPOSE_PROJECT_NAME nao definido."
        return 1
    fi

    if [[ "${require_vhost}" == "true" ]]; then
        local vhost="${NGINX_VHOSTS_DIR}/${COMPOSE_PROJECT_NAME}.conf"
        if [[ ! -f "${vhost}" ]]; then
            log_error "Vhost nao encontrado: ${vhost}. Execute 'cctl install' (com HOST_NGINX=true) primeiro."
            return 1
        fi
    fi

    return 0
}

# --- cctl rollout bluegreen --------------------------------------------------

rollout_bluegreen() {
    local start_ts
    start_ts="$(date +%s)"

    _rollout_parse_args bluegreen "$@" || return 1

    local service="${RO_SERVICE:-${ROLLOUT_SERVICE:-}}"
    _rollout_preflight "${service}" true || return 1

    local exists_rc=0
    compose_service_exists "${service}" || exists_rc=$?
    if [[ ${exists_rc} -eq 2 ]]; then
        return 1
    elif [[ ${exists_rc} -ne 0 ]]; then
        local available
        available="$(compose_list_services | tr '\n' ' ')"
        log_error "Servico '${service}' nao existe no compose deste projeto. Disponiveis: ${available}"
        return 1
    fi

    local vhost="${NGINX_VHOSTS_DIR}/${COMPOSE_PROJECT_NAME}.conf"

    local project_network
    project_network="$(docker network ls --filter "name=${COMPOSE_PROJECT_NAME}" --format "{{.Name}}" | head -1)" || true
    # "(A && B) || true": se B (network_connect_nginx) falhar, A&&B como um
    # todo falha — sob `set -e` de producao isso e um comando solto (nao
    # protegido por if/while), entao sem o "|| true" externo o shell morre
    # aqui numa falha tolerada (rede ja conectada, ou nao encontrada agora e
    # reconectada em outra tentativa).
    [[ -n "${project_network}" ]] && network_connect_nginx "${project_network}" || true

    local live_slot candidate_slot
    live_slot="$(_rollout_resolve_live_slot "${service}")"
    if [[ "${live_slot}" == "blue" ]]; then
        candidate_slot="green"
    else
        candidate_slot="blue"
    fi

    local live_alias candidate_alias candidate_container
    live_alias="$(_rollout_slot_alias "${service}" "${live_slot}")"
    candidate_alias="$(_rollout_slot_alias "${service}" "${candidate_slot}")"
    candidate_container="$(_rollout_slot_container "${service}" "${candidate_slot}")"

    local live_scheme live_port vhost_target
    vhost_target="$(_rollout_vhost_target "${vhost}" "${live_alias}")" || {
        log_error "Nao foi possivel determinar o alvo atual do vhost para o alias '${live_alias}'."
        return 1
    }
    read -r live_scheme live_port <<< "${vhost_target}"

    # Cleanup do override pelo global _ROLLOUT_OVERRIDE_TMP (nunca por um
    # `local`: o `trap ... RETURN` dispara no retorno desta funcao, quando os
    # `local` do corpo ja sairam de escopo — ver a declaracao do global).
    _ROLLOUT_OVERRIDE_TMP=""
    trap _rollout_cleanup_override RETURN

    if ! _rollout_bring_up_candidate "${service}" "${candidate_slot}" "${RO_IMAGE}" _ROLLOUT_OVERRIDE_TMP; then
        log_error "Falha ao subir o slot candidato (${candidate_slot})."
        return 1
    fi

    msg_step "ROLLOUT" "Slot candidato (${candidate_slot}) no ar: ${candidate_container}. Aguardando healthcheck..."

    local health_port="${RO_HEALTH_PORT:-${live_port}}"
    local probe_container="${ROLLOUT_PROBE_CONTAINER:-${NGINX_CONTAINER_NAME}}"

    if ! _rollout_health_wait "${candidate_container}" "${candidate_alias}" "${health_port}" "${live_scheme}" \
        "${RO_HEALTH_PATH}" "${RO_TIMEOUT}" "${RO_INTERVAL}" "${RO_HEALTH_MODE}" "${probe_container}"; then
        log_error "healthcheck falhou apos ${RO_TIMEOUT}s — rollback: trafego permanece no slot ${live_slot}."
        _rollout_discard_candidate "${service}" "${candidate_slot}"
        return 1
    fi

    msg_success "Healthcheck OK — trocando o trafego para o slot ${candidate_slot}"

    if ! _rollout_switch_vhost "${vhost}" "${live_alias}" "${candidate_alias}"; then
        log_error "Falha ao aplicar a nova configuracao nginx — trafego permanece no slot ${live_slot}."
        _rollout_discard_candidate "${service}" "${candidate_slot}"
        return 1
    fi

    # Estado gravado IMEDIATAMENTE apos o switch retornar 0 e ANTES do dreno
    # (B6): o trafego ja esta no candidato nesse ponto, entao o state file
    # precisa refletir isso ja — se o dreno falhar logo em seguida (sob
    # `set -e`, um `compose_exec stop` com rc!=0 mataria o shell sem essa
    # ordem), o container antigo continuaria existindo e, sem o estado
    # atualizado, o PROXIMO rollout tomaria o slot ANTIGO como live —
    # recriando/adotando o slot que na verdade esta em trafego (outage) e
    # tornando o proximo switch um no-op silencioso.
    #
    # A porta gravada no estado (e exibida por 'rollout status') e sempre a
    # porta do SERVICO (derivada do vhost) — '--health-port' e so a porta da
    # sonda de saude e pode divergir da porta real do vhost.
    local new_target="${candidate_alias}:${live_port}"
    local prev_target="${live_alias}:${live_port}"
    _rollout_write_state "${service}" "${candidate_slot}" "${new_target}" "${prev_target}" "${RO_IMAGE}"

    # Falha do dreno e aviso, nao motivo para reportar o rollout inteiro como
    # falho — o trafego ja trocou com sucesso e o estado ja reflete o slot
    # novo (gravado acima).
    _rollout_drain "${live_slot}" "${service}" "${RO_DRAIN}" "${RO_KEEP_OLD}" || \
        msg_warn "Dreno do slot anterior (${live_slot}) nao concluido — o estado ja reflete o slot novo (${candidate_slot}); verifique o container antigo manualmente."

    # Cleanup explicito no fim do caminho feliz: garante a remocao do override
    # mesmo se a semantica do `trap ... RETURN` mudar (o trap continua como
    # rede de seguranca para os caminhos de erro/saida antecipada).
    _rollout_cleanup_override

    local elapsed=$(( $(date +%s) - start_ts ))
    msg_header "Rollout Blue/Green concluido"
    echo -e "  Servico:               ${CYAN}${service}${RESET}"
    echo -e "  Slot novo (live):      ${CYAN}${candidate_slot}${RESET}"
    echo -e "  Imagem:                ${CYAN}${RO_IMAGE:-(sem alteracao)}${RESET}"
    if [[ "${RO_KEEP_OLD}" == "true" ]]; then
        echo -e "  Slot anterior:         ${CYAN}${live_slot} (mantido — --keep-old)${RESET}"
    else
        echo -e "  Slot anterior drenado: ${CYAN}${live_slot}${RESET}"
    fi
    echo -e "  Duracao:               ${CYAN}${elapsed}s${RESET}"
}

# --- cctl rollout rolling ------------------------------------------------------

rollout_rolling() {
    local start_ts
    start_ts="$(date +%s)"

    _rollout_parse_args rolling "$@" || return 1

    local service="${RO_SERVICE:-${ROLLOUT_SERVICE:-}}"
    _rollout_preflight "${service}" false || return 1

    local exists_rc=0
    compose_service_exists "${service}" || exists_rc=$?
    if [[ ${exists_rc} -eq 2 ]]; then
        return 1
    elif [[ ${exists_rc} -ne 0 ]]; then
        local available
        available="$(compose_list_services | tr '\n' ' ')"
        log_error "Servico '${service}' nao existe no compose deste projeto. Disponiveis: ${available}"
        return 1
    fi

    # 'rolling' so sabe operar o slot do compose (blue, alias "${service}"):
    # e o unico container que ele recria/inspeciona. Se o Blue/Green deixou o
    # trafego no slot green (alias "${service}-green"), recriar o slot blue
    # aqui seria um no-op silencioso em produção (nada em trafego muda), o
    # healthcheck sondaria um alias que nao importa, e gravar
    # LIVE_SLOT="blue" por cima do estado real mentiria sobre o slot em
    # trafego — o proximo 'bluegreen' iria falhar em
    # "Nao foi possivel determinar o alvo atual do vhost" porque o vhost so
    # tem "set $target ${service}-green:". Recusar cedo, sem tocar em nada
    # (nem no container, nem no state file), e pedir 'bluegreen' (que alterna
    # os slots de volta) e a saida mais segura: nunca gravamos um LIVE_SLOT
    # que nao corresponda ao container realmente em trafego.
    local live_slot
    live_slot="$(_rollout_resolve_live_slot "${service}")"
    if [[ "${live_slot}" != "blue" ]]; then
        log_error "Rollout 'rolling' opera apenas o slot do compose ('${service}', slot blue) — o slot live atual e '${live_slot}' (trafego no alias '${service}-green'). Rode 'cctl rollout bluegreen' para alternar o trafego de volta ao slot blue antes de usar 'rolling', ou, se so quer subir uma imagem nova, use 'cctl rollout bluegreen --image <ref>' diretamente (resolve em um unico passo)."
        return 1
    fi

    local container="${COMPOSE_PROJECT_NAME}-${service}"
    local prev_image
    prev_image="$(docker inspect -f '{{.Config.Image}}' "${container}" 2>/dev/null)" || true

    # Resolucao de alias/scheme/porta ANTES de recriar o servico (nao depende
    # do container novo — vem do vhost existente ou de --health-port) para
    # poder validar e falhar cedo, sem gastar um `up`+timeout inteiro numa
    # combinacao que ja sabemos que nao vai funcionar.
    local alias="${service}"
    local scheme="http"
    local port="${RO_HEALTH_PORT}"
    local vhost="${NGINX_VHOSTS_DIR}/${COMPOSE_PROJECT_NAME}.conf"
    if [[ -f "${vhost}" ]]; then
        local vt
        vt="$(_rollout_vhost_target "${vhost}" "${alias}")" || true
        if [[ -n "${vt}" ]]; then
            read -r scheme port <<< "${vt}"
        fi
    fi
    [[ -n "${RO_HEALTH_PORT}" ]] && port="${RO_HEALTH_PORT}"

    # Sem vhost e sem --health-port, o modo 'http' explicito monta uma URL
    # com porta vazia (ex. "http://svc:/"), falha por construcao, recria duas
    # vezes (incluindo o rollback) e acusa "ROLLBACK FALHOU" sem causa real.
    # 'auto'/'docker' seguem sem essa exigencia porque podem resolver via
    # `docker inspect` do healthcheck nativo, sem depender de porta alguma.
    if [[ "${RO_HEALTH_MODE}" == "http" && -z "${port}" ]]; then
        log_error "Modo de healthcheck 'http' requer uma porta: informe --health-port ou garanta que o vhost do servico '${service}' exista em ${vhost}."
        return 1
    fi

    # Mesmo cuidado do bluegreen: o cleanup do override usa o global
    # _ROLLOUT_OVERRIDE_TMP (nunca um `local`, que ja saiu de escopo quando o
    # `trap ... RETURN` dispara).
    _ROLLOUT_OVERRIDE_TMP=""
    trap _rollout_cleanup_override RETURN

    if ! _rollout_bring_up_candidate "${service}" "blue" "${RO_IMAGE}" _ROLLOUT_OVERRIDE_TMP; then
        log_error "Falha ao recriar o servico '${service}'."
        return 1
    fi

    local probe_container="${ROLLOUT_PROBE_CONTAINER:-${NGINX_CONTAINER_NAME}}"

    if ! _rollout_health_wait "${container}" "${alias}" "${port}" "${scheme}" \
        "${RO_HEALTH_PATH}" "${RO_TIMEOUT}" "${RO_INTERVAL}" "${RO_HEALTH_MODE}" "${probe_container}"; then

        if [[ -z "${prev_image}" ]]; then
            log_error "Healthcheck falhou apos ${RO_TIMEOUT}s e a imagem anterior nao pode ser determinada — rollback abortado."
            return 1
        fi

        log_error "Healthcheck falhou apos ${RO_TIMEOUT}s — recriando '${service}' com a imagem anterior (${prev_image})."

        local rb_override=""
        # Chamada nao protegida por `if`/`||` anteriormente: sob `set -e` de
        # producao, uma falha aqui (ex.: compose up do rollback tambem falha)
        # matava o shell antes de sequer tentar o _rollout_health_wait de
        # verificacao logo abaixo — o rollback silenciosamente nunca era
        # nem tentado nem reportado como tal.
        _rollout_bring_up_candidate "${service}" "blue" "${prev_image}" rb_override || \
            log_error "Falha ao recriar '${service}' com a imagem anterior (${prev_image}) durante o rollback."
        [[ -n "${rb_override}" ]] && rm -f "${rb_override}"

        if _rollout_health_wait "${container}" "${alias}" "${port}" "${scheme}" \
            "${RO_HEALTH_PATH}" "${RO_TIMEOUT}" "${RO_INTERVAL}" "${RO_HEALTH_MODE}" "${probe_container}"; then
            msg_warn "ROLLBACK EXECUTADO — servico '${service}' revertido para ${prev_image}"
        else
            log_error "ROLLBACK FALHOU — servico '${service}' pode estar indisponivel mesmo apos reverter para ${prev_image}"
        fi
        return 1
    fi

    # N5 (revisao Sprint 5, rodada 3): sem '--image', RO_IMAGE fica vazio — um
    # 'rolling' so de recriacao (sem trocar imagem) NAO pode apagar a imagem
    # ja registrada por um rollout anterior. Preserva o IMAGE existente do
    # state file (se houver) quando RO_IMAGE estiver vazio; PREVIOUS_TARGET
    # continua "" de proposito (nao um valor preservado): 'rolling' nunca
    # troca o alvo do vhost, o alias em trafego nao muda, entao nao existe um
    # "alvo anterior" distinto do atual para registrar — gravar um valor
    # antigo ali sugeriria uma troca de trafego que nao aconteceu.
    #
    # O state file e UNICO por diretorio de projeto (.cctl-rollout) e pode
    # conter o estado de OUTRO servico (projeto multi-servico, ex. dspace):
    # herdar o IMAGE sem conferir o SERVICE gravaria a imagem de A como se
    # fosse de B — e, como o proprio SERVICE seria reescrito, o guarda de
    # divergencia do 'rollout status' (N3) nao teria mais como detectar isso.
    # Por isso a preservacao so vale quando o estado registrado e DESTE
    # servico (achado da rodada 4 da auditoria).
    local image_to_persist="${RO_IMAGE}"
    local state_file="${ROLLOUT_STATE_FILE:-.cctl-rollout}"
    if [[ -z "${image_to_persist}" && -f "${state_file}" ]]; then
        local st_service_prev=""
        st_service_prev="$(_rollout_state_get "${state_file}" SERVICE)" || true
        if [[ "${st_service_prev}" == "${service}" ]]; then
            image_to_persist="$(_rollout_state_get "${state_file}" IMAGE)" || true
        fi
    fi
    _rollout_write_state "${service}" "blue" "${alias}:${port}" "" "${image_to_persist}"

    # Cleanup explicito no fim do caminho feliz (ver comentario no bluegreen).
    _rollout_cleanup_override

    local elapsed=$(( $(date +%s) - start_ts ))
    msg_header "Rollout Rolling concluido"
    echo -e "  Servico: ${CYAN}${service}${RESET}"
    echo -e "  Imagem:  ${CYAN}${RO_IMAGE:-${prev_image:-(sem alteracao)}}${RESET}"
    echo -e "  Duracao: ${CYAN}${elapsed}s${RESET}"
}

# --- cctl rollout status ------------------------------------------------------

# Uso: rollout_status [--service <svc>]
rollout_status() {
    msg_header "Status do rollout"

    local service_override=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --service)
                if [[ -z "${2:-}" ]]; then
                    log_error "Opcao '--service' requer um valor."
                    return 1
                fi
                service_override="$2"
                shift 2
                ;;
            *)
                log_error "Argumento invalido para 'rollout status': $1"
                return 1
                ;;
        esac
    done

    local service="${service_override:-${ROLLOUT_SERVICE:-}}"
    local state_file="${ROLLOUT_STATE_FILE:-.cctl-rollout}"
    local live_slot="" live_target="" image="" updated_at=""

    if [[ -f "${state_file}" ]]; then
        # `|| true` em cada leitura: um state file truncado/legado sem uma
        # das chaves faz _rollout_state_get retornar 1 — sob `set -e` de
        # producao isso mataria 'rollout status' antes de qualquer aviso
        # (exatamente o cenario que este comando existe para diagnosticar).
        live_slot="$(_rollout_state_get "${state_file}" LIVE_SLOT)" || true
        live_target="$(_rollout_state_get "${state_file}" LIVE_TARGET)" || true
        image="$(_rollout_state_get "${state_file}" IMAGE)" || true
        updated_at="$(_rollout_state_get "${state_file}" UPDATED_AT)" || true
        local st_service
        st_service="$(_rollout_state_get "${state_file}" SERVICE)" || true
        if [[ -z "${service}" ]]; then
            service="${st_service}"
        elif [[ -n "${st_service}" && "${st_service}" != "${service}" ]]; then
            # N3 (revisao Sprint 5, rodada 3): o state file gravado pertence a
            # OUTRO servico — exibir LIVE_SLOT/LIVE_TARGET/IMAGE/UPDATED_AT
            # dele como se fossem do servico pedido induz o operador a erro
            # (ex.: "Imagem" mostrada nao e a imagem do servico consultado).
            # Descarta os campos derivados daquele estado; o que segue usa
            # apenas o que e verificavel ao vivo para o servico pedido
            # (docker inspect + a mesma regra de resolucao de slot do N1).
            msg_warn "Estado registrado em ${state_file} pertence ao servico '${st_service}', nao a '${service}' — ignorando slot/alvo/imagem daquele estado."
            live_slot="" live_target="" image="" updated_at=""
        fi
    else
        msg_warn "Arquivo de estado (${state_file}) nao encontrado — nenhum rollout registrado ainda."
    fi

    if [[ -z "${service}" ]]; then
        msg_warn "Servico alvo desconhecido (defina ROLLOUT_SERVICE no project.conf ou use --service)."
        return 0
    fi

    if [[ -z "${live_slot}" ]]; then
        live_slot="$(_rollout_resolve_live_slot "${service}")"
    fi

    local container status="" health=""
    container="$(_rollout_slot_container "${service}" "${live_slot}")"
    if docker inspect "${container}" >/dev/null 2>&1; then
        status="$(docker inspect -f '{{.State.Status}}' "${container}" 2>/dev/null)" || true
        health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "${container}" 2>/dev/null)" || true
    else
        msg_warn "Container ${container} nao encontrado."
    fi

    echo -e "  Servico:        ${CYAN}${service}${RESET}"
    echo -e "  Slot live:      ${CYAN}${live_slot}${RESET}"
    echo -e "  Container:      ${CYAN}${container}${RESET}"
    echo -e "  Status:         ${CYAN}${status:-n/a}${RESET}"
    echo -e "  Saude:          ${CYAN}${health:-n/a}${RESET}"
    echo -e "  Alvo do vhost:  ${CYAN}${live_target:-n/a}${RESET}"
    echo -e "  Imagem:         ${CYAN}${image:-n/a}${RESET}"
    echo -e "  Ultimo rollout: ${CYAN}${updated_at:-n/a}${RESET}"
}
