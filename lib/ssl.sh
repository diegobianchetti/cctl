#!/bin/bash
# lib/ssl.sh — Gerenciamento de certificados SSL
#
# Modos suportados (SSL_MODE no project.conf):
#   letsencrypt — Certbot via webroot (padrao)
#   manual      — Certificados fornecidos pelo usuario (SSL_CERT_FILE + SSL_KEY_FILE)

# Diretorio padrao onde nginx espera os certificados
SSL_CERTS_DIR="${SSL_CERTS_DIR:-/etc/nginx-proxy/certs}"

# Diretorio padrao onde o certbot (letsencrypt) guarda os certificados
LETSENCRYPT_LIVE_DIR="${LETSENCRYPT_LIVE_DIR:-/etc/letsencrypt/live}"

# mkdir/cp/install com sudo somente quando necessario: ver core_priv_run
# (lib/core.sh) — usado diretamente abaixo (_ssl_issue_manual).

# Resolve o modo SSL configurado (padrao: letsencrypt)
_ssl_mode() {
    echo "${SSL_MODE:-letsencrypt}"
}

# Verifica se o dominio e local (localhost, *.local, *.test)
_ssl_is_local_domain() {
    local domain="$1"
    case "${domain}" in
        localhost|*.local|*.test) return 0 ;;
        *) return 1 ;;
    esac
}

# ============================================================
# Emissao / instalacao de certificado
# ============================================================

# Dispatcher principal — chama o handler do modo configurado
ssl_issue() {
    local domain="${1:-${DOMAIN_NAME}}"

    if _ssl_is_local_domain "${domain}"; then
        log_debug "Dominio local (${domain}), pulando SSL"
        return 0
    fi

    local mode
    mode=$(_ssl_mode)

    case "${mode}" in
        letsencrypt) _ssl_issue_letsencrypt "${domain}" ;;
        manual)      _ssl_issue_manual "${domain}" ;;
        *)
            log_error "SSL_MODE invalido: ${mode} (use 'letsencrypt' ou 'manual')"
            return 1
            ;;
    esac
}

# --- modo letsencrypt ------------------------------------------------

_ssl_issue_letsencrypt() {
    local domain="$1"

    if ! command -v certbot &>/dev/null; then
        log_warn "certbot nao encontrado. Instale para SSL automatico."
        return 1
    fi

    msg_step "SSL" "Solicitando certificado Let's Encrypt para ${domain}..."

    local webroot="${CERTBOT_WEBROOT_DIR:-/etc/nginx-proxy/certbot}"
    local email="${CERTBOT_EMAIL:-admin@${domain}}"

    if sudo certbot certonly --webroot \
        -w "${webroot}" \
        -d "${domain}" \
        --non-interactive \
        --agree-tos \
        --email "${email}"; then
        log_success "Certificado SSL emitido para ${domain}"
        nginx_test_and_reload
    else
        log_error "Falha ao emitir certificado SSL para ${domain}"
        return 1
    fi
}

# --- modo manual -----------------------------------------------------

_ssl_issue_manual() {
    local domain="$1"

    local cert_src="${SSL_CERT_FILE:-}"
    local key_src="${SSL_KEY_FILE:-}"

    if [[ -z "${cert_src}" || -z "${key_src}" ]]; then
        log_error "SSL_MODE=manual requer SSL_CERT_FILE e SSL_KEY_FILE no project.conf"
        return 1
    fi

    if [[ ! -f "${cert_src}" ]]; then
        log_error "Arquivo de certificado nao encontrado: ${cert_src}"
        return 1
    fi

    if [[ ! -f "${key_src}" ]]; then
        log_error "Arquivo de chave privada nao encontrado: ${key_src}"
        return 1
    fi

    msg_step "SSL" "Instalando certificado manual para ${domain}..."

    local dest_dir="${SSL_CERTS_DIR}/${domain}"

    core_priv_run mkdir -p "${dest_dir}" || { log_error "Falha ao criar ${dest_dir}"; return 1; }
    core_priv_run cp "${cert_src}" "${dest_dir}/fullchain.pem" || {
        log_error "Falha ao copiar certificado para ${dest_dir}/fullchain.pem"
        return 1
    }
    # install -m 600 evita a janela de exposicao entre cp e chmod para a chave privada
    core_priv_run install -m 600 "${key_src}" "${dest_dir}/privkey.pem" || {
        log_error "Falha ao instalar chave privada em ${dest_dir}/privkey.pem"
        return 1
    }

    log_success "Certificado manual instalado em ${dest_dir}"
    nginx_test_and_reload
}

# ============================================================
# Renovacao
# ============================================================

ssl_renew() {
    local mode
    mode=$(_ssl_mode)

    case "${mode}" in
        letsencrypt)
            if ! command -v certbot &>/dev/null; then
                log_warn "certbot nao encontrado"
                return 1
            fi
            msg_step "SSL" "Renovando certificados Let's Encrypt..."
            if sudo certbot renew --quiet; then
                log_success "Certificados renovados"
                nginx_test_and_reload
            else
                log_warn "Falha na renovacao de certificados"
                return 1
            fi
            ;;
        manual)
            msg_info "SSL_MODE=manual — renovacao nao e automatica."
            msg_info "Substitua os arquivos e execute: cctl ssl-install"
            ;;
        *)
            log_error "SSL_MODE invalido: ${mode}"
            return 1
            ;;
    esac
}

# ============================================================
# Status
# ============================================================

ssl_status() {
    local domain="${1:-${DOMAIN_NAME}}"
    local mode
    mode=$(_ssl_mode)

    local cert_file=""

    case "${mode}" in
        letsencrypt)
            cert_file="${LETSENCRYPT_LIVE_DIR}/${domain}/cert.pem"
            ;;
        manual)
            cert_file="${SSL_CERTS_DIR}/${domain}/fullchain.pem"
            ;;
    esac

    if [[ ! -f "${cert_file}" ]]; then
        msg_warn "Nenhum certificado encontrado para ${domain}"
        return 1
    fi

    local expiry
    if [[ -r "${cert_file}" ]]; then
        expiry=$(openssl x509 -enddate -noout -in "${cert_file}" 2>/dev/null | cut -d= -f2)
    else
        expiry=$(sudo openssl x509 -enddate -noout -in "${cert_file}" 2>/dev/null | cut -d= -f2)
    fi

    echo -e "  Dominio:     ${CYAN}${domain}${RESET}"
    echo -e "  Modo SSL:    ${CYAN}${mode}${RESET}"
    echo -e "  Certificado: ${cert_file}"
    echo -e "  Expira em:   ${YELLOW}${expiry}${RESET}"
}
