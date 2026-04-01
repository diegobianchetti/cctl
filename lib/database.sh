#!/bin/bash
# lib/database.sh — Check/update config customizada do banco de dados (PostgreSQL)
#
# Usa variaveis do manifest:
#   DB_SERVICE         — nome do servico de banco no compose
#   DB_TYPE            — tipo do banco (postgresql)
#   DB_CUSTOM_CONFIG   — path da config customizada (relativo a instancia)
#   DB_CONFIG_PATH     — path dentro do container

# Verifica config customizada vs config atual do banco
database_check_config() {
    _database_validate_manifest || return 1

    local custom_config="${DB_CUSTOM_CONFIG}"

    if [[ ! -f "${custom_config}" ]]; then
        log_error "Config customizada nao encontrada: ${custom_config}"
        return 1
    fi

    msg_header "Verificacao de configuracao do banco (${DB_SERVICE})"
    echo ""

    # Le parametros do arquivo customizado
    local param value current applied
    printf "  ${BOLD}%-35s %-20s %-20s %-10s${RESET}\n" "PARAMETRO" "CUSTOM" "ATUAL" "STATUS"
    printf "  %-35s %-20s %-20s %-10s\n" \
        "-----------------------------------" "--------------------" "--------------------" "----------"

    while IFS= read -r line; do
        # Ignora comentarios e linhas vazias
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue

        # Extrai parametro e valor (formato: param = valor)
        if [[ "${line}" =~ ^[[:space:]]*([a-zA-Z_][a-zA-Z0-9_]*)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            param="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"

            # Consulta o valor atual no banco
            current=$(_database_get_current_value "${param}")

            # Compara
            if [[ "${current}" == "${value}" ]]; then
                applied="${GREEN}aplicado${RESET}"
            else
                applied="${YELLOW}divergente${RESET}"
            fi

            printf "  %-35s %-20s %-20s ${applied}\n" "${param}" "${value}" "${current:-N/A}"
        fi
    done < "${custom_config}"

    echo ""
}

# Aplica config customizada no banco (copia + reload)
database_update_config() {
    _database_validate_manifest || return 1

    local custom_config="${DB_CUSTOM_CONFIG}"
    local container_path="${DB_CONFIG_PATH}"

    if [[ ! -f "${custom_config}" ]]; then
        log_error "Config customizada nao encontrada: ${custom_config}"
        return 1
    fi

    msg_step "DB-CONFIG" "Aplicando configuracao customizada no ${DB_SERVICE}..."

    # Copia config para dentro do container
    local container_name="${COMPOSE_PROJECT_NAME}-${DB_SERVICE}-1"

    # Garante que o diretorio destino existe
    docker exec "${container_name}" mkdir -p "$(dirname "${container_path}")" 2>/dev/null

    # Copia o arquivo
    docker cp "${custom_config}" "${container_name}:${container_path}"

    if [[ $? -ne 0 ]]; then
        log_error "Falha ao copiar config para o container"
        return 1
    fi

    log_success "Config copiada para ${container_name}:${container_path}"

    # Reload do PostgreSQL (sem restart)
    case "${DB_TYPE}" in
        postgresql)
            msg_step "RELOAD" "Recarregando PostgreSQL..."
            docker exec "${container_name}" su - postgres -c "pg_ctl reload" 2>/dev/null \
                || docker exec "${container_name}" psql -U postgres -c "SELECT pg_reload_conf();" 2>/dev/null

            if [[ $? -eq 0 ]]; then
                log_success "PostgreSQL recarregado"
            else
                log_warn "Falha no reload. Pode ser necessario reiniciar o container."
            fi
            ;;
        *)
            log_warn "Reload automatico nao suportado para DB_TYPE=${DB_TYPE}. Reinicie o container manualmente."
            ;;
    esac

    echo ""
    msg_info "Verificando aplicacao..."
    database_check_config
}

# Valida que as variaveis de banco estao definidas no manifest
_database_validate_manifest() {
    if [[ -z "${DB_SERVICE:-}" ]]; then
        log_error "DB_SERVICE nao definido no manifest (project.conf)"
        return 1
    fi
    if [[ -z "${DB_CUSTOM_CONFIG:-}" ]]; then
        log_error "DB_CUSTOM_CONFIG nao definido no manifest (project.conf)"
        return 1
    fi
    if [[ -z "${DB_CONFIG_PATH:-}" ]]; then
        log_error "DB_CONFIG_PATH nao definido no manifest (project.conf)"
        return 1
    fi
    return 0
}

# Consulta o valor atual de um parametro no PostgreSQL
_database_get_current_value() {
    local param="$1"
    local container_name="${COMPOSE_PROJECT_NAME}-${DB_SERVICE}-1"

    docker exec "${container_name}" \
        psql -U postgres -t -A -c "SHOW ${param};" 2>/dev/null \
        | tr -d '[:space:]'
}
