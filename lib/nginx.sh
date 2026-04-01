#!/bin/bash
# lib/nginx.sh — Gerenciamento de configuracao Nginx no host

# Paths padrao do nginx (container nginx em /var/docker/nginx)
NGINX_BASE_DIR="/var/docker/nginx"
NGINX_SITES_AVAILABLE="${NGINX_BASE_DIR}/config/sites-available"
NGINX_SITES_ENABLED="${NGINX_BASE_DIR}/config/sites-enabled"
NGINX_COMPOSE_FILE="${NGINX_BASE_DIR}/docker-compose.yml"

# Instala config do site no nginx
nginx_enable_site() {
    local domain="${1:-${DOMAIN_NAME}}"
    local nginx_conf_src="${2:-./nginx/site.conf}"

    if [[ ! -f "${nginx_conf_src}" ]]; then
        log_warn "Config nginx nao encontrada: ${nginx_conf_src}"
        return 1
    fi

    local site_available="${NGINX_SITES_AVAILABLE}/${domain}.conf"
    local site_enabled="${NGINX_SITES_ENABLED}/${domain}.conf"

    # Copia config para sites-available
    sudo cp "${nginx_conf_src}" "${site_available}"

    # Cria symlink em sites-enabled
    sudo ln -sf "${site_available}" "${site_enabled}"

    # Testa e recarrega
    if nginx_test_and_reload; then
        log_success "Site ${domain} habilitado no Nginx"
        return 0
    else
        # Reverte em caso de erro
        log_error "Config nginx invalida! Revertendo..."
        sudo rm -f "${site_enabled}"
        return 1
    fi
}

# Remove config do site do nginx
nginx_disable_site() {
    local domain="${1:-${DOMAIN_NAME}}"
    local backup_dir="/tmp/nginx_backup_${COMPOSE_PROJECT_NAME}"

    local site_available="${NGINX_SITES_AVAILABLE}/${domain}.conf"
    local site_enabled="${NGINX_SITES_ENABLED}/${domain}.conf"

    # Backup
    mkdir -p "${backup_dir}"
    [[ -f "${site_available}" ]] && cp -p "${site_available}" "${backup_dir}/"

    # Remove
    msg_info "Removendo configuracao nginx para ${domain}..."
    echo -e "  ${CYAN}${site_enabled}${RESET}"
    sudo rm -f "${site_enabled}"
    echo -e "  ${CYAN}${site_available}${RESET}"
    sudo rm -f "${site_available}"

    # Testa e recarrega
    if nginx_test_and_reload; then
        rm -rf "${backup_dir}"
        log_success "Site ${domain} removido do Nginx"
        return 0
    else
        # Restaura backup
        log_error "Config nginx invalida apos remocao! Restaurando..."
        [[ -f "${backup_dir}/${domain}.conf" ]] && sudo cp -p "${backup_dir}/${domain}.conf" "${site_available}"
        [[ -f "${site_available}" ]] && sudo ln -sf "${site_available}" "${site_enabled}"
        nginx_test_and_reload
        rm -rf "${backup_dir}"
        return 1
    fi
}

# Testa config nginx e recarrega se valida
nginx_test_and_reload() {
    msg_info "Testando configuracao nginx..."

    if docker compose -p nginx exec nginx nginx -t 2>/dev/null; then
        msg_success "Configuracao valida"
        docker compose -p nginx exec nginx nginx -s reload 2>/dev/null
        return 0
    else
        msg_error "Configuracao nginx invalida!"
        return 1
    fi
}

# Remove referencia da rede do projeto no docker-compose.yml do nginx
nginx_remove_network_config() {
    local project_network="$1"

    if [[ ! -f "${NGINX_COMPOSE_FILE}" ]]; then
        log_warn "docker-compose.yml do nginx nao encontrado"
        return 0
    fi

    if ! command -v yq &>/dev/null; then
        log_warn "yq nao disponivel. Remova manualmente a rede ${project_network} de ${NGINX_COMPOSE_FILE}"
        return 0
    fi

    # Backup
    cp "${NGINX_COMPOSE_FILE}" "${NGINX_COMPOSE_FILE}.bak"

    # Remove referencias da rede
    yq eval "del(.networks.\"${project_network}\")" -i "${NGINX_COMPOSE_FILE}"
    yq eval "del(.services.nginx.networks[] | select(. == \"${project_network}\"))" -i "${NGINX_COMPOSE_FILE}"

    # Valida
    if docker compose -f "${NGINX_COMPOSE_FILE}" config &>/dev/null; then
        rm -f "${NGINX_COMPOSE_FILE}.bak"
        log_success "Rede ${project_network} removida do nginx compose"
    else
        log_error "Configuracao invalida apos remocao! Restaurando backup..."
        mv "${NGINX_COMPOSE_FILE}.bak" "${NGINX_COMPOSE_FILE}"
        return 1
    fi
}
