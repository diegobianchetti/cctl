#!/bin/bash
# lib/nginx.sh — Gerenciamento de configuracao Nginx no host (nginx-proxy)
#
# Caminhos (NGINX_VHOSTS_DIR, LETSENCRYPT_DIR, PROXY_*) NAO sao redeclarados
# aqui — a fonte unica dos defaults e cctl.conf (sourceado em core_bootstrap
# antes desta lib). Esta lib so consome as variaveis ja definidas.

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
#
# Mantido pelo nome para nao quebrar chamadas/testes existentes — delega
# diretamente a nginx_proxy_reload (mesma logica de teste+reload usada pelo
# proxy nativo, ver "Proxy nativo" abaixo), eliminando a duplicacao.
nginx_test_and_reload() {
    nginx_proxy_reload
}

# Noop: nginx-proxy usa redes runtime (docker network connect/disconnect),
# nao precisa de alteracao no compose file
nginx_remove_network_config() {
    local project_network="$1"
    log_debug "nginx-proxy usa redes runtime — nenhuma alteracao no compose necessaria para ${project_network}"
    return 0
}

# --- Proxy nativo (cctl proxy) ---------------------------------------------
#
# Infraestrutura do proxy Nginx compartilhado: rede Docker global
# (${PROXY_NETWORK}), diretorios de host (vhosts/certs/webroot) e o
# container ${NGINX_CONTAINER_NAME}, criado a partir de ${NGINX_PROXY_IMAGE}.

# Sobe a infraestrutura do proxy (rede + diretorios + container). Idempotente:
# avisa sem falhar se o container ja estiver rodando, inicia se estiver parado.
#
# Cria a arvore INTEIRA a partir de CCTL_BASE_DIR (inclusive instances/), via
# core_priv_run mkdir -p — pode usar sudo se a raiz ainda nao existir/nao for
# gravavel. Em seguida faz "chown" — chamado diretamente com sudo, nao via
# core_priv_run (que nao suporta a operacao "chown") — apenas das FOLHAS
# operacionais (CCTL_INSTANCE_BASE_DIR, NGINX_VHOSTS_DIR) para o usuario que
# invocou (${SUDO_USER:-$(id -un)}).
# LETSENCRYPT_DIR fica FORA do chown -R de proposito: e o certbot (root) quem
# escreve la, inclusive as chaves privadas em archive/*/privkey.pem — se a
# arvore fosse chownada recursivamente a partir de CCTL_BASE_DIR (que contem
# letsencrypt/), essas chaves passariam a ser legiveis sem sudo por qualquer
# processo rodando como o usuario do host. CCTL_BASE_DIR em si recebe chown
# SEM "-R" (só o proprio diretorio, nao o conteudo) para nao arrastar
# letsencrypt/ por baixo; cada folha abaixo dele recebe "-R" individualmente.
# E de proposito: assim o dia a dia (install/up/backup/rollout) passa a
# operar sem sudo nas folhas depois deste "proxy up" inicial, e o sudo fica
# reservado para certbot e para os arquivos fixos de /etc (cron.d,
# logrotate.d). Falha no chown e so aviso — nao aborta a subida do proxy, so
# deixa o alvo sob dono root.
# Indica se "$1" precisa de chown para o usuario operador (dono efetivo
# atual difere do processo). Isolado em funcao (em vez de "[[ ! -O ]]" inline)
# para permitir que os testes forcem o ramo "precisa chown" via override
# pos-source — nao da para simular dono diferente de fato sem root real.
_nginx_dir_needs_chown() {
    [[ ! -O "$1" ]]
}

