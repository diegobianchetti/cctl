#!/bin/bash
# commands/status.sh — Resumo de saude do ambiente

cmd_status() {
    msg_header "Status da instancia: ${COMPOSE_PROJECT_NAME}"
    echo ""

    # Info da instancia
    if [[ -f "./.cctl-instance" ]]; then
        source ./.cctl-instance
        echo -e "  Projeto:  ${CYAN}${PROJECT_TYPE}${RESET}"
        echo -e "  Cliente:  ${CYAN}${CLIENT_NAME}${RESET}"
        echo -e "  Dominio:  ${CYAN}${DOMAIN_NAME}${RESET}"
        echo -e "  Criado:   ${DIM}${CREATED_AT:-?}${RESET}"
        echo ""
    fi

    # Containers
    echo -e "${YELLOW}=== Containers ===${RESET}"
    compose_ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"
    echo ""

    # Rede
    echo -e "${YELLOW}=== Rede ===${RESET}"
    network_show_details

    # Disco
    echo -e "${YELLOW}=== Disco ===${RESET}"
    local volumes_count
    volumes_count=$(docker volume ls -q --filter "name=${COMPOSE_PROJECT_NAME}" | wc -l)
    echo -e "  Volumes: ${volumes_count}"

    local total_size
    total_size=$(docker system df -v 2>/dev/null | grep "${COMPOSE_PROJECT_NAME}" | awk '{sum+=$3} END {printf "%.1fMB", sum}' 2>/dev/null || echo "N/A")
    echo -e "  Tamanho estimado: ${total_size}"
    echo ""
}
