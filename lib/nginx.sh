#!/bin/bash
# lib/nginx.sh — Gerenciamento de configuracao Nginx no host (nginx-proxy)

# Container nginx-proxy e diretorio de vhosts no host
NGINX_CONTAINER_NAME="${NGINX_CONTAINER_NAME:-nginx-proxy}"
NGINX_VHOSTS_DIR="${NGINX_VHOSTS_DIR:-/etc/nginx-proxy/vhosts.d}"

# Instala config do site no nginx-proxy
nginx_enable_site() {
    local domain="${1:-${DOMAIN_NAME}}"
    local nginx_conf_src="${2:-./nginx/site.conf}"

    if [[ ! -f "${nginx_conf_src}" ]]; then
        log_warn "Config nginx nao encontrada: ${nginx_conf_src}"
        return 1
    fi

    if [[ ! -d "${NGINX_VHOSTS_DIR}" ]]; then
        log_error "Diretorio ${NGINX_VHOSTS_DIR} nao existe. nginx-proxy esta instalado?"
        return 1
    fi

    local vhost_dst="${NGINX_VHOSTS_DIR}/${COMPOSE_PROJECT_NAME}.conf"

    sudo cp "${nginx_conf_src}" "${vhost_dst}"

    if nginx_test_and_reload; then
        log_success "Site ${domain} habilitado no nginx-proxy"
        return 0
    else
        log_error "Config nginx invalida! Revertendo..."
        sudo rm -f "${vhost_dst}"
        return 1
    fi
}

# Remove config do site do nginx-proxy
nginx_disable_site() {
    local domain="${1:-${DOMAIN_NAME}}"
    local vhost_dst="${NGINX_VHOSTS_DIR}/${COMPOSE_PROJECT_NAME}.conf"
    local backup_dir="/tmp/nginx_backup_${COMPOSE_PROJECT_NAME}"

    mkdir -p "${backup_dir}"
    [[ -f "${vhost_dst}" ]] && cp -p "${vhost_dst}" "${backup_dir}/"

    msg_info "Removendo configuracao nginx para ${domain}..."
    echo -e "  ${CYAN}${vhost_dst}${RESET}"
    sudo rm -f "${vhost_dst}"

    if nginx_test_and_reload; then
        rm -rf "${backup_dir}"
        log_success "Site ${domain} removido do nginx-proxy"
        return 0
    else
        log_error "Config nginx invalida apos remocao! Restaurando..."
        [[ -f "${backup_dir}/${COMPOSE_PROJECT_NAME}.conf" ]] && \
            sudo cp -p "${backup_dir}/${COMPOSE_PROJECT_NAME}.conf" "${vhost_dst}"
        nginx_test_and_reload
        rm -rf "${backup_dir}"
        return 1
    fi
}

# Testa config nginx e recarrega se valida
nginx_test_and_reload() {
    msg_info "Testando configuracao nginx..."

    if docker exec "${NGINX_CONTAINER_NAME}" nginx -t 2>/dev/null; then
        msg_success "Configuracao valida"
        docker exec "${NGINX_CONTAINER_NAME}" nginx -s reload 2>/dev/null
        return 0
    else
        msg_error "Configuracao nginx invalida!"
        return 1
    fi
}

# Noop: nginx-proxy usa redes runtime (docker network connect/disconnect),
# nao precisa de alteracao no compose file
nginx_remove_network_config() {
    local project_network="$1"
    log_debug "nginx-proxy usa redes runtime — nenhuma alteracao no compose necessaria para ${project_network}"
    return 0
}
