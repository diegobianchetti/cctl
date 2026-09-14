#!/bin/bash
# lib/core.sh — Bootstrap, parse args, dispatch, deteccao de contexto
# shellcheck disable=SC2034  # variáveis globais exportadas para uso via source em commands/ e lib/

# Versao do cctl
CCTL_VERSION="0.1.0"

# core_priv_run — executa rm/cp/install/mkdir/cat com sudo somente quando necessario.
#
# Contrato de argumentos: core_priv_run <op> [flags/args...] <target>
#   - <op> e sempre o primeiro argumento: rm, cp, install, mkdir ou cat.
#   - o TARGET/DESTINO e sempre o ULTIMO argumento da chamada (padrao de
#     cp/install/mkdir/rm — o caminho que sera efetivamente criado/alterado).
#   - para cp/install, a ORIGEM e o ultimo argumento nao-flag antes do
#     target (heuristica: percorre os argumentos entre a operacao e o
#     target, ignorando os que comecam com "-").
#
# Criterio de gravabilidade/legibilidade por operacao:
#   rm       : a permissao de remover vem do diretorio-pai, nao do arquivo
#              em si — testa sempre "dirname $target".
#   cp/install: verifica LEITURA da origem ("-r \"$src\"" — uma origem
#              ilegivel, ex. arquivo 0600 de root, exige sudo mesmo com
#              destino gravavel) E ESCRITA do destino (o proprio alvo se
#              ja existir, senao o diretorio-pai onde sera criado).
#   mkdir    : sobe pelos ancestrais ate achar o primeiro diretorio
#              existente e testa gravabilidade dele.
#   cat      : verifica apenas LEITURA do target (unico argumento) — usado
#              para ler arquivos restritos (ex. chave privada 0600 de root)
#              sem copiar/mover nada.
#
# Se alguma checagem indicar necessidade de privilegio, tenta `sudo -n`
# quando stdin nao e um terminal (ambiente nao-interativo); se falhar,
# reporta erro claro em vez de travar esperando senha. Em terminal
# interativo, usa `sudo` normal (pode pedir senha).
core_priv_run() {
    local op="${1:-}"
    local target="${*: -1}"
    local need_sudo=false

    case "${op}" in
        rm)
            local rm_dir
            rm_dir="$(dirname -- "${target}")"
            [[ -w "${rm_dir}" ]] || need_sudo=true
            ;;
        cp|install)
            local src="" i arg
            for (( i = 2; i < $#; i++ )); do
                arg="${!i}"
                [[ "${arg}" == -* ]] && continue
                src="${arg}"
            done

            if [[ -n "${src}" && ! -r "${src}" ]]; then
                need_sudo=true
            fi

            if [[ -e "${target}" ]]; then
                [[ -w "${target}" ]] || need_sudo=true
            else
                local dst_dir
                dst_dir="$(dirname -- "${target}")"
                [[ -w "${dst_dir}" ]] || need_sudo=true
            fi
            ;;
        mkdir)
            local check_path="${target}"
            while [[ ! -e "${check_path}" ]]; do
                check_path="$(dirname -- "${check_path}")"
            done
            [[ -w "${check_path}" ]] || need_sudo=true
            ;;
        cat)
            [[ -r "${target}" ]] || need_sudo=true
            ;;
        *)
            log_error "core_priv_run: operacao nao suportada: ${op}"
            return 2
            ;;
    esac

    if [[ "${need_sudo}" == "false" ]]; then
        "$@"
        return $?
    fi

    if [[ ! -t 0 ]]; then
        if sudo -n "$@"; then
            return 0
        fi
        log_error "Privilegio de root necessario para '${op} ... ${target}' e sudo nao-interativo (sudo -n) falhou. Configure sudo NOPASSWD para este usuario ou execute em uma sessao interativa."
        return 1
    fi

    sudo "$@"
}

