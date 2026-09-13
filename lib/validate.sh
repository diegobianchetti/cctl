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

# Verifica se o DNS do dominio resolve. Usa `host`; na ausencia dele, cai
# para `getent hosts` e depois `nslookup`. Sem nenhuma das tres ferramentas,
# apenas avisa e deixa passar (nao bloqueia o preflight por causa do ambiente).
validate_dns() {
    local domain="$1"

    # Pula validacao para dominios locais
    case "${domain}" in
        localhost|*.local|*.test) return 0 ;;
    esac

    local resolved=false

    if command -v host &>/dev/null; then
        host "${domain}" &>/dev/null && resolved=true
    elif command -v getent &>/dev/null; then
        getent hosts "${domain}" &>/dev/null && resolved=true
    elif command -v nslookup &>/dev/null; then
        nslookup "${domain}" &>/dev/null && resolved=true
    else
        log_warn "Nenhuma ferramenta de resolucao DNS disponivel (host/getent/nslookup) — pulando validacao de ${domain}"
        return 0
    fi

    if [[ "${resolved}" != "true" ]]; then
        log_warn "DNS do dominio '${domain}' nao resolve. Verifique a configuracao."
        return 1
    fi

    log_debug "DNS OK: ${domain}"
    return 0
}

# Valida o nome do projeto: whitelist estrita para evitar path traversal
# (../), quebra do sed usado nos placeholders (| ou &) e nomes ilegais para
# Docker/Nginx (compose project name, nome de container, vhost).
validate_project_name() {
    local name="$1"

    if [[ -z "${name}" ]]; then
        log_error "Nome do projeto nao pode ser vazio."
        return 1
    fi

    if [[ ! "${name}" =~ ^[a-z0-9][a-z0-9_-]{1,62}$ ]]; then
        log_error "Nome de projeto invalido: '${name}'. Use apenas minusculas, digitos, '-' e '_', comecando com letra/digito (2 a 63 caracteres)."
        return 1
    fi

    return 0
}

# Valida tag de imagem de acordo com o charset aceito por registries OCI
# (docker/distribution): letras, digitos, '_', '.', '-', ate 128 caracteres,
# nao pode comecar com '.' ou '-'.
validate_image_tag() {
    local tag="$1"

    if [[ -z "${tag}" ]]; then
        log_error "Tag de imagem nao pode ser vazia."
        return 1
    fi

    if [[ ! "${tag}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]]; then
        log_error "Tag de imagem invalida: '${tag}'. Use apenas letras, digitos, '.', '_' e '-', comecando com letra/digito/underscore (ate 128 caracteres)."
        return 1
    fi

    return 0
}

# Valida nome de servico (usado para compor a referencia de imagem e para
# argumentos posicionais de `cctl build`). Mesmo charset de validate_image_tag
# por seguranca/consistencia (evita path traversal e quebra de referencia
# "registry/projeto-servico:tag").
validate_service_name() {
    local name="$1"

    if [[ -z "${name}" ]]; then
        log_error "Nome de servico nao pode ser vazio."
        return 1
    fi

    if [[ ! "${name}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]]; then
        log_error "Nome de servico invalido: '${name}'. Use apenas letras, digitos, '.', '_' e '-', comecando com letra/digito/underscore (ate 128 caracteres)."
        return 1
    fi

    return 0
}

# Valida referencia de imagem completa (registry/repositorio:tag ou @digest),
# usada por `cctl rollout --image`. Mais permissiva que validate_image_tag
# (aceita '/' de registry/repositorio e ':' de porta/tag/digest), mas
# restrita a um charset seguro — rejeita espacos, quebras de linha e
# qualquer caractere que pudesse escapar do contexto YAML do override de
# compose gerado em runtime (ver _rollout_bring_up_candidate).
validate_image_ref() {
    local ref="$1"

    if [[ -z "${ref}" ]]; then
        log_error "Referencia de imagem nao pode ser vazia."
        return 1
    fi

    if [[ ${#ref} -gt 255 ]]; then
        log_error "Referencia de imagem muito longa (max 255 caracteres): '${ref}'."
        return 1
    fi

    if [[ ! "${ref}" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]]; then
        log_error "Referencia de imagem invalida: '${ref}'. Use apenas letras, digitos, '.', '_', '-', '/', ':' e '@' (sem espacos ou quebras de linha)."
        return 1
    fi

    return 0
}

# Valida o path de healthcheck HTTP (`cctl rollout --health-path`): deve
# comecar com '/' e nao pode conter espacos/quebras de linha (evita montar
# uma URL de sonda quebrada ou injetar conteudo na chamada de curl/wget).
validate_health_path() {
    local path="$1"

    if [[ "${path}" != /* ]]; then
        log_error "--health-path invalido: '${path}' (deve comecar com '/')."
        return 1
    fi

    if [[ "${path}" == *' '* || "${path}" == *$'\n'* || "${path}" == *$'\t'* ]]; then
        log_error "--health-path invalido: '${path}' (contem espaco ou quebra de linha)."
        return 1
    fi

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
        elif [[ "${SSL_MODE:-letsencrypt}" == "letsencrypt" ]]; then
            log_error "DNS de '${DOMAIN_NAME}' nao resolve — obrigatorio para SSL_MODE=letsencrypt (desafio ACME)."
            ((errors++))
        else
            msg_warn "DNS de '${DOMAIN_NAME}' nao resolve — seguindo (SSL_MODE=${SSL_MODE:-letsencrypt} nao depende de DNS publico). O certificado/vhost so funcionara quando o nome resolver."
        fi
    fi

    if [[ ${errors} -gt 0 ]]; then
        log_error "${errors} verificacao(oes) falharam."
        return 1
    fi

    msg_success "Todas as verificacoes passaram."
    return 0
}
