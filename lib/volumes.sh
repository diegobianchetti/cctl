#!/bin/bash
# lib/volumes.sh — Listar e limpar volumes Docker do projeto

# Lista volumes Docker e bind mounts do projeto
volumes_list() {
    local project_name="${COMPOSE_PROJECT_NAME}"

    echo -e "Volumes e Bind Mounts da instalacao ${YELLOW}${project_name}${RESET}\n"

    # 1. Volumes Docker (named volumes)
    echo -e "${YELLOW}=== Volumes Docker ===${RESET}"
    local volumes
    volumes=$(docker volume ls --filter "name=${project_name}" --format "{{.Name}}")

    if [[ -n "${volumes}" ]]; then
        local vol mountpoint
        for vol in ${volumes}; do
            mountpoint=$(docker volume inspect "${vol}" --format '{{.Mountpoint}}')
            printf "  %-50s  %s\n" "${vol}" "${mountpoint}"
        done
    else
        echo "  Nenhum volume encontrado"
    fi

    # 2. Bind mounts do compose
    echo -e "\n${YELLOW}=== Bind Mounts (Host Paths) ===${RESET}"
    if command -v jq &>/dev/null; then
        compose_exec config --format json 2>/dev/null \
            | jq -r '.services[]?.volumes[]? | select(.type == "bind") | "  \(.source)  →  \(.target)"' 2>/dev/null \
            || echo "  Nao foi possivel listar bind mounts"
    else
        echo "  (jq nao disponivel para listar bind mounts)"
    fi
}

# Remove todos os volumes do projeto (com confirmacao)
volumes_clear() {
    local project_name="${COMPOSE_PROJECT_NAME}"

    msg_danger "ATENCAO: ESTA OPERACAO REMOVERA TODOS OS DADOS DO PROJETO!"
    echo -e "${YELLOW}Projeto: ${CYAN}${project_name}${RESET}"
    echo -e "${YELLOW}Esta acao e irreversivel e inclui:${RESET}"
    echo "  - Todos os volumes (dados permanentes)"
    echo ""

    read -rp "Digite exatamente o nome do projeto para confirmar: " confirmation
    echo ""

    if [[ "${confirmation}" != "${project_name}" ]]; then
        msg_error "Confirmacao falhou!"
        msg_warn "Operacao cancelada."
        return 1
    fi

    # Para e remove containers
    msg_step "ETAPA 1/2" "Parando e removendo containers..."
    if compose_exec down 2>/dev/null; then
        msg_success "Containers removidos"
    else
        msg_warn "Nenhum container em execucao encontrado"
    fi

    # Remove volumes
    msg_step "ETAPA 2/2" "Removendo volumes..."
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

    echo ""
    msg_success "Volumes do projeto ${project_name} removidos com sucesso!"
}
