#!/bin/bash
# commands/install.sh — Instala a instancia no servidor
#
# Pré-requisito: estar no diretorio do projeto (com project.conf, sem .cctl-instance)
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
#   9. SSL (se HOST_SSL) + Nginx (se HOST_NGINX) — SSL antes do nginx para
#      que o certificado ja exista quando "nginx -t" validar a config final
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

    # 2b. Limpa rede orfa de uma instalacao/down anterior que tenha falhado
    # antes de desconectar o nginx-proxy (ver network_cleanup_orphans em
    # lib/network.sh) — sem isso, a rede orfa fica com o proxy conectado e
    # o "docker compose up" seguinte pode reaproveitar/colidir com ela.
    _install_cleanup_orphan_network

    # 3. Gera senhas
    passwords_generate_all

    # 4. Aloca subnet
    _install_allocate_subnet || return 1

    # 5. Renderiza templates
    _install_set_ssl_paths || return 1
    msg_step "TEMPLATES" "Renderizando templates..."
    env_render_all_templates
    log_success "Templates renderizados"

    # 6. Recarrega .env apos geracoes de senhas e subnet
    env_load

    # 7. Pre-flight checks
    validate_preflight_install || return 1

    # 8. Pull imagens
    compose_pull || return 1

    # 9. Build (se necessario)
    _install_build_if_needed

    # 10. Up
    compose_up

    # 11. SSL + Nginx — SSL roda ANTES para que o certificado (self-signed,
    # manual ou letsencrypt) ja exista quando _install_nginx testar a
    # configuracao final com "nginx -t" (ver _install_ssl para o bootstrap
    # do desafio ACME quando o certificado letsencrypt ainda nao existe).
    _install_ssl
    _install_nginx || return 1

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

# Define {{SSL_CERT_PATH}}/{{SSL_KEY_PATH}} no .env com base no SSL_MODE do
# manifest, para que env_render_all_templates os substitua nos templates
# nginx (ssl_certificate / ssl_certificate_key)
_install_set_ssl_paths() {
    local cert_path key_path
    cert_path=$(ssl_get_cert_path "${DOMAIN_NAME}") || return 1
    key_path=$(ssl_get_key_path "${DOMAIN_NAME}") || return 1

    env_set_var "SSL_CERT_PATH" "${cert_path}"
    env_set_var "SSL_KEY_PATH" "${key_path}"
}

# Remove rede orfa do projeto (com o nginx-proxy ainda preso nela) deixada
# por uma instalacao/down anterior que falhou antes de desconectar o proxy
# — para que um `cctl install` logo apos um `install` malsucedido tambem se
# recupere, em vez de herdar a rede velha. Sem COMPOSE_PROJECT_NAME (nao
# deveria acontecer a essa altura, ja carregado do manifest) e um no-op.
_install_cleanup_orphan_network() {
    if [[ -z "${COMPOSE_PROJECT_NAME:-}" ]]; then
        return 0
    fi

    msg_step "REDE" "Verificando rede orfa de instalacao anterior..."
    network_cleanup_orphans "${COMPOSE_PROJECT_NAME}"
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

    # Conecta a rede antes de testar o config (resolver Docker precisa da rede)
    local project_networks project_network
    project_networks=$(network_list_for_project "${COMPOSE_PROJECT_NAME}")
    project_network=$(head -n1 <<< "${project_networks}")
    if [[ -z "${project_network}" ]]; then
        log_warn "Nenhuma rede encontrada para o projeto ${COMPOSE_PROJECT_NAME}, pulando conexao do nginx-proxy"
    else
        if [[ $(wc -l <<< "${project_networks}") -gt 1 ]]; then
            log_warn "Mais de uma rede encontrada para o projeto ${COMPOSE_PROJECT_NAME}, usando: ${project_network}"
        fi
        network_connect_nginx "${project_network}"
    fi

    # Vhost HTTP-only quando SSL esta desabilitado: SSL_MODE=none, HOST_SSL=false
    # ou o legado MOODLE_SSL=false. Se existir um template dedicado
    # (nginx/site-nossl.conf.template), renderiza-o para nginx/site.conf;
    # senao usa um site-nossl.conf ja renderizado, se houver.
    local nginx_conf="./nginx/site.conf"
    local ssl_disabled=false
    if [[ "${SSL_MODE:-}" == "none" || "${HOST_SSL:-false}" != "true" || "${MOODLE_SSL:-true}" == "false" ]]; then
        ssl_disabled=true
    fi

    if [[ "${ssl_disabled}" == "true" ]]; then
        if [[ -f "./nginx/site-nossl.conf.template" ]]; then
            log_debug "SSL desabilitado — renderizando vhost HTTP-only a partir de site-nossl.conf.template"
            env_render_template "./nginx/site-nossl.conf.template" "${nginx_conf}"
        elif [[ -f "./nginx/site-nossl.conf" ]]; then
            nginx_conf="./nginx/site-nossl.conf"
            log_debug "SSL desabilitado — usando site-nossl.conf ja renderizado"
        else
            log_debug "SSL desabilitado, sem template/arquivo nossl dedicado — limpando diretivas ssl vazias em site.conf padrao"
            _ssl_strip_empty_cert_directives "${nginx_conf}"
        fi
    fi

    nginx_enable_site "${DOMAIN_NAME}" "${nginx_conf}" || return 1
}

