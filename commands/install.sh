#!/bin/bash
# commands/install.sh — Instala a instancia no servidor
#
# Pré-requisito: estar no diretorio do projeto (com project.conf, sem .cctl-instance)
#
# Fluxo:
#   1. Valida contexto (project.conf existe, .cctl-instance NAO existe)
#   2. Source project.conf + .env
#   3. Gera senhas (AUTO_PASSWORD_VARS)
#   4. Pre-flight checks (sudo, Docker, disco, range de rede, DNS)
#   5. Rede do projeto: reaproveita a que ja existe ou sugere a proxima
#      faixa livre do range do cctl.conf e cria (com confirmacao se houver
#      terminal); grava CCTL_PROJECT_NETWORK e COMPOSE_PROJECT_SUBNET no .env
#   6. Renderiza templates
#   7. Pull/build imagens
#   8. Up containers (a rede ja existe: o compose so a usa como "external")
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

    # 3. Gera senhas
    passwords_generate_all

    # 4. Pre-flight checks — ANTES de criar a rede: o range de rede tambem
    # e conferido aqui, e nao faz sentido reservar uma faixa num host que
    # nem passa nas verificacoes.
    validate_preflight_install || return 1

    # 5. Rede do projeto (a rede existe antes do primeiro "compose up")
    _install_ensure_network || return 1

    # 6. Renderiza templates
    _install_set_ssl_paths || return 1
    msg_step "TEMPLATES" "Renderizando templates..."
    env_render_all_templates
    log_success "Templates renderizados"

    # 7. Recarrega .env apos geracoes de senhas e rede
    env_load

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
    _install_cron || return 1

    # 13. Hook post-install
    _install_post_hook || return 1

    # 14. Grava .cctl-instance
    _install_write_instance_file

    # Resumo
    echo ""
    msg_header "Instalacao concluida!"
    echo ""
    echo -e "  Projeto:  ${CYAN}${PROJECT_TYPE}${RESET}"
    echo -e "  Cliente:  ${CYAN}${CLIENT_NAME}${RESET}"
    echo -e "  Dominio:  ${CYAN}${DOMAIN_NAME}${RESET}"
    echo -e "  Rede:     ${CYAN}${CCTL_PROJECT_NETWORK:-N/A}${RESET}"
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

