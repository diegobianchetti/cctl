#!/bin/bash
# commands/paths.sh — Diagnostico das raizes efetivas do cctl
#
# CCTL_BASE_DIR (default /opt/cctl) e a raiz unica de onde derivam as demais
# (ver cctl.conf). CRON_DIR/LOGROTATE_DIR sao fixos de proposito (cron e
# logrotate leem de caminho fixo do sistema, root-owned) e nao derivam dela.
# Comando de diagnostico global: roda em qualquer contexto (init|help|proxy|
# paths na allowlist de contexto desconhecido, ver lib/core.sh).

cmd_paths() {
    msg_header "Caminhos efetivos do cctl"
    echo ""
    echo -e "  CCTL_BASE_DIR: ${CYAN}${CCTL_BASE_DIR}${RESET}"
    echo -e "  ${DIM}Sobrescreva exportando CCTL_BASE_DIR antes de rodar o cctl (ex.: CCTL_BASE_DIR=/var/containers cctl proxy up).${RESET}"
    echo -e "  ${DIM}Cada raiz abaixo tambem aceita override individual (a variavel do nome correspondente).${RESET}"
    echo ""

    local -a _paths_derived=(
        "CCTL_INSTANCE_BASE_DIR"
        "CCTL_INVENTORY_DIR"
        "NGINX_VHOSTS_DIR"
        "LETSENCRYPT_DIR"
        "LETSENCRYPT_LIVE_DIR"
    )
    local -a _paths_fixed=(
        "CRON_DIR"
        "LOGROTATE_DIR"
    )

    echo -e "  ${BOLD}Derivadas de CCTL_BASE_DIR:${RESET}"
    _paths_print "${_paths_derived[@]}"
    echo ""
    echo -e "  ${BOLD}Fixas (nao derivam de CCTL_BASE_DIR — cron/logrotate leem caminho fixo do sistema):${RESET}"
    _paths_print "${_paths_fixed[@]}"
    echo ""
    _paths_print_networks
}

# Rede de cada instancia do inventario e divergencias entre o inventario e o
# Docker. So mostra; nunca apaga nada (limpar e decisao do operador:
# "docker network rm <rede>" para uma orfa, "cctl up" para recriar uma que
# sumiu).
_paths_print_networks() {
    echo -e "  ${BOLD}Rede das instalacoes:${RESET}"
    echo -e "  ${DIM}Faixa do cctl: CCTL_NETWORK_RANGE=${CCTL_NETWORK_RANGE} (prefixo /${CCTL_NETWORK_PREFIX})${RESET}"

    if ! docker network ls -q >/dev/null 2>&1; then
        echo -e "    ${YELLOW}Docker indisponivel — redes nao verificadas.${RESET}"
        return 0
    fi

    local kind project net subnet actual_owner registered_subnet found=0 divergences=0
    while IFS=$'\t' read -r kind project net subnet actual_owner registered_subnet; do
        [[ -n "${kind}" ]] || continue
        found=$((found + 1))
        case "${kind}" in
            OK)
                printf "    %-28s %-30s %s\n" "${project}" "${net}" "${subnet}"
                ;;
            DIVERGENT)
                divergences=$((divergences + 1))
                printf "    ${YELLOW}%-28s %-30s %s — DIVERGENCIA: Docker tem dono '%s' e subnet %s; inventario registra dono '%s' e subnet %s${RESET}\n" \
                    "${project}" "${net}" "${subnet}" "${actual_owner}" "${subnet}" "${project}" "${registered_subnet}"
                ;;
            MISSING)
                divergences=$((divergences + 1))
                printf "    ${YELLOW}%-28s %-30s %s — DIVERGENCIA: a rede nao existe (rode 'cctl up' na instancia para recria-la)${RESET}\n" \
                    "${project}" "${net}" "${subnet}"
                ;;
            NONE)
                divergences=$((divergences + 1))
                printf "    ${YELLOW}%-28s — DIVERGENCIA: instalada sem rede registrada (versao antiga do cctl; reinstale)${RESET}\n" "${project}"
                ;;
            NOPROJECT)
                divergences=$((divergences + 1))
                printf "    ${YELLOW}%-28s %-30s %s — DIVERGENCIA: rede gerenciada sem projeto (sem o label io.cctl.project; se nao for mais usada: docker network rm %s)${RESET}\n" \
                    "-" "${net}" "${subnet}" "${net}"
                ;;
            ORPHAN)
                divergences=$((divergences + 1))
                printf "    ${YELLOW}%-28s %-30s %s — DIVERGENCIA: rede do cctl sem instancia no inventario (se nao for mais usada: docker network rm %s)${RESET}\n" \
                    "${project}" "${net}" "${subnet}" "${net}"
                ;;
        esac
    done < <(network_audit_lines)

    if [[ ${found} -eq 0 ]]; then
        echo -e "    ${DIM}Nenhuma rede de instalacao registrada.${RESET}"
    elif [[ ${divergences} -eq 0 ]]; then
        echo -e "    ${GREEN}Sem divergencias.${RESET}"
    fi
}

# Imprime nome, valor efetivo e status (existe/gravavel) de cada variavel de
# caminho passada por nome (nao por valor — usa indireta "${!name}").
_paths_print() {
    local name value status
    for name in "$@"; do
        value="${!name}"
        if [[ -d "${value}" ]]; then
            if [[ -w "${value}" ]]; then
                status="${GREEN}existe, gravavel${RESET}"
            else
                status="${YELLOW}existe, somente leitura${RESET}"
            fi
        else
            status="${DIM}nao existe${RESET}"
        fi
        printf "    %-22s %-38s %b\n" "${name}" "${value}" "${status}"
    done
}
