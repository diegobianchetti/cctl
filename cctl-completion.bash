#!/bin/bash
# cctl-completion.bash — Autocomplete bash para o cctl
# shellcheck disable=SC2207  # COMPREPLY=( $(compgen -W ...) ) é o padrão idiomático de bash completion
#
# Instalacao (adicionar ao ~/.bashrc ou /etc/bash_completion.d/cctl):
#
#   source /caminho/do/repo/cctl-completion.bash
#
# Ou para instalar globalmente:
#
#   sudo cp cctl-completion.bash /etc/bash_completion.d/cctl
#   source /etc/bash_completion.d/cctl

_cctl_completions() {
    local cur prev
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD-1]}"

    # Todos os subcomandos
    local all_commands="init install up down start stop restart ps logs status
                        network volumes config connect build update backup list
                        db-check-config db-update-config clear-volumes clear-all
                        destroy help"

    # Opcoes globais
    local global_opts="--version --help --verbose -v -h"

    # Primeiro token apos cctl (ou ./cctl)
    local command=""
    local i
    for (( i=1; i < COMP_CWORD; i++ )); do
        local word="${COMP_WORDS[i]}"
        if [[ "${word}" != -* ]]; then
            command="${word}"
            break
        fi
    done

    # Completa subcomandos e opcoes globais
    if [[ -z "${command}" ]]; then
        COMPREPLY=( $(compgen -W "${all_commands} ${global_opts}" -- "${cur}") )
        return 0
    fi

    # Completa argumentos especificos por subcomando
    case "${command}" in
        init)
            # Conta argumentos posicionais ja informados (ignora flags)
            local pos_count=0
            local i
            for (( i=1; i < COMP_CWORD; i++ )); do
                [[ "${COMP_WORDS[i]}" != --* ]] && (( pos_count++ )) || true
            done

            case "${prev}" in
                --domain|--dest)
                    COMPREPLY=()
                    ;;
                *)
                    if (( pos_count == 0 )); then
                        # Primeiro posicional: tipo de template
                        local cctl_root
                        cctl_root="$(dirname "$(readlink -f "${COMP_WORDS[0]}")" 2>/dev/null)"
                        local templates=""
                        if [[ -d "${cctl_root}/templates" ]]; then
                            templates="$(ls -1 "${cctl_root}/templates/" 2>/dev/null | tr '\n' ' ')"
                        else
                            templates="dspace moodle"
                        fi
                        COMPREPLY=( $(compgen -W "${templates}" -- "${cur}") )
                    elif (( pos_count == 1 )); then
                        # Segundo posicional: nome do projeto (sem sugestoes)
                        COMPREPLY=()
                    else
                        COMPREPLY=( $(compgen -W "--domain --dest" -- "${cur}") )
                    fi
                    ;;
            esac
            ;;

        logs)
            # Sugere servicos do CONNECTABLE_SERVICES se project.conf existir
            local services
            services=$(_cctl_get_services)
            # -N: atalho para --tail N (ex: -50, -100, -200)
            local log_opts="-f -50 -100 -200 --tail --no-color"
            if [[ -n "${services}" ]]; then
                COMPREPLY=( $(compgen -W "${services} ${log_opts}" -- "${cur}") )
            else
                COMPREPLY=( $(compgen -W "${log_opts}" -- "${cur}") )
            fi
            ;;

        connect)
            local services
            services=$(_cctl_get_services)
            if [[ -n "${services}" ]]; then
                COMPREPLY=( $(compgen -W "${services}" -- "${cur}") )
            fi
            ;;

        backup)
            COMPREPLY=( $(compgen -W "--no-db --no-volumes" -- "${cur}") )
            ;;

        clear-volumes|clear-all|destroy)
            # Sem sugestoes (operacoes destrutivas pedem confirmacao)
            COMPREPLY=()
            ;;

        up|down|start|stop|restart|build|update)
            # Servicos opcionais
            local services
            services=$(_cctl_get_services)
            if [[ -n "${services}" ]]; then
                COMPREPLY=( $(compgen -W "${services}" -- "${cur}") )
            fi
            ;;

        *)
            COMPREPLY=()
            ;;
    esac

    return 0
}

# Retorna lista de servicos do project.conf atual (se disponivel)
_cctl_get_services() {
    local conf="./project.conf"
    if [[ ! -f "${conf}" ]]; then
        # Tenta encontrar no diretorio do script
        local cctl_root
        cctl_root="$(dirname "$(readlink -f "${COMP_WORDS[0]}")" 2>/dev/null)"
        conf="${cctl_root}/project.conf"
    fi

    if [[ -f "${conf}" ]]; then
        # Extrai CONNECTABLE_SERVICES do manifest
        local services
        services=$(bash -c "source '${conf}' 2>/dev/null; echo \"\${CONNECTABLE_SERVICES[*]:-}\"")
        echo "${services}"
    fi
}

# Registra o completion para cctl e ./cctl
complete -F _cctl_completions cctl
complete -F _cctl_completions ./cctl

# Sinaliza que o completion esta ativo (herdado por subprocessos via export)
export CCTL_COMPLETION_LOADED=1
