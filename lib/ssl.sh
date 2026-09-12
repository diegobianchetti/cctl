#!/bin/bash
# lib/ssl.sh — Gerenciamento de certificados SSL
#
# Modos suportados (SSL_MODE no project.conf):
#   self-signed — par autoassinado gerado na hora via OpenSSL (dev/homologacao)
#   letsencrypt — Certbot via webroot compartilhado com o proxy (padrao)
#   manual      — Certificados fornecidos pelo usuario (SSL_CERT_FILE + SSL_KEY_FILE)
#   none        — sem SSL, fallback puramente HTTP

# Diretorio padrao onde nginx espera os certificados (manual/self-signed)
SSL_CERTS_DIR="${SSL_CERTS_DIR:-/etc/nginx-proxy/certs}"

# Diretorio padrao onde o certbot (letsencrypt) guarda os certificados —
# derivado de LETSENCRYPT_DIR (lib/nginx.sh) para manter os dois em sincronia
# quando so LETSENCRYPT_DIR e customizado.
LETSENCRYPT_LIVE_DIR="${LETSENCRYPT_LIVE_DIR:-${LETSENCRYPT_DIR:-/etc/letsencrypt}/live}"

# mkdir/cp/install com sudo somente quando necessario: ver core_priv_run
# (lib/core.sh) — usado diretamente pelos handlers de emissao abaixo.

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
# Resolucao de caminhos (dentro do container nginx-proxy)
# ============================================================

# Caminho do fullchain dentro do container, conforme o modo SSL configurado
ssl_get_cert_path() {
    local domain="${1:-${DOMAIN_NAME}}"
    local mode
    mode=$(_ssl_mode)

    case "${mode}" in
        none) echo ""; return 0 ;;
        letsencrypt) echo "/etc/letsencrypt/live/${domain}/fullchain.pem" ;;
        manual|self-signed) echo "/etc/nginx/certs/${domain}/fullchain.pem" ;;
        *) log_error "SSL_MODE invalido: ${mode}"; return 1 ;;
    esac
}

# Caminho da chave privada dentro do container, conforme o modo SSL configurado
ssl_get_key_path() {
    local domain="${1:-${DOMAIN_NAME}}"
    local mode
    mode=$(_ssl_mode)

    case "${mode}" in
        none) echo ""; return 0 ;;
        letsencrypt) echo "/etc/letsencrypt/live/${domain}/privkey.pem" ;;
        manual|self-signed) echo "/etc/nginx/certs/${domain}/privkey.pem" ;;
        *) log_error "SSL_MODE invalido: ${mode}"; return 1 ;;
    esac
}

# Verifica se o certificado (fullchain) do modo/dominio atuais ja existe no
# filesystem. Usa sudo quando o arquivo nao e legivel pelo usuario atual
# (ex.: /etc/letsencrypt e normalmente 0700 root). SSL_MODE=none nunca "tem"
# certificado.
ssl_cert_exists() {
    local domain="${1:-${DOMAIN_NAME}}"
    local cert_path
    cert_path=$(ssl_get_cert_path "${domain}") || return 1
    [[ -z "${cert_path}" ]] && return 1

    if [[ -r "${cert_path}" ]]; then
        [[ -f "${cert_path}" ]]
    else
        sudo test -f "${cert_path}" 2>/dev/null
    fi
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
        self-signed) _ssl_issue_self_signed "${domain}" ;;
        letsencrypt) _ssl_issue_letsencrypt "${domain}" ;;
        manual)      _ssl_issue_manual "${domain}" ;;
        none)        _ssl_issue_none "${domain}" ;;
        *)
            log_error "SSL_MODE invalido: ${mode} (use 'self-signed', 'letsencrypt', 'manual' ou 'none')"
            return 1
            ;;
    esac
}

# --- modo self-signed --------------------------------------------------

