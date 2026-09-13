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
    local vol_list volumes_count
    vol_list=$(volumes_list_for_project "${COMPOSE_PROJECT_NAME}")
    volumes_count=$(printf '%s\n' "${vol_list}" | grep -c . || true)
    echo -e "  Volumes: ${volumes_count}"

    # Soma o tamanho apenas dos volumes ja saneados por
    # volumes_list_for_project (uniao label+nome com prefixo literal) —
    # nunca um grep solto sobre a saida inteira do `docker system df -v`
    # (que tambem lista imagens/containers e sofre a mesma colisao de
    # substring de "moodle" vs "moodle-lab" que ja foi corrigida para
    # volumes/redes). Casamento por nome EXATO de campo ($1 in wanted), sem
    # regex interpolada.
    local total_size
    if [[ -n "${vol_list}" ]]; then
        # `docker system df -v` emite o campo SIZE com unidade embutida
        # (ex: "1.234GB", "512.3MB", "0B") — nao um numero cru em MB. Somar
        # $3 direto, como se todas as linhas viessem em MB, sub-estima
        # brutalmente qualquer volume >= 1GB (um volume de 2GB vira "2.0MB")
        # e o total fica errado sem nenhum sinal de que algo falhou. Cada
        # valor precisa ser normalizado para MB antes de somar.
        total_size=$(docker system df -v 2>/dev/null | LC_NUMERIC=C awk -v vols="${vol_list}" '
            BEGIN {
                n = split(vols, arr, "\n")
                for (i = 1; i <= n; i++) { if (arr[i] != "") wanted[arr[i]] = 1 }
            }
            ($1 in wanted) {
                s = $3
                u = s
                sub(/^[0-9.]+/, "", u)
                sub(/[A-Za-z]+$/, "", s)
                if (u == "GB") m = 1024
                else if (u == "TB") m = 1048576
                else if (u == "kB" || u == "KB") m = 1/1024
                else if (u == "B") m = 1/1048576
                else m = 1
                sum += s * m
            }
            END { printf "%.1fMB", sum }
        ' 2>/dev/null)
        [[ -z "${total_size}" ]] && total_size="N/A"
    else
        total_size="0.0MB"
    fi
    echo -e "  Tamanho estimado: ${total_size}"
    echo ""
}
