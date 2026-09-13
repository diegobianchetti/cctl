#!/bin/bash
# lib/compose.sh — Wrappers docker compose (monta -f do manifest)

# Monta os argumentos -f para docker compose a partir do COMPOSE_FILES do manifest
_compose_file_args() {
    local args=()
    if [[ -n "${COMPOSE_FILES+x}" ]]; then
        local f
        for f in "${COMPOSE_FILES[@]}"; do
            args+=("-f" "${f}")
        done
    else
        # Fallback: docker-compose.yml padrao
        args+=("-f" "docker-compose.yml")
    fi
    echo "${args[@]}"
}

# Executa docker compose com os arquivos e projeto corretos
compose_exec() {
    local file_args
    file_args=$(_compose_file_args)

    log_debug "docker compose ${file_args} -p ${COMPOSE_PROJECT_NAME} $*"

    # shellcheck disable=SC2086
    docker compose ${file_args} -p "${COMPOSE_PROJECT_NAME}" "$@"
}

# Executa compose_exec com um -f de override adicional quando informado
# (usado pelo rollout Blue/Green para o docker-compose.rollout.yaml gerado em
# runtime). Com override vazio, comporta-se como compose_exec puro. Uso:
# compose_exec_override <override-ou-vazio> <args...>
compose_exec_override() {
    local override="$1"
    shift
    if [[ -n "${override}" ]]; then
        compose_exec -f "${override}" "$@"
    else
        compose_exec "$@"
    fi
}

# Pull de imagens
compose_pull() {
    msg_step "PULL" "Baixando imagens..."
    compose_exec pull
    log_success "Imagens baixadas"
}

# Build de imagens locais
compose_build() {
    local build_args=("$@")
    msg_step "BUILD" "Construindo imagens..."
    compose_exec build "${build_args[@]}" || { log_error "Falha no build"; return 1; }
    log_success "Build concluido"
}

# Verifica se um servico existe no compose do projeto atual.
# Uso: compose_service_exists <servico>  (retorna 0=existe / 1=nao existe /
# 2=falha ao consultar o compose — erro real, distinto de "nao existe")
compose_service_exists() {
    local service="$1"
    local services
    if ! services=$(compose_exec config --services 2>&1); then
        log_error "Falha ao consultar servicos do compose: ${services}"
        return 2
    fi

    local s
    while IFS= read -r s; do
        [[ "${s}" == "${service}" ]] && return 0
    done <<< "${services}"

    return 1
}

# Lista os servicos definidos no compose do projeto atual (um por linha).
compose_list_services() {
    compose_exec config --services 2>/dev/null
}

# Lista APENAS os servicos que tem contexto de build (chave `build:`) no
# compose resolvido — os unicos que `docker compose build` sem argumentos
# realmente constroi, e os unicos seguros para retag/push automatico (um
# servico so com `image:`, ex. postgres:16, nao e nosso para republicar).
#
# Heuristica (bash puro, sem jq/yq): usa `docker compose config` (YAML
# resolvido, sem --format json — mais portavel entre versoes do plugin) e
# faz parsing por indentacao: dentro do bloco top-level "services:", cada
# chave em 2 espacos e um nome de servico; se algum descendente direto tiver
# uma chave "build:" em 4 espacos, o servico entra na lista.
# Limitacao conhecida: assume a indentacao padrao de 2 espacos por nivel
# emitida pelo `docker compose config` atual. Um compose com ancoras YAML
# incomuns ou uma versao do plugin que mude o indentation style pode nao ser
# reconhecido corretamente — nesse caso, passar os servicos explicitamente
# na linha de comando contorna a heuristica.
compose_buildable_services() {
    local config
    if ! config=$(compose_exec config 2>&1); then
        log_error "Falha ao consultar configuracao do compose: ${config}"
        return 1
    fi

    echo "${config}" | awk '
        /^services:[[:space:]]*$/ { in_services = 1; next }
        in_services && /^[A-Za-z0-9_-]+:[[:space:]]*$/ { in_services = 0 }
        in_services && /^  [A-Za-z0-9._-]+:[[:space:]]*$/ {
            if (svc != "" && has_build) print svc
            svc = $1
            sub(/:$/, "", svc)
            has_build = 0
            next
        }
        in_services && /^    build:/ { has_build = 1 }
        END { if (svc != "" && has_build) print svc }
    '
}

# Resolve a imagem efetiva de um servico (a definida/resultante no compose
# resolvido) — usada para retaguear apos build com --tag.
compose_service_image() {
    local service="$1"
    compose_exec config --images "${service}" 2>/dev/null | head -n1
}

# Build de servico(s) especificos.
# Uso: compose_build_service <nome-do-array-bash-de-servicos> [flags...]
# Recebe o NOME da variavel array (nameref) em vez de colapsar os servicos
# numa string — evita o problema classico de `read -ra` desfazer o quoting
# de nomes com espacos/caracteres especiais.
compose_build_service() {
    local -n _cbs_services="$1"
    shift
    local flags=("$@")

    msg_step "BUILD" "Construindo servico(s): ${_cbs_services[*]}"
    compose_exec build "${flags[@]}" "${_cbs_services[@]}" || {
        log_error "Falha no build dos servicos: ${_cbs_services[*]}"
        return 1
    }
    log_success "Build concluido"
}

# Up (cria e inicia containers)
compose_up() {
    msg_step "UP" "Iniciando containers..."
    compose_exec up -d "$@"
    log_success "Containers iniciados"
}

# Down (remove containers e rede)
compose_down() {
    msg_step "DOWN" "Removendo containers..."
    compose_exec down "$@"
    log_success "Containers removidos"
}

# Start (inicia containers parados)
compose_start() {
    local service="${1:-}"
    if [[ -n "${service}" ]]; then
        compose_exec start "${service}"
    else
        compose_exec start
    fi
}

# Stop (para containers)
compose_stop() {
    local service="${1:-}"
    if [[ -n "${service}" ]]; then
        compose_exec stop "${service}"
    else
        compose_exec stop
    fi
}

# Restart
compose_restart() {
    local service="${1:-}"
    if [[ -n "${service}" ]]; then
        compose_exec restart "${service}"
    else
        compose_exec restart
    fi
}

# PS (lista containers)
compose_ps() {
    compose_exec ps "$@"
}

# Logs
compose_logs() {
    compose_exec logs "$@"
}

# Exec (executa comando dentro de um container)
compose_connect() {
    local service="$1"
    shift

    # Valida que o servico e conectavel
    if [[ -n "${CONNECTABLE_SERVICES+x}" ]]; then
        local valid=false
        local s
        for s in "${CONNECTABLE_SERVICES[@]}"; do
            if [[ "${s}" == "${service}" ]]; then
                valid=true
                break
            fi
        done
        if [[ "${valid}" != "true" ]]; then
            log_error "Servico '${service}' nao disponivel para conexao."
            msg_info "Servicos disponiveis: ${CONNECTABLE_SERVICES[*]}"
            return 1
        fi
    fi

    local shell="${1:-bash}"
    compose_exec exec -it "${service}" "${shell}"
}

# Config (exibe configuracao resolvida)
compose_config() {
    compose_exec config "$@"
}
