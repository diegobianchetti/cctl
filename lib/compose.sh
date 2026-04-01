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
    compose_exec build "${build_args[@]}"
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
