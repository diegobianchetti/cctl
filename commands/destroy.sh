#!/bin/bash
# commands/destroy.sh — Teardown completo da instancia (clear-all + remove diretorio)

cmd_destroy() {
    local project_name="${COMPOSE_PROJECT_NAME}"
    local instance_dir
    instance_dir=$(pwd)

    msg_danger "DESTROY: REMOCAO COMPLETA DA INSTANCIA!"
    echo -e "${YELLOW}Projeto:   ${CYAN}${project_name}${RESET}"
    echo -e "${YELLOW}Diretorio: ${CYAN}${instance_dir}${RESET}"
    echo ""
    echo -e "${RED}Alem de remover containers, volumes e configs, o diretorio sera APAGADO.${RESET}"
    echo ""

    read -rp "Digite exatamente o nome do projeto para confirmar: " confirmation
    echo ""

    if [[ "${confirmation}" != "${project_name}" ]]; then
        msg_error "Confirmacao falhou!"
        msg_warn "Operacao cancelada."
        return 1
    fi

    # Executa clear-all
    source "${CCTL_ROOT}/commands/clear-all.sh"
    cmd_clear-all

    # Remove o diretorio da instancia
    msg_step "DESTROY" "Removendo diretorio da instancia..."
    cd /tmp || exit 1

    if [[ -d "${instance_dir}" && "${instance_dir}" != "/" && "${instance_dir}" != "${HOME}" ]]; then
        sudo rm -rf "${instance_dir}"
        log_success "Diretorio ${instance_dir} removido"
    else
        log_warn "Diretorio nao removido por seguranca: ${instance_dir}"
    fi

    echo ""
    msg_success "Instancia ${project_name} destruida completamente."
}
