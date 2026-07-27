#!/bin/bash
# lib/network.sh — Alocacao de subnet e gerenciamento de redes Docker

# Encontra a proxima subnet /24 disponivel dentro do range do manifest
# Usa: SUBNET_RANGE (ex: "10.88.0.0/16") e SUBNET_PREFIX_LEN (ex: 24)
network_allocate_subnet() {
    local range="${SUBNET_RANGE:-10.88.0.0/16}"
    local prefix_len="${SUBNET_PREFIX_LEN:-24}"

    # Extrai o prefixo base (ex: "10.88" de "10.88.0.0/16")
    local base
    base=$(echo "${range}" | cut -d'.' -f1-2)

    # Lista todas as subnets Docker existentes
    local used_subnets
    used_subnets=$(docker network ls -q | xargs -r docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null | sort -u)

    # Procura a proxima subnet livre no range
    local third_octet
    for third_octet in $(seq 1 254); do
        local candidate="${base}.${third_octet}.0/${prefix_len}"

        if ! echo "${used_subnets}" | grep -q "^${candidate}$"; then
            echo "${candidate}"
            log_debug "Subnet alocada: ${candidate}"
            return 0
        fi
    done

    log_error "Nenhuma subnet livre encontrada no range ${range}"
    return 1
}

# Exibe detalhes da rede Docker do projeto
network_show_details() {
    local project_name="${COMPOSE_PROJECT_NAME}"

    if [[ -z "${project_name}" ]]; then
        log_error "COMPOSE_PROJECT_NAME nao definido"
        return 1
    fi

    # Busca redes do projeto
    local networks
    networks=$(docker network ls --filter "name=${project_name}" --format "{{.Name}}")

    if [[ -z "${networks}" ]]; then
        log_warn "Nenhuma rede encontrada para o projeto ${project_name}"
        return 0
    fi

    echo -e "Rede Docker da instalacao ${YELLOW}${project_name}${RESET}\n"

    local net
    for net in ${networks}; do
        local subnet
        subnet=$(docker network inspect "${net}" --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null)

        echo -e "Nome da Rede: ${CYAN}${net}${RESET}"
        echo -e "SUBNET:       ${CYAN}${subnet}${RESET}"
        echo ""

        # Lista containers conectados com IPs
        docker network inspect "${net}" --format '{{range $id, $c := .Containers}}{{$c.Name}} {{$c.IPv4Address}}{{"\n"}}{{end}}' 2>/dev/null \
            | while read -r name ip; do
                [[ -z "${name}" ]] && continue
                printf "  Container: %-30s  IPv4: %s\n" "${name}" "${ip}"
            done
        echo ""
    done
}

# Conecta o container nginx-proxy a rede do projeto
network_connect_nginx() {
    local project_network="$1"
    local container="${NGINX_CONTAINER_NAME:-nginx-proxy}"
    local alias_args=()
    [[ -n "${DOMAIN_NAME:-}" ]] && alias_args=(--alias "${DOMAIN_NAME}")

    if docker network connect "${alias_args[@]}" "${project_network}" "${container}" 2>/dev/null; then
        log_success "Nginx conectado a rede ${project_network}"
    else
        log_warn "Nao foi possivel conectar nginx a rede ${project_network} (ja conectado ou container inexistente)"
    fi
}

# Desconecta o container nginx-proxy da rede do projeto
network_disconnect_nginx() {
    local project_network="$1"
    local container="${NGINX_CONTAINER_NAME:-nginx-proxy}"

    if docker network disconnect "${project_network}" "${container}" 2>/dev/null; then
        log_success "Nginx desconectado da rede ${project_network}"
    else
        log_warn "Nginx nao estava conectado a rede ${project_network}"
    fi
}