# Solicita/instala certificado SSL (se HOST_SSL=true, MOODLE_SSL!=false e
# SSL_MODE!=none). Roda ANTES de _install_nginx (ver cmd_install) para que o
# certificado ja exista quando o nginx testar a configuracao final.
_install_ssl() {
    if [[ "${HOST_SSL:-false}" != "true" ]]; then
        log_debug "HOST_SSL desabilitado, pulando SSL"
        return 0
    fi

    if [[ "${MOODLE_SSL:-true}" == "false" ]]; then
        log_debug "MOODLE_SSL=false — pulando SSL"
        return 0
    fi

    if [[ "${SSL_MODE:-}" == "none" ]]; then
        log_debug "SSL_MODE=none — pulando emissao de certificado"
        return 0
    fi

    # letsencrypt exige um vhost HTTP respondendo em /.well-known/acme-challenge/
    # ANTES da emissao (desafio webroot). Se o certificado ainda nao existe,
    # sobe temporariamente esse vhost HTTP puro; o vhost final (SSL ou nossl)
    # e aplicado depois por _install_nginx.
    if [[ "$(_ssl_mode)" == "letsencrypt" ]] && [[ "${HOST_NGINX:-false}" == "true" ]] \
        && ! ssl_cert_exists "${DOMAIN_NAME}"; then
        _install_bootstrap_letsencrypt_http_vhost || \
            log_warn "Falha ao preparar vhost HTTP temporario para o desafio ACME — emissao letsencrypt pode falhar"
    fi

    ssl_issue "${DOMAIN_NAME}" || log_warn "Falha no SSL. Verifique manualmente."
}

# Sobe temporariamente um vhost HTTP puro e ISOLADO (./nginx/.acme-bootstrap.conf)
# so com a rota /.well-known/acme-challenge/, para o certbot conseguir emitir
# o primeiro certificado via webroot. Nao e usado em renovacoes
# (ssl_cert_exists ja filtra esse caso no chamador).
#
# IMPORTANTE: nunca tocar em ./nginx/site.conf aqui — esse arquivo ja contem
# o vhost HTTPS final renderizado por env_render_all_templates (cmd_install,
# passo 5) e e ativado logo em seguida por _install_nginx apos o Certbot
# emitir o certificado. Usar um arquivo dedicado evita sobrescrever/destruir
# o vhost final durante o bootstrap.
_install_bootstrap_letsencrypt_http_vhost() {
    local domain="${DOMAIN_NAME}"
    local tmp_conf="./nginx/.acme-bootstrap.conf"

    msg_step "SSL" "Publicando vhost HTTP temporario para o desafio ACME..."

    cat > "${tmp_conf}" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domain};
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
    location / {
        return 404;
    }
}
EOF

    local project_networks project_network
    project_networks=$(network_list_for_project "${COMPOSE_PROJECT_NAME}")
    project_network=$(head -n1 <<< "${project_networks}")
    if [[ -z "${project_network}" ]]; then
        log_warn "Nenhuma rede encontrada para o projeto ${COMPOSE_PROJECT_NAME}, pulando conexao do nginx-proxy"
    else
        if [[ $(wc -l <<< "${project_networks}") -gt 1 ]]; then
            log_warn "Mais de uma rede encontrada para o projeto ${COMPOSE_PROJECT_NAME}, usando: ${project_network}"
        fi
        network_connect_nginx "${project_network}"
    fi

    local result=0
    nginx_enable_site "${domain}" "${tmp_conf}" || result=1

    rm -f "${tmp_conf}"

    return "${result}"
}

# Instala cron entries no host (se HOST_CRON=true) — logica real em
# lib/cron.sh:cron_install (CRON_DIR + core_priv_run + fallback pra crontab
# do usuario); aqui so o guard de HOST_CRON e a mensagem de etapa do install.
_install_cron() {
    if [[ "${HOST_CRON:-false}" != "true" ]]; then
        log_debug "HOST_CRON desabilitado, pulando cron"
        return 0
    fi

    msg_step "CRON" "Instalando cron jobs..."
    cron_install
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
