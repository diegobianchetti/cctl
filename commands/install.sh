#!/bin/bash
# commands/install.sh — Instala a instancia no servidor
#
# Pré-requisito: estar no diretorio da branch de cliente (com project.conf, sem .cctl-instance)
#
# Fluxo:
#   1. Valida contexto (project.conf existe, .cctl-instance NAO existe)
#   2. Source project.conf + .env
#   3. Gera senhas (AUTO_PASSWORD_VARS)
#   4. Aloca subnet livre
#   5. Renderiza templates
#   6. Pre-flight checks
#   7. Pull/build imagens
#   8. Up containers
#   9. Nginx + SSL (se HOST_NGINX/HOST_SSL)
#  10. Cron (se HOST_CRON)
#  11. Hook post-install
#  12. Grava .cctl-instance

cmd_install() {
    msg_header "Instalacao da instancia"

    # 1. Valida contexto
    if [[ ! -f "./project.conf" ]]; then
        log_error "Arquivo project.conf nao encontrado. Este nao e um diretorio de instancia."
        return 1
    fi

    if [[ -f "./.cctl-instance" ]]; then
        log_error "Instancia ja instalada (.cctl-instance encontrado)."
        msg_info "Use os comandos operacionais (up/down/restart) para gerenciar."
        return 1
    fi

    # 2. Manifest e .env ja foram carregados pelo entry point (cctl)
    echo -e "  Projeto: ${CYAN}${PROJECT_TYPE:-?}${RESET}"
    echo -e "  Cliente: ${CYAN}${CLIENT_NAME:-?}${RESET}"
    echo -e "  Dominio: ${CYAN}${DOMAIN_NAME:-?}${RESET}"
    echo ""

    # 3. Gera senhas
    passwords_generate_all

    # 4. Aloca subnet
    _install_allocate_subnet || return 1

    # 5. Renderiza templates
    msg_step "TEMPLATES" "Renderizando templates..."
    env_render_all_templates
    log_success "Templates renderizados"

    # 6. Recarrega .env apos geracoes de senhas e subnet
    env_load

    # 7. Pre-flight checks
    validate_preflight_install || return 1

    # 8. Pull imagens
    compose_pull

    # 9. Build (se necessario)
    _install_build_if_needed

    # 10. Up
    compose_up

    # 11. Nginx + SSL
    _install_nginx
    _install_ssl

    # 12. Cron
    _install_cron

    # 13. Hook post-install
    _install_post_hook

    # 14. Grava .cctl-instance
    _install_write_instance_file

    # Resumo
    echo ""
    msg_header "Instalacao concluida!"
    echo ""
    echo -e "  Projeto:  ${CYAN}${PROJECT_TYPE}${RESET}"
    echo -e "  Cliente:  ${CYAN}${CLIENT_NAME}${RESET}"
    echo -e "  Dominio:  ${CYAN}${DOMAIN_NAME}${RESET}"
    echo -e "  Subnet:   ${CYAN}${COMPOSE_PROJECT_SUBNET:-N/A}${RESET}"
    echo ""
    echo -e "  Comandos uteis:"
    echo -e "    cctl ps          — listar containers"
    echo -e "    cctl logs        — ver logs"
    echo -e "    cctl status      — resumo de saude"
    echo ""

    log_success "Instancia ${COMPOSE_PROJECT_NAME} instalada com sucesso!"
}

# Aloca subnet e seta no .env
_install_allocate_subnet() {
    msg_step "SUBNET" "Alocando subnet..."

    local subnet
    subnet=$(network_allocate_subnet) || return 1

    env_set_var "COMPOSE_PROJECT_SUBNET" "${subnet}"
    log_success "Subnet alocada: ${subnet}"
}

# Build de imagens locais se houver Dockerfiles no diretorio
_install_build_if_needed() {
    # Verifica se algum servico no compose precisa de build
    if compose_exec config --format json 2>/dev/null | grep -q '"build"'; then
        compose_build
    else
        log_debug "Nenhuma imagem local para build"
    fi
}

# Configura nginx no host (se HOST_NGINX=true)
_install_nginx() {
    if [[ "${HOST_NGINX:-false}" != "true" ]]; then
        log_debug "HOST_NGINX desabilitado, pulando nginx"
        return 0
    fi

    msg_step "NGINX" "Configurando Nginx..."
    nginx_enable_site || return 1

    # Conecta nginx-proxy a rede do projeto para acessar o container da aplicacao
    local project_network
    project_network=$(docker network ls --filter "name=${COMPOSE_PROJECT_NAME}" --format "{{.Name}}" | head -1)
    if [[ -n "${project_network}" ]]; then
        network_connect_nginx "${project_network}"
    fi
}

# Solicita/instala certificado SSL (se HOST_SSL=true)
# Delega para ssl_issue() que trata SSL_MODE (letsencrypt|manual)
_install_ssl() {
    if [[ "${HOST_SSL:-false}" != "true" ]]; then
        log_debug "HOST_SSL desabilitado, pulando SSL"
        return 0
    fi

    ssl_issue "${DOMAIN_NAME}" || log_warn "Falha no SSL. Verifique manualmente."
}

# Instala cron entries no host (se HOST_CRON=true)
_install_cron() {
    if [[ "${HOST_CRON:-false}" != "true" ]]; then
        log_debug "HOST_CRON desabilitado, pulando cron"
        return 0
    fi

    msg_step "CRON" "Instalando cron jobs..."

    # Procura arquivos .cron no diretorio cron/
    local cron_dir="./cron"
    if [[ ! -d "${cron_dir}" ]]; then
        log_debug "Diretorio cron/ nao encontrado, pulando"
        return 0
    fi

    local cron_file
    for cron_file in "${cron_dir}"/*.cron; do
        [[ -f "${cron_file}" ]] || continue
        local cron_name
        cron_name=$(basename "${cron_file}" .cron)
        local dest="/etc/cron.d/${cron_name}-${COMPOSE_PROJECT_NAME}"
        sudo cp "${cron_file}" "${dest}"
        sudo chmod 644 "${dest}"
        log_success "Cron instalado: ${dest}"
    done
}

# Executa hook post-install (se definido no manifest)
_install_post_hook() {
    if [[ -z "${HOOK_POST_INSTALL:-}" ]]; then
        return 0
    fi

    local hook_script="./scripts/${HOOK_POST_INSTALL}"

    if [[ ! -f "${hook_script}" ]]; then
        log_warn "Hook post-install nao encontrado: ${hook_script}"
        return 0
    fi

    msg_step "HOOK" "Executando post-install..."
    chmod +x "${hook_script}"
    bash "${hook_script}" || log_warn "Hook post-install retornou erro"
    log_success "Hook post-install executado"
}

# Grava arquivo .cctl-instance com metadados
_install_write_instance_file() {
    cat > ./.cctl-instance <<EOF
# Gerado automaticamente pelo cctl install — nao editar manualmente
PROJECT_TYPE="${PROJECT_TYPE}"
CLIENT_NAME="${CLIENT_NAME}"
DOMAIN_NAME="${DOMAIN_NAME}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME}"
CCTL_VERSION="${CCTL_VERSION}"
CREATED_AT="$(date -Iseconds)"
INSTALLED_BY="$(whoami)@$(hostname)"
EOF

    log_debug ".cctl-instance gravado"
}
