#!/bin/bash
# commands/update.sh — Pull de imagens e recria containers
#
# Como o "up", garante a rede do projeto antes de recriar os containers.

cmd_update() {
    compose_pull
    network_ensure_for_up || return 1
    compose_up --force-recreate "$@"
    log_success "Ambiente atualizado"
}