# Gera um par de chaves + certificado X.509 autoassinado, com SAN cobrindo
# o dominio e o wildcard correspondente (evita rejeicao em navegadores
# modernos, WebSockets, PWAs e chamadas de API que exigem SAN).
_ssl_issue_self_signed() {
    local domain="$1"

    if ! command -v openssl &>/dev/null; then
        log_error "openssl nao encontrado. Necessario para SSL_MODE=self-signed."
        return 1
    fi

    msg_step "SSL" "Gerando certificado autoassinado para ${domain}..."

    local tmp_dir
    tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/cctl_selfsigned.XXXXXX")" || {
        log_error "Falha ao criar diretorio temporario para o certificado"
        return 1
    }

    # Limpeza garantida ao sair da funcao por qualquer caminho (sucesso ou
    # qualquer um dos "return 1" abaixo) — evita deixar a chave temporaria
    # orfa em /tmp caso um passo intermediario falhe.
    #
    # "set +T" desarma functrace antes de armar o trap: com functrace ligado
    # (ex. bats-core roda com "set -eET"), um RETURN trap e herdado por TODA
    # funcao aninhada chamada depois (core_priv_run, log_*, etc.), disparando
    # a limpeza no primeiro retorno de funcao interna — muito antes deste
    # "_ssl_issue_self_signed" realmente terminar, apagando tmp_dir antes de
    # instalar o certificado. Restaura o estado original de functrace dentro
    # do proprio trap, entao o comportamento do chamador nao muda.
    local _cctl_functrace_was_on=0
    [[ $- == *T* ]] && _cctl_functrace_was_on=1
    set +T
    trap 'rm -rf "${tmp_dir}"; (( _cctl_functrace_was_on )) && set -T; trap - RETURN' RETURN

    local tmp_key="${tmp_dir}/privkey.pem"
    local tmp_cert="${tmp_dir}/fullchain.pem"

    if ! openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout "${tmp_key}" \
        -out "${tmp_cert}" \
        -subj "/CN=${domain}" \
        -addext "subjectAltName=DNS:${domain},DNS:*.${domain}" \
        &>/dev/null; then
        log_error "Falha ao gerar certificado autoassinado para ${domain}"
        return 1
    fi

    local dest_dir="${SSL_CERTS_DIR}/${domain}"

    core_priv_run mkdir -p "${dest_dir}" || {
        log_error "Falha ao criar ${dest_dir}"
        return 1
    }
    core_priv_run install -m 644 "${tmp_cert}" "${dest_dir}/fullchain.pem" || {
        log_error "Falha ao instalar certificado em ${dest_dir}/fullchain.pem"
        return 1
    }
    # install -m 600 evita a janela de exposicao entre cp e chmod para a chave privada
    core_priv_run install -m 600 "${tmp_key}" "${dest_dir}/privkey.pem" || {
        log_error "Falha ao instalar chave privada em ${dest_dir}/privkey.pem"
        return 1
    }

    log_success "Certificado autoassinado instalado em ${dest_dir}"
    nginx_proxy_reload
}

# --- modo letsencrypt ------------------------------------------------

_ssl_issue_letsencrypt() {
    local domain="$1"

    if ! command -v certbot &>/dev/null; then
        log_warn "certbot nao encontrado. Instale para SSL automatico."
        return 1
    fi

    if ! validate_dns "${domain}"; then
        log_error "DNS de ${domain} nao resolve — emissao Let's Encrypt abortada."
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
        nginx_proxy_reload
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

    if ! _ssl_keypair_matches "${cert_src}" "${key_src}"; then
        log_error "Certificado e chave privada nao formam um par valido (chave publica do certificado nao corresponde a chave privada): ${cert_src} / ${key_src}"
        return 1
    fi

    msg_step "SSL" "Instalando certificado manual para ${domain}..."

    local dest_dir="${SSL_CERTS_DIR}/${domain}"

    core_priv_run mkdir -p "${dest_dir}" || { log_error "Falha ao criar ${dest_dir}"; return 1; }
    core_priv_run install -m 644 "${cert_src}" "${dest_dir}/fullchain.pem" || {
        log_error "Falha ao instalar certificado em ${dest_dir}/fullchain.pem"
        return 1
    }
    # install -m 600 evita a janela de exposicao entre cp e chmod para a chave privada
    core_priv_run install -m 600 "${key_src}" "${dest_dir}/privkey.pem" || {
        log_error "Falha ao instalar chave privada em ${dest_dir}/privkey.pem"
        return 1
    }

    log_success "Certificado manual instalado em ${dest_dir}"
    nginx_proxy_reload
}

