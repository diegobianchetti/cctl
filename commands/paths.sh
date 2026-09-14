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
