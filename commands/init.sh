#!/bin/bash
# commands/init.sh — Inicializa diretorio de projeto a partir de um template
#
# Uso: cctl init <template> <nome> [--domain <dominio>] [--dest <caminho>]
#
# Fluxo:
#   1. Valida template e nome do projeto
#   2. Solicita destino (prompt interativo ou --dest)
#   3. Solicita dominio (prompt interativo ou --domain)
#   4. Cria diretorio e copia template
#   5. Gera .env e renderiza project.conf com dados nao-sensiveis
#   6. Gera vhost nginx de referencia (se dominio informado)

cmd_init() {
    local template_type=""
    local project_name=""
    local domain_name=""
    local dest_dir=""

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --domain)    shift; domain_name="${1:-}" ;;
            --domain=*)  domain_name="${1#*=}" ;;
            --dest)      shift; dest_dir="${1:-}" ;;
            --dest=*)    dest_dir="${1#*=}" ;;
            --help|-h)   _init_usage; return 0 ;;
            -*)
                msg_error "Opcao desconhecida: $1"
                _init_usage
                return 1
                ;;
            *)
                if [[ -z "${template_type}" ]]; then
                    template_type="$1"
                elif [[ -z "${project_name}" ]]; then
                    project_name="$1"
                else
                    msg_error "Argumento inesperado: $1"
                    _init_usage
                    return 1
                fi
                ;;
        esac
        shift
    done

    if [[ -z "${template_type}" || -z "${project_name}" ]]; then
        msg_error "Template e nome do projeto sao obrigatorios."
        _init_usage
        return 1
    fi

    local template_dir="${CCTL_ROOT}/templates/${template_type}"
    if [[ ! -d "${template_dir}" ]]; then
        msg_error "Template '${template_type}' nao encontrado."
        msg_info "Templates disponiveis:"
        ls -1 "${CCTL_ROOT}/templates/" 2>/dev/null | sed 's/^/  - /'
        return 1
    fi

    msg_header "Inicializando projeto: ${project_name}"
    echo -e "  Template: ${CYAN}${template_type}${RESET}"
    echo ""

    if [[ -z "${dest_dir}" ]]; then
        _init_ask_dest "${project_name}"
        dest_dir="${_INIT_DEST}"
    fi

    if [[ -z "${domain_name}" ]]; then
        _init_ask_domain
        domain_name="${_INIT_DOMAIN:-}"
    fi

    if [[ -d "${dest_dir}" ]]; then
        msg_error "Diretorio ja existe: ${dest_dir}"
        msg_info "Remova o diretorio ou escolha outro nome/destino."
        return 1
    fi

    echo ""
    echo -e "  Destino: ${CYAN}${dest_dir}${RESET}"
    if [[ -n "${domain_name}" ]]; then
        echo -e "  Dominio: ${CYAN}${domain_name}${RESET}"
    else
        echo -e "  Dominio: ${DIM}(definir depois no .env)${RESET}"
    fi
    echo ""

    # 1. Cria diretorio e copia template
    msg_step "1/3" "Copiando template ${template_type}..."
    mkdir -p "${dest_dir}"
    cp -r "${template_dir}"/. "${dest_dir}/"
    log_success "Template copiado para ${dest_dir}"

    # 2. Configura .env e project.conf
    msg_step "2/3" "Configurando .env e project.conf..."

    local env_file_rel env_template_rel
    env_file_rel=$(bash -c "source '${dest_dir}/project.conf' 2>/dev/null; echo \"\${ENV_FILE:-docker/.env}\"")
    env_template_rel=$(bash -c "source '${dest_dir}/project.conf' 2>/dev/null; echo \"\${ENV_TEMPLATE:-docker/.env.template}\"")

    local env_file="${dest_dir}/${env_file_rel}"
    local env_template="${dest_dir}/${env_template_rel}"

    if [[ -f "${env_template}" ]]; then
        mkdir -p "$(dirname "${env_file}")"
        cp "${env_template}" "${env_file}"
    fi

    _init_render_placeholders "${env_file}" "${project_name}" "${domain_name}"
    _init_render_placeholders "${dest_dir}/project.conf" "${project_name}" "${domain_name}"

    log_success ".env e project.conf configurados"

    # 3. Gera vhost de referencia (so se dominio informado)
    msg_step "3/3" "Gerando vhost de referencia..."
    if [[ -n "${domain_name}" && -f "${dest_dir}/nginx/site.conf.template" ]]; then
        sed \
            -e "s|{{DOMAIN_NAME}}|${domain_name}|g" \
            -e "s|{{COMPOSE_PROJECT_NAME}}|${project_name}|g" \
            "${dest_dir}/nginx/site.conf.template" \
            > "${dest_dir}/nginx/${project_name}.conf"
        log_success "Vhost gerado: nginx/${project_name}.conf"
    else
        log_debug "Vhost pulado (sem dominio ou sem site.conf.template)"
    fi

    echo ""
    msg_header "Projeto inicializado!"
    echo ""
    echo -e "  Diretorio: ${CYAN}${dest_dir}${RESET}"
    echo ""
    if [[ -z "${domain_name}" ]]; then
        msg_warn "DOMAIN_NAME nao definido — edite ${env_file_rel} antes de instalar."
        echo ""
    fi
    echo -e "  Proximo passo:"
    echo -e "    ${DIM}cd ${dest_dir}${RESET}"
    echo -e "    ${DIM}vi ${env_file_rel}${RESET}"
    echo -e "    ${DIM}cctl install${RESET}"
    echo ""
    log_success "Init concluido para ${project_name}!"
}

