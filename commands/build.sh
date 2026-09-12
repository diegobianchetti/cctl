#!/bin/bash
# commands/build.sh — Build/rebuild de imagens locais e ciclo de customizacao/push
#
# Convencao de build customizado: docker/custom/<servico>/Dockerfile (contexto
# = mesmo diretorio). Override do diretorio base via CUSTOM_BUILD_DIR.

cmd_build() {
    local services=()
    local no_cache=false
    local pull=false
    local tag=""
    local custom_service=""
    local do_push=false
    local registry_override=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --help|-h)
                _build_usage
                return 0
                ;;
            --no-cache)
                no_cache=true
                shift
                ;;
            --pull)
                pull=true
                shift
                ;;
            -t|--tag)
                if [[ -z "${2:-}" ]]; then
                    log_error "Opcao '$1' requer um valor."
                    _build_usage
                    return 1
                fi
                tag="$2"
                shift 2
                ;;
            --custom)
                if [[ -z "${2:-}" ]]; then
                    log_error "Opcao '--custom' requer o nome de um servico."
                    _build_usage
                    return 1
                fi
                custom_service="$2"
                shift 2
                ;;
            --push)
                do_push=true
                shift
                ;;
            --registry)
                if [[ -z "${2:-}" ]]; then
                    log_error "Opcao '--registry' requer uma URL."
                    _build_usage
                    return 1
                fi
                registry_override="$2"
                shift 2
                ;;
            -*)
                log_error "Opcao desconhecida: $1"
                _build_usage
                return 1
                ;;
            *)
                services+=("$1")
                shift
                ;;
        esac
    done

    if [[ -n "${custom_service}" && ${#services[@]} -gt 0 ]]; then
        log_error "Nao e possivel combinar '--custom' com servicos posicionais (${services[*]}). Use um ou outro."
        return 1
    fi

    if [[ -n "${tag}" ]] && ! validate_image_tag "${tag}"; then
        return 1
    fi

    local svc
    for svc in "${services[@]}"; do
        validate_service_name "${svc}" || return 1
    done

    local registry
    registry="$(registry_effective "${registry_override}")"

    local build_flags=()
    [[ "${no_cache}" == "true" ]] && build_flags+=("--no-cache")
    [[ "${pull}" == "true" ]] && build_flags+=("--pull")

    local built_images=()

    if [[ -n "${custom_service}" ]]; then
        local custom_ref
        _build_custom "${custom_service}" "${tag}" "${registry}" custom_ref "${build_flags[@]}" || return 1
        built_images+=("${custom_ref}")
    else
        if [[ ${#services[@]} -gt 0 ]]; then
            local exists_rc
            for svc in "${services[@]}"; do
                exists_rc=0
                compose_service_exists "${svc}" || exists_rc=$?
                if [[ ${exists_rc} -eq 2 ]]; then
                    return 1
                elif [[ ${exists_rc} -ne 0 ]]; then
                    local available
                    available="$(compose_list_services | tr '\n' ' ')"
                    log_error "Servico '${svc}' nao existe no compose deste projeto. Disponiveis: ${available}"
                    return 1
                fi
            done
            compose_build_service services "${build_flags[@]}" || return 1
        else
            compose_build "${build_flags[@]}" || return 1
        fi

        # Alvo(s) a considerar para retag/push: os servicos informados
        # explicitamente pelo usuario (ja validados acima), ou — quando
        # nenhum foi passado — apenas os servicos com contexto de build
        # (`build:`) no compose. Nunca todos os servicos: um servico so com
        # `image:` (ex: postgres:16) nao e nosso para retaguear/publicar.
        local targets=("${services[@]}")
        if [[ ${#targets[@]} -eq 0 && ( -n "${tag}" || "${do_push}" == "true" ) ]]; then
            local targets_raw
            targets_raw="$(compose_buildable_services)" || { log_error "Falha ao resolver servicos buildaveis"; return 1; }
            while IFS= read -r svc; do
                [[ -n "${svc}" ]] && targets+=("${svc}")
            done <<< "${targets_raw}"

            if [[ ${#targets[@]} -eq 0 ]]; then
                log_warn "Nenhum servico com contexto de build encontrado no compose."
            fi
        fi

        if [[ -n "${tag}" || "${do_push}" == "true" ]]; then
            # Mesmo sem --tag, o push sempre usa a referencia qualificada
            # pelo registry (--registry precisa valer independente de
            # --tag) — nunca a imagem crua do compose (ex: "app:latest"),
            # que iria parar no Docker Hub em vez do registry configurado.
            local eff_tag="${tag:-latest}"
            local src_image ref
            for svc in "${targets[@]}"; do
                src_image="$(compose_service_image "${svc}")"
                if [[ -z "${src_image}" ]]; then
                    log_error "Nao foi possivel resolver a imagem do servico '${svc}' apos o build."
                    return 1
                fi
                ref="$(registry_image_ref "${svc}" "${eff_tag}" "${registry}")" || return 1
                if ! docker tag "${src_image}" "${ref}"; then
                    log_error "Falha ao aplicar a tag '${ref}' na imagem de '${svc}'."
                    return 1
                fi
                log_success "Tag aplicada: ${ref}"
                built_images+=("${ref}")
            done
        fi
    fi

    if [[ "${do_push}" == "true" ]]; then
        if [[ ${#built_images[@]} -eq 0 ]]; then
            log_error "Nada para publicar: nenhuma imagem foi construida/taggeada."
            return 1
        fi

        registry_login "${registry}" || return 1

        local img
        for img in "${built_images[@]}"; do
            registry_push "${img}" || return 1
        done
    fi

    return 0
}

# Build de Dockerfile customizado do projeto: docker/custom/<servico>/Dockerfile
# (override do diretorio base via CUSTOM_BUILD_DIR). Em sucesso, devolve a
# referencia final da imagem construida via nameref (4o argumento) — nunca
# por stdout: com o builder legado (DOCKER_BUILDKIT=0 ou Docker < 23) o
# `docker build` escreve o progresso em stdout, o que contaminaria uma
# captura via command substitution. Mensagens informativas vao para stderr.
# Uso: _build_custom <servico> <tag> <registry> <nome-da-var-de-saida> [flags...]
_build_custom() {
    local service="$1"
    local tag="$2"
    local registry="$3"
    local -n _bc_out_ref="$4"
    shift 4
    local extra_args=("$@")

    if ! validate_service_name "${service}"; then
        return 1
    fi

    local base_dir="${CUSTOM_BUILD_DIR:-docker/custom}"
    local ctx_dir="${base_dir}/${service}"
    local dockerfile="${ctx_dir}/Dockerfile"

    if [[ ! -f "${dockerfile}" ]]; then
        log_error "Dockerfile customizado nao encontrado: ${dockerfile}" >&2
        msg_info "Convencao esperada: ${base_dir}/<servico>/Dockerfile (override via CUSTOM_BUILD_DIR)." >&2
        return 1
    fi

    local ref
    ref="$(registry_image_ref "${service}" "${tag:-latest}" "${registry}")" || return 1

    msg_step "BUILD" "Build customizado: ${service} (${dockerfile})" >&2
    if ! docker build "${extra_args[@]}" -t "${ref}" -f "${dockerfile}" "${ctx_dir}"; then
        log_error "Falha no build customizado do servico '${service}'." >&2
        return 1
    fi
    log_success "Build customizado concluido: ${ref}" >&2

    _bc_out_ref="${ref}"
}

_build_usage() {
    echo "Uso: cctl build [servico...] [opcoes]"
    echo ""
    echo "  (sem argumentos)         Compila todas as imagens com 'build:' no compose"
    echo "  <servico> [servicos...]  Compila apenas os servicos indicados"
    echo "  --no-cache               Repassa --no-cache ao docker compose build"
    echo "  --pull                   Repassa --pull (atualiza imagens base)"
    echo "  -t, --tag <tag>          Aplica tag customizada as imagens construidas"
    echo "  --custom <servico>       Build via Dockerfile customizado do projeto"
    echo "                           (docker/custom/<servico>/Dockerfile, ou"
    echo "                           CUSTOM_BUILD_DIR/<servico>/Dockerfile)"
    echo "  --push                   Publica as imagens construidas no registry"
    echo "  --registry <url>         Sobrescreve o registry alvo (default:"
    echo "                           \$CCTL_REGISTRY ou ghcr.io/\$DOCKER_OWNER)"
    echo "  --help, -h               Exibe esta ajuda"
    echo ""
    echo "Credenciais de push: CCTL_REGISTRY_USER + CCTL_REGISTRY_TOKEN (ou"
    echo "GHCR_TOKEN/DOCKER_TOKEN). Nunca passe o token como argumento."
}
