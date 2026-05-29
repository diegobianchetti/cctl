#!/bin/bash
# commands/logs.sh — Exibe logs dos containers
#
# Uso:
#   cctl logs          — últimas 50 linhas de todos os containers
#   cctl logs -N       — últimas N linhas (ex: cctl logs -100)
#   cctl logs -f       — segue os logs em tempo real (tail -f)
#   cctl logs -f -N    — segue a partir das últimas N linhas
#   cctl logs <svc>    — logs de um serviço específico

cmd_logs() {
    local follow=false
    local tail_lines=50
    local extra_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f|--follow)
                follow=true
                shift
                ;;
            -[0-9]*)
                tail_lines="${1#-}"
                shift
                ;;
            --tail)
                tail_lines="${2:-50}"
                shift 2
                ;;
            *)
                extra_args+=("$1")
                shift
                ;;
        esac
    done

    local log_args=("--tail" "${tail_lines}")
    [[ "${follow}" == "true" ]] && log_args+=("-f")

    compose_logs "${log_args[@]}" "${extra_args[@]}"
}
