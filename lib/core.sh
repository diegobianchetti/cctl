#!/bin/bash
# lib/core.sh — Bootstrap, parse args, dispatch, deteccao de contexto
# shellcheck disable=SC2034  # variáveis globais exportadas para uso via source em commands/ e lib/

# Versao do cctl
CCTL_VERSION="0.1.0"

# core_priv_run — executa rm/cp/install/mkdir/cat/test/ls/mv com sudo somente
# quando necessario.
#
# Contrato de argumentos: core_priv_run <op> [flags/args...] <target>.
# <op> e o primeiro argumento; TARGET/DESTINO e o ultimo. Para cp/install,
# a origem e o ultimo argumento nao-flag anterior ao destino.
#
# Criterio por operacao: rm/mv testam escrita no pai; cp/install exigem leitura
# da origem e escrita no destino; mkdir sobe ate o ancestral existente; cat le
# o alvo; ls exige leitura+travessia do diretorio. `test -f|-d` executa o
# predicado real; se precisar sudo, primeiro prova sua operabilidade e depois
# executa somente o mesmo test, sem abrir shell generico.
#
# O protocolo de `test` separa resultado logico de operacional: 0 = presente,
# 1 = ausente confirmado e 2 = sudo/test nao executou a consulta. Sem TTY usa
# sudo -n; com TTY usa sudo normal. No ramo direto, um symlink cujo alvo pode
# estar protegido escala para sudo. Risco residual aceito: sudoers restrito por
# comando que permita true e negue test pode parecer ausencia; isto fica fora
# do contrato pela D1, que exige usuario com sudo completo. Erro de `ls` pode
# ser do diretorio, filesystem ou sudo, portanto nao e atribuido so ao sudo.
_core_stdin_is_tty() {
    [[ -t 0 ]]
}

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
        test)
            # Sem travessia no pai, ou symlink que o teste direto nao conseguiu
            # resolver, a ausencia so pode ser confirmada pelo test privilegiado.
            if [[ ! -x "$(dirname -- "${target}")" ]]; then
                need_sudo=true
            elif "$@"; then
                return 0
            else
                local test_rc=$?
                [[ ${test_rc} -eq 1 && -L "${target}" ]] && need_sudo=true || return "${test_rc}"
            fi
            ;;
        ls)
            # Descobertas estritas precisam enumerar o diretorio de verdade.
            # Leitura e travessia sao ambas necessarias; sem uma delas, escala
            # para sudo em vez de converter o erro em uma lista vazia.
            [[ -r "${target}" && -x "${target}" ]] || need_sudo=true
            ;;
        mv)
            local mv_dir
            mv_dir="$(dirname -- "${target}")"
            [[ -w "${mv_dir}" ]] || need_sudo=true
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

    if [[ "${op}" == "test" ]]; then
        local sudo_rc
        if ! _core_stdin_is_tty; then
            sudo -n true || {
                log_error "Nao foi possivel operar sudo para consultar ${target}. Confira sudo, permissao e filesystem."
                return 2
            }
            sudo -n "$@"
        else
            sudo true || {
                log_error "Nao foi possivel operar sudo para consultar ${target}. Confira sudo, permissao e filesystem."
                return 2
            }
            sudo "$@"
        fi
        sudo_rc=$?
        [[ ${sudo_rc} -le 1 ]] && return "${sudo_rc}"
        return 2
    fi

    if ! _core_stdin_is_tty; then
        if sudo -n "$@"; then
            return 0
        fi
        log_error "Privilegio de root necessario para '${op} ... ${target}'; a consulta pode ter falhado por sudo, permissao ou filesystem."
        return 1
    fi

    sudo "$@"
}

# core_sudo_check — confere se o sudo funciona nesta sessao, sem executar
# nenhuma operacao real. Com terminal (stdin TTY) usa "sudo -v", que pode
# pedir a senha uma vez e a deixa em cache para as proximas chamadas; sem
# terminal usa "sudo -n true", que falha se exigir senha. Mantem o unico
# ponto de contato direto com o binario "sudo" concentrado neste arquivo.
core_sudo_check() {
    # root nao precisa de sudo (e o host pode nem ter o pacote sudo)
    [[ ${EUID} -eq 0 ]] && return 0
    if [[ -t 0 ]]; then
        sudo -v
    else
        sudo -n true 2>/dev/null
    fi
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
    source "${lib_dir}/inventory.sh"
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
            # Repo de templates: apenas init, help, proxy, paths e list
            # (gerenciamento global — list le so o inventario, nao precisa
            # de instancia/projeto no diretorio atual; mesmo motivo de
            # proxy/paths estarem aqui)
            case "${cmd}" in
                init|help|proxy|paths|list) return 0 ;;
                *)
                    msg_error "Comando '${cmd}' requer uma instancia instalada."
                    msg_info "Use 'cctl init' para criar uma nova instancia ou acesse o diretorio de uma instancia existente."
                    return 1
                    ;;
            esac
            ;;
        project)
            # Diretorio de projeto pre-install: install, ssl, help, proxy,
            # paths e list (gerenciamento global — mesmo motivo de
            # proxy/paths estarem aqui)
            case "${cmd}" in
                install|ssl|help|proxy|paths|list) return 0 ;;
                *)
                    msg_error "Comando '${cmd}' nao disponivel. Esta instancia ainda nao foi instalada."
                    msg_info "Execute 'cctl install' para instalar."
                    return 1
                    ;;
            esac
            ;;
        *)
            # Contexto desconhecido: apenas init, help, proxy, paths e list
            # (gerenciamento global)
            case "${cmd}" in
                init|help|proxy|paths|list) return 0 ;;
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

        # Manifest antigo: a faixa de rede deixou de ser definida por projeto.
        if [[ -n "${SUBNET_RANGE:-}" || -n "${SUBNET_PREFIX_LEN:-}" ]]; then
            log_warn "project.conf define SUBNET_RANGE/SUBNET_PREFIX_LEN, mas isso agora e ignorado: quem manda e o cctl.conf (CCTL_NETWORK_RANGE=${CCTL_NETWORK_RANGE:-?}, CCTL_NETWORK_PREFIX=${CCTL_NETWORK_PREFIX:-?}). Pode remover essas linhas do project.conf."
        fi
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
