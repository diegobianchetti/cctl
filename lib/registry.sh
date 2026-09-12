#!/bin/bash
# lib/registry.sh — Autenticacao e push de imagens para registries OCI
#
# Nunca ecoar/logar token: o valor so passa pelo stdin de `docker login`
# (--password-stdin), nunca como argumento de linha de comando.

# Resolve o registry efetivo (parametro > CCTL_REGISTRY > ghcr.io/DOCKER_OWNER).
# Atencao: o valor retornado pode incluir um namespace/path (ex:
# "ghcr.io/acme") — para operacoes que exigem apenas o host (docker login,
# lookup em ~/.docker/config.json) use registry_host().
registry_effective() {
    local override="${1:-}"

    if [[ -n "${override}" ]]; then
        echo "${override}"
        return 0
    fi

    if [[ -n "${CCTL_REGISTRY:-}" ]]; then
        echo "${CCTL_REGISTRY}"
        return 0
    fi

    if [[ -n "${DOCKER_OWNER:-}" ]]; then
        echo "ghcr.io/${DOCKER_OWNER}"
    else
        echo "ghcr.io"
    fi
}

# Extrai apenas o host de um valor de registry (que pode vir com namespace,
# ex: "ghcr.io/acme" -> "ghcr.io"). E o que `docker login` espera como
# argumento SERVER e a chave usada em ~/.docker/config.json#auths.
registry_host() {
    local registry="$1"
    echo "${registry%%/*}"
}

# Monta a referencia completa de imagem para um servico. O repositorio
# (registry + projeto + servico) e sanitizado em minusculas (exigencia de
# registries OCI); a TAG e preservada exatamente como informada, pois tags
# OCI sao case-sensitive (ex: "V1.0" != "v1.0").
# Uso: registry_image_ref <servico> [tag] [registry]
registry_image_ref() {
    local service="$1"
    local tag="${2:-latest}"
    local registry
    registry="$(registry_effective "${3:-}")"

    if ! validate_service_name "${service}"; then
        return 1
    fi
    if ! validate_image_tag "${tag}"; then
        return 1
    fi

    local project="${COMPOSE_PROJECT_NAME:-cctl}"
    local repo="${registry}/${project}-${service}"
    repo="$(echo "${repo}" | tr '[:upper:]' '[:lower:]')"

    echo "${repo}:${tag}"
}

# Verifica se ja existe sessao autenticada para o registry (pelo HOST, nunca
# pelo namespace de imagem) em ~/.docker/config.json.
#
# Limitacoes (sem parser JSON em bash puro):
# - O grep de string fixa "<host>": varre o arquivo inteiro, nao so o bloco
#   "auths" — uma chave "<host>": dentro de outro bloco (ex: "credHelpers")
#   tambem casa e e tratada como sessao valida. Na pratica isso raramente
#   importa (se o host aparece em credHelpers normalmente tambem esta ou
#   estara em auths), mas o comentario nao deve prometer um escopo que o
#   grep nao respeita. JSON minificado/reformatado de forma incomum tambem
#   pode nao casar.
# - Quando o config.json usa "credsStore"/"credHelpers" (credenciais geridas
#   por um helper externo — keychain, pass, etc.), o host autenticado nao
#   aparece em "auths" e nao ha como consultar o helper em bash puro. Nesse
#   caso degradamos: assumimos que pode haver sessao e deixamos a tentativa
#   de push prosseguir — se nao houver sessao de fato, o proprio `docker
#   push`/`docker login` vai falhar com o erro autentico do Docker.
_registry_has_session() {
    local registry="$1"
    local host
    host="$(registry_host "${registry}")"
    local config_file="${HOME}/.docker/config.json"

    [[ -f "${config_file}" ]] || return 1

    if grep -qF "\"${host}\":" "${config_file}" 2>/dev/null; then
        return 0
    fi

    if grep -qF '"credsStore"' "${config_file}" 2>/dev/null \
        || grep -qF '"credHelpers"' "${config_file}" 2>/dev/null; then
        log_debug "config.json usa credsStore/credHelpers — nao e possivel confirmar sessao para '${host}' sem invocar o helper externo; permitindo tentativa de push."
        return 0
    fi

    return 1
}

# Autentica no registry via `docker login --password-stdin`.
# Le o token de CCTL_REGISTRY_TOKEN / GHCR_TOKEN / DOCKER_TOKEN, nessa ordem.
# Sem token no ambiente, reaproveita sessao existente se houver; caso
# contrario, erro claro (nunca tenta login sem credenciais).
# `registry` pode vir com namespace (ex: ghcr.io/acme) — o login e feito
# sempre contra o HOST, que e o que o Docker exige e o que fica gravado em
# ~/.docker/config.json.
registry_login() {
    local registry="$1"
    local host
    host="$(registry_host "${registry}")"
    local token="${CCTL_REGISTRY_TOKEN:-${GHCR_TOKEN:-${DOCKER_TOKEN:-}}}"
    local user="${CCTL_REGISTRY_USER:-}"

    if [[ -z "${token}" ]]; then
        if _registry_has_session "${registry}"; then
            log_debug "Sem token de registry no ambiente — reaproveitando sessao existente em ~/.docker/config.json"
            return 0
        fi
        log_error "Push requer autenticacao: defina CCTL_REGISTRY_TOKEN (ou GHCR_TOKEN/DOCKER_TOKEN) e CCTL_REGISTRY_USER, ou execute 'docker login ${host}' manualmente antes de usar --push."
        return 1
    fi

    if [[ -z "${user}" ]]; then
        log_error "CCTL_REGISTRY_USER nao definido — necessario para autenticar em ${host}."
        return 1
    fi

    msg_step "REGISTRY" "Autenticando em ${host}..."

    # Hardening: garante que um `bash -x` externo nao exponha o token no
    # trace do pipeline de login — desliga xtrace localmente e restaura o
    # estado original de `$-` ao sair da funcao, sem afetar o restante do
    # script.
    local restore_xtrace=""
    case "$-" in
        *x*) restore_xtrace="set -x" ;;
    esac
    set +x

    local login_rc=0
    printf '%s' "${token}" | docker login "${host}" --username "${user}" --password-stdin >/dev/null || login_rc=$?

    ${restore_xtrace}

    if [[ ${login_rc} -ne 0 ]]; then
        log_error "Falha ao autenticar em ${host}."
        return 1
    fi
    log_success "Autenticado em ${host}"
}

# Envia uma imagem ja construida/taggeada (referencia completa, com
# registry+namespace) para o registry.
registry_push() {
    local image="$1"

    msg_step "PUSH" "Enviando ${image}..."
    if ! docker push "${image}"; then
        log_error "Falha ao enviar ${image} para o registry."
        return 1
    fi
    log_success "Imagem enviada: ${image}"
}

# Encerra a sessao autenticada no registry (limpeza opcional). Usa o HOST,
# como registry_login.
registry_logout() {
    local registry="$1"
    local host
    host="$(registry_host "${registry}")"
    docker logout "${host}" >/dev/null 2>&1 || true
}