nginx_proxy_up() {
    if ! docker network inspect "${PROXY_NETWORK}" >/dev/null 2>&1; then
        msg_info "Criando rede ${PROXY_NETWORK}..."
        if ! docker network create "${PROXY_NETWORK}" >/dev/null; then
            log_error "Falha ao criar rede ${PROXY_NETWORK}"
            return 1
        fi
    else
        log_debug "Rede ${PROXY_NETWORK} ja existe"
    fi

    local -a _proxy_dirs=(
        "${CCTL_BASE_DIR}"
        "${CCTL_INSTANCE_BASE_DIR}"
        "${NGINX_VHOSTS_DIR}"
        "${LETSENCRYPT_DIR}"
    )
    local _proxy_dir
    for _proxy_dir in "${_proxy_dirs[@]}"; do
        core_priv_run mkdir -p "${_proxy_dir}" || { log_error "Falha ao criar ${_proxy_dir}"; return 1; }
    done

    local _proxy_owner="${SUDO_USER:-$(id -un)}"
    if _nginx_dir_needs_chown "${CCTL_BASE_DIR}"; then
        local _proxy_chown_err
        if ! _proxy_chown_err="$(sudo chown "${_proxy_owner}:${_proxy_owner}" "${CCTL_BASE_DIR}" 2>&1)"; then
            log_warn "Falha ao ajustar dono de ${CCTL_BASE_DIR} para ${_proxy_owner} (siga usando sudo para operacoes nesta arvore): ${_proxy_chown_err}"
        fi
    fi

    # Folhas operacionais apenas — LETSENCRYPT_DIR fica de fora (root-owned,
    # ver comentario acima do container/proximo de nginx_proxy_up).
    local -a _proxy_owned_dirs=(
        "${CCTL_INSTANCE_BASE_DIR}"
        "${NGINX_VHOSTS_DIR}"
    )
    local _proxy_owned_dir _proxy_chown_leaf_err
    for _proxy_owned_dir in "${_proxy_owned_dirs[@]}"; do
        _nginx_dir_needs_chown "${_proxy_owned_dir}" || continue
        if ! _proxy_chown_leaf_err="$(sudo chown -R "${_proxy_owner}:${_proxy_owner}" "${_proxy_owned_dir}" 2>&1)"; then
            log_warn "Falha ao ajustar dono de ${_proxy_owned_dir} para ${_proxy_owner} (siga usando sudo para operacoes nesta arvore): ${_proxy_chown_leaf_err}"
        fi
    done

    if [[ ! "${PROXY_HTTP_PORT}" =~ ^[0-9]+$ ]]; then
        log_error "PROXY_HTTP_PORT invalido: '${PROXY_HTTP_PORT}' (esperado inteiro)"
        return 1
    fi
    if [[ ! "${PROXY_HTTPS_PORT}" =~ ^[0-9]+$ ]]; then
        log_error "PROXY_HTTPS_PORT invalido: '${PROXY_HTTPS_PORT}' (esperado inteiro)"
        return 1
    fi

    local state
    state="$(docker inspect -f '{{.State.Status}}' "${NGINX_CONTAINER_NAME}" 2>/dev/null || true)"

    if [[ "${state}" == "running" ]]; then
        msg_warn "Container ${NGINX_CONTAINER_NAME} ja esta em execucao"
        return 0
    fi

    if [[ -n "${state}" ]]; then
        msg_info "Container ${NGINX_CONTAINER_NAME} existe e esta parado. Iniciando..."
        if docker start "${NGINX_CONTAINER_NAME}" >/dev/null; then
            msg_success "Proxy ${NGINX_CONTAINER_NAME} iniciado"
            return 0
        fi
        log_error "Falha ao iniciar ${NGINX_CONTAINER_NAME}"
        return 1
    fi

    msg_info "Subindo container ${NGINX_CONTAINER_NAME} (${NGINX_PROXY_IMAGE})..."
    if docker run -d \
        --name "${NGINX_CONTAINER_NAME}" \
        --network "${PROXY_NETWORK}" \
        --restart unless-stopped \
        --cap-add NET_RAW \
        -p "${PROXY_HTTP_PORT}:80" \
        -p "${PROXY_HTTPS_PORT}:443" \
        -v "${NGINX_VHOSTS_DIR}:/etc/nginx/conf.d/vhosts:ro" \
        -v "${LETSENCRYPT_DIR}:/etc/letsencrypt:rw" \
        "${NGINX_PROXY_IMAGE}" >/dev/null; then
        msg_success "Proxy ${NGINX_CONTAINER_NAME} em execucao (rede ${PROXY_NETWORK})"
        return 0
    fi

    log_error "Falha ao subir o container ${NGINX_CONTAINER_NAME}"
    return 1
}