# Cria (ou reaproveita) a rede do projeto — logica em
# lib/network.sh:network_provision_for_install.
_install_ensure_network() {
    msg_step "REDE" "Preparando a rede do projeto..."
    network_provision_for_install
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

# Conecta o nginx-proxy a rede do projeto (CCTL_PROJECT_NETWORK, criada no
# passo da rede), com alias = DOMAIN_NAME. Sem a rede registrada no .env, so
# avisa — o install ja teria falhado antes disso.
_install_connect_proxy() {
    if [[ -z "${CCTL_PROJECT_NETWORK:-}" ]]; then
        log_warn "CCTL_PROJECT_NETWORK nao definido para o projeto ${COMPOSE_PROJECT_NAME}, pulando conexao do nginx-proxy"
        return 0
    fi
    if ! network_ensure_nginx_connected "${CCTL_PROJECT_NETWORK}" "${DOMAIN_NAME:-}"; then
        log_error "Nao foi possivel conectar o nginx-proxy a rede ${CCTL_PROJECT_NETWORK}; o vhost nao sera publicado."
        return 1
    fi
    return 0
}

# Configura nginx no host (se HOST_NGINX=true)
_install_nginx() {
    if [[ "${HOST_NGINX:-false}" != "true" ]]; then
        log_debug "HOST_NGINX desabilitado, pulando nginx"
        return 0
    fi

    msg_step "NGINX" "Configurando Nginx..."

    # Conecta a rede antes de testar o config (resolver Docker precisa da rede).
    # O chamador usa `|| return`, que inibe errexit dentro desta funcao; cheque
    # explicitamente para nunca publicar um vhost com o proxy desconectado.
    _install_connect_proxy || return 1

    # Vhost HTTP-only quando SSL esta desabilitado: SSL_MODE=none ou
    # HOST_SSL!=true (o cctl nao olha variaveis especificas de cada projeto).
    # Se existir um template dedicado
    # (nginx/site-nossl.conf.template), renderiza-o para nginx/site.conf;
    # senao usa um site-nossl.conf ja renderizado, se houver.
    local nginx_conf="./nginx/site.conf"
    local ssl_disabled=false
    if [[ "${SSL_MODE:-}" == "none" || "${HOST_SSL:-false}" != "true" ]]; then
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

    # Antes de publicar: todo alvo do vhost tem de ser <container>.<rede>
    # (rede vazia ou nome curto = nao publica).
    vhost_validate_targets "${nginx_conf}" "${CCTL_PROJECT_NETWORK:-}" || return 1

    nginx_enable_site "${DOMAIN_NAME}" "${nginx_conf}" || return 1

    # Depois de publicar: de dentro do proxy, cada alvo resolve para o
    # container DESTE projeto.
    if [[ -n "${CCTL_PROJECT_NETWORK:-}" ]]; then
        network_check_vhost_targets "${NGINX_VHOSTS_DIR}/${COMPOSE_PROJECT_NAME}.conf" "${CCTL_PROJECT_NETWORK}" || {
            log_error "O vhost foi publicado, mas o alvo nao aponta para o container deste projeto. Instalacao interrompida."
            msg_info "O vhost foi MANTIDO de proposito (${NGINX_VHOSTS_DIR}/${COMPOSE_PROJECT_NAME}.conf): o alvo <container>.<rede> so resolve dentro da rede deste projeto, entao o pior caso e um erro 502 — nunca o site de outro projeto. Corrija a causa apontada acima e rode 'cctl install' de novo."
            return 1
        }
    fi
}

# Solicita/instala certificado SSL (se HOST_SSL=true e SSL_MODE!=none).
# Roda ANTES de _install_nginx (ver cmd_install) para que o certificado ja
# exista quando o nginx testar a configuracao final.
_install_ssl() {
    if [[ "${HOST_SSL:-false}" != "true" ]]; then
        log_debug "HOST_SSL desabilitado, pulando SSL"
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

    local result=0
    if ! _install_connect_proxy; then
        result=1
    else
        nginx_enable_site "${domain}" "${tmp_conf}" || result=1
    fi

    rm -f "${tmp_conf}"

    return "${result}"
}

# Instala cron entries no host (se HOST_CRON=true) — logica real em
# lib/cron.sh:cron_install (CRON_DIR + core_priv_run); aqui so o guard de
# HOST_CRON e a mensagem de etapa do install. Falha ao instalar propaga rc 1.
_install_cron() {
    if [[ "${HOST_CRON:-false}" != "true" ]]; then
        log_debug "HOST_CRON desabilitado, pulando cron"
        return 0
    fi

    msg_step "CRON" "Instalando cron jobs..."
    cron_install || return 1
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
    local hook_rc=0
    bash "${hook_script}" || hook_rc=$?
    if [[ ${hook_rc} -ne 0 ]]; then
        log_error "Hook post-install falhou (rc=${hook_rc}): ${hook_script}"
        return 1
    fi
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

    # Registra/atualiza o inventario (F2.4) DEPOIS do .cctl-instance ja
    # estar gravado — e esse arquivo, nao o inventario, que e a fonte de
    # verdade de "instancia instalada" (core_detect_context). Se nao havia
    # registro "prepared" (projeto nunca passou por `cctl init`, ou
    # inventario anterior a F2.4), inventory_mark_installed cria um novo
    # registro direto em installed, adotando a instancia.
    #
    # Falha aqui NAO aborta o install: a instancia ja esta funcional
    # (containers de pe, .cctl-instance gravado) — mesmo criterio dos
    # demais passos nao-essenciais do fluxo (cron, hook post-install, ver
    # acima). log_error (nao log_warn) porque, diferente deles, o efeito e
    # "cctl list" nao ver esta instancia — vale a visibilidade mais forte.
    # A rede e a faixa vao junto (so quando existem): sem registro previo, e
    # aqui que a reserva da faixa entra no inventario.
    local -a _inv_network_args=()
    if [[ -n "${CCTL_PROJECT_NETWORK:-}" ]]; then
        _inv_network_args=("${CCTL_PROJECT_NETWORK}" "${COMPOSE_PROJECT_SUBNET:-}")
    fi
    if ! inventory_mark_installed "${COMPOSE_PROJECT_NAME}" "${PROJECT_TYPE}" "${CLIENT_NAME}" "${DOMAIN_NAME}" "$(pwd)" "${_inv_network_args[@]}"; then
        log_error "Instancia instalada, mas falhou o registro/atualizacao no inventario (cctl list pode nao refletir esta instancia)."
    fi
}