# core_sudo_usable — sonda se sudo esta disponivel de forma nao-interativa
# (sudo -n true), sem executar nenhuma operacao real. Para chamadores que
# precisam decidir ANTES de chamar core_priv_run se ha um caminho
# privilegiado viavel — ex: lib/cron.sh, para decidir o fallback de crontab
# de usuario sem arriscar um prompt de senha preso num terminal
# interativo. Mantem o unico ponto de contato direto com o binario "sudo"
# concentrado neste arquivo.
core_sudo_usable() {
    sudo -n true 2>/dev/null
}

# Carrega todas as libs
core_bootstrap() {
    local lib_dir="${CCTL_ROOT}/lib"

    # Defaults globais (cctl.conf) — carregado antes das libs para que
    # variaveis como CCTL_REGISTRY estejam disponiveis a todas elas.
    if [[ -f "${CCTL_ROOT}/cctl.conf" ]]; then
        # shellcheck source=/dev/null
        source "${CCTL_ROOT}/cctl.conf"
    fi

    source "${lib_dir}/colors.sh"
    source "${lib_dir}/log.sh"
    source "${lib_dir}/env.sh"
    source "${lib_dir}/validate.sh"
    source "${lib_dir}/network.sh"
    source "${lib_dir}/compose.sh"
    source "${lib_dir}/registry.sh"
    source "${lib_dir}/volumes.sh"
    source "${lib_dir}/passwords.sh"
    source "${lib_dir}/database.sh"
    source "${lib_dir}/nginx.sh"
    source "${lib_dir}/vhost.sh"
    source "${lib_dir}/rollout.sh"
    source "${lib_dir}/ssl.sh"
    source "${lib_dir}/cron.sh"
    source "${lib_dir}/backup.sh"
}

# Detecta o contexto de execucao
# Seta CCTL_CONTEXT para: "instance", "project", "template" ou "unknown"
core_detect_context() {
    if [[ -f "./.cctl-instance" ]]; then
        CCTL_CONTEXT="instance"
        CCTL_INSTANCE_DIR="$(pwd)"
    elif [[ -f "./project.conf" ]]; then
        CCTL_CONTEXT="project"
    elif [[ -d "${CCTL_ROOT}/templates" ]]; then
        CCTL_CONTEXT="template"
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
            # Repo de templates: apenas init, help, proxy e paths (gerenciamento
            # global — paths e diagnostico, mesmo motivo de proxy estar aqui)
            case "${cmd}" in
                init|help|proxy|paths) return 0 ;;
                *)
                    msg_error "Comando '${cmd}' requer uma instancia instalada."
                    msg_info "Use 'cctl init' para criar uma nova instancia ou acesse o diretorio de uma instancia existente."
                    return 1
                    ;;
            esac
            ;;
        project)
            # Diretorio de projeto pre-install: install, ssl, help, proxy e
            # paths (gerenciamento global — paths e diagnostico, mesmo motivo
            # de proxy estar aqui)
            case "${cmd}" in
                install|ssl|help|proxy|paths) return 0 ;;
                *)
                    msg_error "Comando '${cmd}' nao disponivel. Esta instancia ainda nao foi instalada."
                    msg_info "Execute 'cctl install' para instalar."
                    return 1
                    ;;
            esac
            ;;
        *)
            # Contexto desconhecido: apenas init, help, proxy e paths (gerenciamento global)
            case "${cmd}" in
                init|help|proxy|paths) return 0 ;;
                *)
                    msg_error "Diretorio atual nao e um contexto valido do cctl."
                    msg_info "Use 'cctl init' para criar um novo projeto ou acesse o diretorio de uma instancia instalada."
                    return 1
                    ;;
            esac
            ;;
    esac
}

# Carrega o manifest (project.conf) se disponivel
core_load_manifest() {
    local manifest=""

    if [[ "${CCTL_CONTEXT}" == "instance" || "${CCTL_CONTEXT}" == "project" ]]; then
        manifest="./project.conf"
    fi

    if [[ -n "${manifest}" && -f "${manifest}" ]]; then
        set -a
        # shellcheck source=/dev/null
        source "${manifest}"
        set +a
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

    # shellcheck source=/dev/null
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