# Le um arquivo respeitando permissoes: cat direto se legivel pelo usuario
# atual, senao recorre a core_priv_run (sudo) — necessario para comparar
# chaves privadas 0600 pertencentes a root sem exigir acesso direto a elas.
_ssl_read_file() {
    local f="$1"
    if [[ -r "${f}" ]]; then
        cat "${f}"
    else
        core_priv_run cat "${f}"
    fi
}

# Compara a chave publica do certificado com a da chave privada: extrai a
# chave publica de cada lado em DER e compara o hash SHA-256. Agnostico de
# algoritmo (RSA, ECDSA, Ed25519) — ao contrario da comparacao de modulus
# (RSA-only). Retorna 0 se baterem (par valido), 1 caso contrario ou em erro
# de leitura/parse. Nao altera nenhum arquivo existente — checagem e sempre
# feita ANTES de instalar.
_ssl_keypair_matches() {
    local cert_file="$1"
    local key_file="$2"

    local cert_pubkey key_pubkey
    cert_pubkey=$(_ssl_read_file "${cert_file}" | openssl x509 -noout -pubkey 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | openssl sha256 2>/dev/null)
    key_pubkey=$(_ssl_read_file "${key_file}" | openssl pkey -pubout -outform DER 2>/dev/null | openssl sha256 2>/dev/null)

    [[ -n "${cert_pubkey}" && "${cert_pubkey}" == "${key_pubkey}" ]]
}

# Remove diretivas ssl_certificate/ssl_certificate_key vazias (sem valor) de
# um vhost ja renderizado. Ocorre quando SSL_MODE=none e o vhost final usado
# e o site.conf padrao (sem site-nossl.conf.template/site-nossl.conf
# dedicado): {{SSL_CERT_PATH}}/{{SSL_KEY_PATH}} sao renderizados como string
# vazia (ver ssl_get_cert_path/ssl_get_key_path, modo "none"), deixando
# "ssl_certificate ;" no arquivo — o que reprova "nginx -t". Idempotente e
# silenciosa se o arquivo nao existir.
_ssl_strip_empty_cert_directives() {
    local conf_file="$1"

    [[ -f "${conf_file}" ]] || return 0

    sed -i -E '/^[[:space:]]*ssl_certificate(_key)?[[:space:]]*;[[:space:]]*$/d' "${conf_file}"
}

# --- modo none ---------------------------------------------------------

_ssl_issue_none() {
    local domain="$1"
    msg_info "SSL_MODE=none — ${domain} servira somente HTTP. Nenhum certificado emitido."
    return 0
}

# ============================================================
# Renovacao
# ============================================================

ssl_renew() {
    local domain="${1:-${DOMAIN_NAME}}"
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
                nginx_proxy_reload
            else
                log_warn "Falha na renovacao de certificados"
                return 1
            fi
            ;;
        self-signed)
            msg_info "SSL_MODE=self-signed — regenerando o par autoassinado..."
            _ssl_issue_self_signed "${domain}"
            ;;
        manual)
            msg_info "SSL_MODE=manual — renovacao nao e automatica."
            msg_info "Substitua os arquivos e execute: cctl ssl issue"
            ;;
        none)
            msg_info "SSL_MODE=none — nada a renovar."
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

    echo -e "  Dominio:     ${CYAN}${domain}${RESET}"
    echo -e "  Modo SSL:    ${CYAN}${mode}${RESET}"

    if [[ "${mode}" == "none" ]]; then
        echo -e "  Certificado: ${DIM}(nenhum — SSL_MODE=none)${RESET}"
        return 0
    fi

    local cert_file=""
    case "${mode}" in
        letsencrypt)
            cert_file="${LETSENCRYPT_LIVE_DIR}/${domain}/fullchain.pem"
            ;;
        manual|self-signed)
            cert_file="${SSL_CERTS_DIR}/${domain}/fullchain.pem"
            ;;
        *)
            log_error "SSL_MODE invalido: ${mode}"
            return 1
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

    echo -e "  Certificado: ${cert_file}"
    echo -e "  Expira em:   ${YELLOW}${expiry}${RESET}"
}
