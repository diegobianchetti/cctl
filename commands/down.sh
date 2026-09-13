#!/bin/bash
# commands/down.sh — Remove containers e rede (mantem volumes)

cmd_down() {
    # Desconecta o nginx-proxy da rede do projeto ANTES do compose down: a
    # rede so pode ser removida quando nenhum endpoint (incluindo o proxy,
    # conectado por network_connect_nginx durante o install) permanece
    # ativo nela. Sem isso, "docker compose down" falha ao remover a rede
    # ("active endpoints") e a proxima instalacao reaproveita uma rede orfa.
    if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
        network_disconnect_project_networks "${COMPOSE_PROJECT_NAME}"
    fi

    compose_down "$@"
}
