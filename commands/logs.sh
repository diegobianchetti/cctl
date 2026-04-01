#!/bin/bash
# commands/logs.sh — Exibe logs dos containers

cmd_logs() {
    # Se nenhum argumento, segue os logs com -f
    if [[ "$#" -eq 0 ]]; then
        compose_logs -f
    else
        compose_logs "$@"
    fi
}
