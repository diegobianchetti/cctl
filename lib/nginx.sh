#!/bin/bash
# lib/nginx.sh — Gerenciamento de configuracao Nginx no host (nginx-proxy)

# Container nginx-proxy e diretorio de vhosts no host
NGINX_CONTAINER_NAME="${NGINX_CONTAINER_NAME:-nginx-proxy}"
NGINX_VHOSTS_DIR="${NGINX_VHOSTS_DIR:-/etc/nginx-proxy/vhosts.d}"

# Executa cp/rm com sudo somente quando necessario. Uso: _nginx_priv <cmd> [args...]
#
# Wrapper fino sobre core_priv_run (lib/core.sh) — mantido pelo nome para nao
# quebrar chamadas/testes existentes. Ver core_priv_run para o contrato de
# argumentos e o criterio de gravabilidade/legibilidade por operacao.
_nginx_priv() {
    core_priv_run "$@"
}

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

    if ! _nginx_priv cp "${nginx_conf_src}" "${vhost_dst}"; then
        log_error "Falha ao copiar configuracao nginx para ${vhost_dst}"
        return 1
    fi

    if nginx_test_and_reload; then
        log_success "Site ${domain} habilitado no nginx-proxy"
        return 0
    else
        log_error "Config nginx invalida! Revertendo..."
        _nginx_priv rm -f "${vhost_dst}"
        return 1
    fi
}

# Remove config do site do nginx-proxy
nginx_disable_site() {
    local domain="${1:-${DOMAIN_NAME}}"
    local vhost_dst="${NGINX_VHOSTS_DIR}/${COMPOSE_PROJECT_NAME}.conf"
    local backup_dir
    backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/cctl_nginx_backup.XXXXXX")" || {
        log_error "Falha ao criar diretorio de backup temporario"
        return 1
    }

    if [[ -f "${vhost_dst}" ]]; then
        core_priv_run cp -p "${vhost_dst}" "${backup_dir}/" || {
            log_error "Falha ao criar backup do vhost ${vhost_dst}"
            rm -rf "${backup_dir}"
            return 1
        }
    fi

    msg_info "Removendo configuracao nginx para ${domain}..."
    echo -e "  ${CYAN}${vhost_dst}${RESET}"
    _nginx_priv rm -f "${vhost_dst}"

    if nginx_test_and_reload; then
        rm -rf "${backup_dir}"
        log_success "Site ${domain} removido do nginx-proxy"
        return 0
    else
        log_error "Config nginx invalida apos remocao! Restaurando..."
        if [[ -f "${backup_dir}/${COMPOSE_PROJECT_NAME}.conf" ]]; then
            core_priv_run cp -p "${backup_dir}/${COMPOSE_PROJECT_NAME}.conf" "${vhost_dst}" || \
                log_error "Falha ao restaurar vhost de backup para ${vhost_dst}"
        fi
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
