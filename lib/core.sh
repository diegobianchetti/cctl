#!/bin/bash
# lib/core.sh — Bootstrap, parse args, dispatch, deteccao de contexto

# Versao do cctl
CCTL_VERSION="0.1.0"

# Carrega todas as libs
core_bootstrap() {
    local lib_dir="${CCTL_ROOT}/lib"

    source "${lib_dir}/colors.sh"
    source "${lib_dir}/log.sh"
    source "${lib_dir}/env.sh"
    source "${lib_dir}/validate.sh"
    source "${lib_dir}/network.sh"
    source "${lib_dir}/compose.sh"
    source "${lib_dir}/volumes.sh"
    source "${lib_dir}/passwords.sh"
    source "${lib_dir}/database.sh"
    source "${lib_dir}/nginx.sh"
    source "${lib_dir}/ssl.sh"
    source "${lib_dir}/cron.sh"
    source "${lib_dir}/backup.sh"
}

# Detecta o contexto de execucao
# Seta CCTL_CONTEXT para: "instance", "template", "client_branch" ou "unknown"
core_detect_context() {
    if [[ -f "./.cctl-instance" ]]; then
        CCTL_CONTEXT="instance"
        CCTL_INSTANCE_DIR="$(pwd)"
    elif [[ -d "${CCTL_ROOT}/templates" ]]; then
        CCTL_CONTEXT="template"
    elif [[ -f "./project.conf" && ! -f "./.cctl-instance" ]]; then
        CCTL_CONTEXT="client_branch"
    else
        CCTL_CONTEXT="unknown"
    fi
    export CCTL_CONTEXT
}

# Verifica se o comando e valido para o contexto atual
core_check_command_context() {
    local cmd="$1"

    case "${CCTL_CONTEXT}" in
        instance)
            # Instancia instalada: todos os comandos operacionais
            return 0
            ;;
        template)
            # Repo de templates: apenas init e help
            case "${cmd}" in
                init|help) return 0 ;;
                *)
                    msg_error "Comando '${cmd}' requer uma instancia instalada."
                    msg_info "Use 'cctl init' para criar uma nova instancia ou acesse o diretorio de uma instancia existente."
                    return 1
                    ;;
            esac
            ;;
        client_branch)
            # Branch de cliente pre-install: apenas install e help
            case "${cmd}" in
                install|help) return 0 ;;
                *)
                    msg_error "Comando '${cmd}' nao disponivel. Esta instancia ainda nao foi instalada."
                    msg_info "Execute 'cctl install' para instalar."
                    return 1
                    ;;
            esac
            ;;
        *)
            case "${cmd}" in
                help) return 0 ;;
                *)
                    msg_error "Diretorio atual nao e um contexto valido do cctl."
                    msg_info "Acesse o diretorio do repositorio containers-control ou de uma instancia instalada."
                    return 1
                    ;;
            esac
            ;;
    esac
}

# Carrega o manifest (project.conf) se disponivel
core_load_manifest() {
    local manifest=""

    if [[ "${CCTL_CONTEXT}" == "instance" || "${CCTL_CONTEXT}" == "client_branch" ]]; then
        manifest="./project.conf"
    fi

    if [[ -n "${manifest}" && -f "${manifest}" ]]; then
        source "${manifest}"
        log_debug "Manifest carregado: ${manifest} (PROJECT_TYPE=${PROJECT_TYPE:-?})"
    fi
}

# Dispatch: carrega e executa o comando
core_dispatch() {
    local cmd="$1"
    shift

    local cmd_file="${CCTL_ROOT}/commands/${cmd}.sh"

    if [[ ! -f "${cmd_file}" ]]; then
        msg_error "Comando desconhecido: '${cmd}'"
        msg_info "Use 'cctl help' para ver os comandos disponiveis."
        return 1
    fi

    source "${cmd_file}"

    if declare -f "cmd_${cmd}" > /dev/null 2>&1; then
        "cmd_${cmd}" "$@"
    else
        msg_error "Comando '${cmd}' nao implementa a funcao cmd_${cmd}()"
        return 1
    fi
}

# Parse de argumentos globais (antes do subcomando)
core_parse_global_args() {
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --version|-v)
                echo "cctl ${CCTL_VERSION}"
                exit 0
                ;;
            --help|-h)
                CCTL_COMMAND="help"
                return 0
                ;;
            --verbose)
                CCTL_VERBOSE=true
                shift
                ;;
            -*)
                msg_error "Opcao global desconhecida: $1"
                msg_info "Use 'cctl --help' para ver as opcoes disponiveis."
                exit 1
                ;;
            *)
                # Primeiro argumento nao-flag e o subcomando
                CCTL_COMMAND="$1"
                shift
                CCTL_ARGS=("$@")
                return 0
                ;;
        esac
    done

    # Nenhum comando informado
    CCTL_COMMAND="help"
}
