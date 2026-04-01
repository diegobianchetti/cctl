#!/bin/bash
# commands/connect.sh — Abre shell no container do servico

cmd_connect() {
    if [[ "$#" -eq 0 ]]; then
        msg_error "Informe o servico para conectar."
        if [[ -n "${CONNECTABLE_SERVICES+x}" ]]; then
            msg_info "Servicos disponiveis: ${CONNECTABLE_SERVICES[*]}"
        fi
        return 1
    fi

    compose_connect "$@"
}
