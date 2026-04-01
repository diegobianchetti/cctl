#!/bin/bash
# lib/validate.sh — Pre-flight checks

# Verifica se o Docker esta instalado e rodando
validate_docker() {
    if ! command -v docker &>/dev/null; then
        log_error "Docker nao encontrado. Instale o Docker antes de continuar."
        return 1
    fi

    if ! docker info &>/dev/null; then
        log_error "Docker nao esta rodando ou o usuario nao tem permissao."
        return 1
    fi

    # Verifica Docker Compose (plugin)
    if ! docker compose version &>/dev/null; then
        log_error "Docker Compose plugin nao encontrado."
        return 1
    fi

    log_debug "Docker OK: $(docker --version)"
    return 0
}

# Verifica espaco em disco disponivel (minimo em MB)
validate_disk_space() {
    local min_mb="${1:-1024}"
    local dir="${2:-.}"
    local available_mb

    available_mb=$(df -BM "${dir}" | awk 'NR==2 {gsub(/M/,""); print $4}')

    if [[ "${available_mb}" -lt "${min_mb}" ]]; then
        log_error "Espaco em disco insuficiente: ${available_mb}MB disponiveis, minimo ${min_mb}MB"
        return 1
    fi

    log_debug "Disco OK: ${available_mb}MB disponiveis"
    return 0
}

# Verifica se uma porta esta livre no host
validate_port_available() {
    local port="$1"

    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        log_error "Porta ${port} ja esta em uso."
        return 1
    fi

    return 0
}

# Verifica se o DNS do dominio resolve
validate_dns() {
    local domain="$1"

    # Pula validacao para dominios locais
    case "${domain}" in
        localhost|*.local|*.test) return 0 ;;
    esac

    if ! host "${domain}" &>/dev/null; then
        log_warn "DNS do dominio '${domain}' nao resolve. Verifique a configuracao."
        return 1
    fi

    log_debug "DNS OK: ${domain}"
    return 0
}

# Verifica se o Git esta disponivel
validate_git() {
    if ! command -v git &>/dev/null; then
        log_error "Git nao encontrado. Instale o Git antes de continuar."
        return 1
    fi
    return 0
}

# Executa todos os pre-flight checks para install
validate_preflight_install() {
    local errors=0

    msg_header "Verificacoes pre-instalacao"

    if validate_docker; then
        msg_success "Docker"
    else
        ((errors++))
    fi

    if validate_disk_space 1024; then
        msg_success "Espaco em disco"
    else
        ((errors++))
    fi

    if [[ -n "${DOMAIN_NAME:-}" ]]; then
        if validate_dns "${DOMAIN_NAME}"; then
            msg_success "DNS (${DOMAIN_NAME})"
        else
            ((errors++))
        fi
    fi

    if [[ ${errors} -gt 0 ]]; then
        log_error "${errors} verificacao(oes) falharam."
        return 1
    fi

    msg_success "Todas as verificacoes passaram."
    return 0
}
