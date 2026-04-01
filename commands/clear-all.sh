#!/bin/bash
# commands/clear-all.sh — Remove tudo: containers, volumes, configs do host

cmd_clear-all() {
    local project_name="${COMPOSE_PROJECT_NAME}"

    msg_danger "ATENCAO: ESTA OPERACAO REMOVERA TODOS OS DADOS E A INSTALACAO DO PROJETO!"
    echo -e "${YELLOW}Projeto: ${CYAN}${project_name}${RESET}"
    echo -e "${YELLOW}Esta acao e irreversivel e inclui:${RESET}"
    echo "  - Todos os containers e volumes"
    echo "  - Configuracoes de rede"
    echo "  - Configuracoes do Nginx para ${DOMAIN_NAME:-?}"
    echo "  - Cron jobs do projeto"
    echo ""

    read -rp "Digite exatamente o nome do projeto para confirmar: " confirmation
    echo ""

    if [[ "${confirmation}" != "${project_name}" ]]; then
        msg_error "Confirmacao falhou!"
        msg_warn "Operacao cancelada."
        return 1
    fi

    # Etapa 1/6: Containers
    msg_step "ETAPA 1/6" "Parando e removendo containers..."
    if compose_exec down 2>/dev/null; then
        msg_success "Containers removidos"
    else
        msg_warn "Nenhum container em execucao encontrado"
    fi

    # Etapa 2/6: Volumes
    msg_step "ETAPA 2/6" "Removendo volumes..."
    local volumes
    volumes=$(docker volume ls -q --filter "name=${project_name}")
    if [[ -n "${volumes}" ]]; then
        echo -e "${BLUE}Volumes encontrados:${RESET}"
        echo "${volumes}" | sed 's/^/  - /'
        echo "${volumes}" | xargs -r sudo docker volume rm
        msg_success "Volumes removidos"
    else
        msg_info "Nenhum volume encontrado"
    fi

    # Etapa 3/6: Redes
    msg_step "ETAPA 3/6" "Limpando redes..."
    local project_networks
    project_networks=$(docker network ls --filter "name=${project_name}" --format "{{.Name}}")
    local net
    for net in ${project_networks}; do
        network_disconnect_nginx "${net}"
        if docker network rm "${net}" 2>/dev/null; then
            msg_success "Rede ${net} removida"
        else
            msg_warn "Rede ${net} ja removida"
        fi
    done

    # Etapa 4/6: Nginx compose config
    msg_step "ETAPA 4/6" "Atualizando configuracao do Nginx..."
    for net in ${project_networks}; do
        nginx_remove_network_config "${net}"
    done

    # Etapa 5/6: Arquivos do sistema (cron, logrotate)
    msg_step "ETAPA 5/6" "Removendo arquivos do sistema..."
    cron_remove

    # Logrotate
    local logrotate_file="/etc/logrotate.d/rotate-apache-logs-${project_name}"
    if [[ -f "${logrotate_file}" ]]; then
        echo -e "  Removendo: ${CYAN}${logrotate_file}${RESET}"
        sudo rm -f "${logrotate_file}"
    fi

    # Etapa 6/6: Config do site nginx
    msg_step "ETAPA 6/6" "Limpando configuracao do site..."
    if [[ -n "${DOMAIN_NAME:-}" ]]; then
        nginx_disable_site "${DOMAIN_NAME}" || msg_warn "Falha ao limpar config nginx para ${DOMAIN_NAME}"
    fi

    echo ""
    msg_success "Projeto ${project_name} removido com sucesso!"
}
