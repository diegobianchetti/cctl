#!/bin/bash
# commands/update.sh — Pull de imagens e recria containers

cmd_update() {
    compose_pull
    compose_up --force-recreate "$@"
    log_success "Ambiente atualizado"
}