# Substitui _PLACEHOLDER_ no .env e project.conf
_init_render_placeholders() {
    local file="$1"
    local project_name="$2"
    local domain_name="$3"

    [[ -f "${file}" ]] || return 0

    sed -i \
        -e "s|_CLIENT_NAME_|${project_name}|g" \
        -e "s|_COMPOSE_PROJECT_NAME_|${project_name}|g" \
        "${file}"

    if [[ -n "${domain_name}" ]]; then
        sed -i -e "s|_DOMAIN_NAME_|${domain_name}|g" "${file}"
    fi
}

_init_ask_dest() {
    local project_name="$1"
    local opt1
    opt1="$(pwd)/${project_name}"
    local opt2="/opt/${project_name}"

    echo -e "${BOLD}Onde criar o diretorio do projeto?${RESET}"
    echo ""
    echo -e "  ${CYAN}1)${RESET} ${opt1}"
    echo -e "     (diretorio atual)"
    echo -e "  ${CYAN}2)${RESET} ${opt2}"
    echo -e "     (recomendado para producao)"
    echo -e "  ${CYAN}3)${RESET} Outro caminho"
    echo ""
    local choice
    read -rp "  Escolha [1]: " choice
    choice="${choice:-1}"

    case "${choice}" in
        1) _INIT_DEST="${opt1}" ;;
        2) _INIT_DEST="${opt2}" ;;
        3)
            echo ""
            read -rp "  Caminho completo: " _INIT_DEST
            _INIT_DEST="${_INIT_DEST%/}"
            ;;
        *) _INIT_DEST="${choice}" ;;
    esac
    echo ""
}

_init_ask_domain() {
    read -rp "  Dominio (Enter para definir depois no .env): " _INIT_DOMAIN
}

_init_usage() {
    echo ""
    echo "Uso: cctl init <template> <nome> [--domain <dominio>] [--dest <caminho>]"
    echo ""
    echo "Argumentos:"
    echo "  <template>          Tipo de projeto (ex: moodle, dspace)"
    echo "  <nome>              Nome unico do projeto (ex: moodle-acme)"
    echo ""
    echo "Opcoes:"
    echo "  --domain <dominio>  Dominio da instancia (ex: moodle.acme.example.br)"
    echo "  --dest <caminho>    Diretorio de destino completo (prompt se omitido)"
    echo ""
    echo "Exemplos:"
    echo "  cctl init moodle moodle-acme"
    echo "  cctl init moodle moodle-acme --domain moodle.acme.example.br"
    echo "  cctl init moodle moodle-acme --domain moodle.acme.example.br --dest /opt/moodle-acme"
    echo ""
    echo "Templates disponiveis:"
    ls -1 "${CCTL_ROOT}/templates/" 2>/dev/null | sed 's/^/  - /' || echo "  (nenhum)"
}