# Verifica se o container do proxy existe; caso contrario avisa e retorna 1.
_nginx_proxy_require_container() {
    if ! docker inspect "${NGINX_CONTAINER_NAME}" &>/dev/null; then
        log_error "Container ${NGINX_CONTAINER_NAME} nao existe. Execute 'cctl proxy up' primeiro."
        return 1
    fi
    return 0
}

# Para e remove o container do proxy. Avisa (sem falhar) se nao existir.
nginx_proxy_down() {
    if ! docker inspect "${NGINX_CONTAINER_NAME}" >/dev/null 2>&1; then
        msg_warn "Container ${NGINX_CONTAINER_NAME} nao existe"
        return 0
    fi

    msg_info "Parando ${NGINX_CONTAINER_NAME}..."
    docker stop "${NGINX_CONTAINER_NAME}" >/dev/null 2>&1

    if ! docker rm "${NGINX_CONTAINER_NAME}" >/dev/null 2>&1; then
        log_error "Falha ao remover o container ${NGINX_CONTAINER_NAME}"
        return 1
    fi

    msg_success "Proxy ${NGINX_CONTAINER_NAME} parado e removido"
}

# Testa a configuracao do Nginx e recarrega se valida. Aborta com erro claro
# caso o teste de sintaxe falhe.
nginx_proxy_reload() {
    _nginx_proxy_require_container || return 1

    msg_info "Testando configuracao nginx..."
    if ! docker exec "${NGINX_CONTAINER_NAME}" nginx -t; then
        log_error "Configuracao nginx invalida — reload abortado"
        return 1
    fi

    docker exec "${NGINX_CONTAINER_NAME}" nginx -s reload
    msg_success "Configuracao recarregada"
}

# Executa apenas o teste de sintaxe (todos os vhosts montados)
nginx_proxy_test() {
    _nginx_proxy_require_container || return 1

    docker exec "${NGINX_CONTAINER_NAME}" nginx -t
}

# Encaminha argumentos extras (-f, --tail N, ...) para `docker logs`
nginx_proxy_logs() {
    _nginx_proxy_require_container || return 1

    docker logs "${NGINX_CONTAINER_NAME}" "$@"
}

# Exibe status do container, saude, portas e existencia da rede do proxy
nginx_proxy_status() {
    msg_header "Status do proxy (${NGINX_CONTAINER_NAME})"

    if ! docker inspect "${NGINX_CONTAINER_NAME}" >/dev/null 2>&1; then
        msg_warn "Container ${NGINX_CONTAINER_NAME} nao existe"
    else
        local status health ports
        status="$(docker inspect -f '{{.State.Status}}' "${NGINX_CONTAINER_NAME}" 2>/dev/null)"
        health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' "${NGINX_CONTAINER_NAME}" 2>/dev/null)"
        ports="$(docker inspect -f '{{range $p, $c := .NetworkSettings.Ports}}{{$p}} {{end}}' "${NGINX_CONTAINER_NAME}" 2>/dev/null)"

        echo -e "  Container: ${CYAN}${NGINX_CONTAINER_NAME}${RESET}"
        echo -e "  Status:    ${CYAN}${status}${RESET}"
        echo -e "  Saude:     ${CYAN}${health}${RESET}"
        echo -e "  Portas:    ${CYAN}${ports}${RESET}"
    fi

    if docker network inspect "${PROXY_NETWORK}" >/dev/null 2>&1; then
        echo -e "  Rede ${PROXY_NETWORK}: ${GREEN}existe${RESET}"
    else
        echo -e "  Rede ${PROXY_NETWORK}: ${RED}nao existe${RESET}"
    fi
}
