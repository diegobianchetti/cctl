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

# Lista os nomes das redes Docker do projeto (usado por show_details,
# clear-all, down e a limpeza de rede orfa no install).
#
# UNIAO, nao fallback condicional: mesma razao de volumes_list_for_project
# (lib/volumes.sh) — uma rede rotulada pelo compose e uma rede orfa/recriada
# a mao sem label podem coexistir, e um `if [[ -z ]]` que so consulta o
# ramo por nome quando o ramo por label vem vazio faz a orfa desaparecer
# silenciosamente. Os dois ramos sempre rodam e o resultado e a uniao
# (dedup com `sort -u`). O filtro "name=" de REDE aceita ancora "^" (ao
# contrario do de volume), entao o ramo por nome ja usa prefixo literal via
# o proprio filtro do Docker — sem regex interpolada no lado do cctl.
network_list_for_project() {
    local project_name="$1"
    local by_label by_name

    # Label exato do compose (nao sofre colisao de prefixo)
    by_label=$(docker network ls \
        --filter "label=com.docker.compose.project=${project_name}" \
        --format "{{.Name}}")

    # Filtro por nome ancorado no inicio (cobre redes orfas/sem label)
    by_name=$(docker network ls --filter "name=^${project_name}_" --format "{{.Name}}")

    # printf sempre com exit 0 (mesmo com string vazia) e sed remove as
    # linhas em branco resultantes — evita depender de `[[ -n ]] && printf`,
    # que sob `set -e` do chamador aborta o script quando ambos os ramos
    # vem vazios.
    printf '%s\n%s\n' "${by_label}" "${by_name}" | sed '/^$/d' | sort -u
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
    networks=$(network_list_for_project "${project_name}")

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

# Desconecta o nginx-proxy de TODAS as redes do projeto, sem remove-las —
# usado por `cctl down` ANTES do `docker compose down`: a rede so pode ser
# removida quando nenhum endpoint externo ao projeto (o nginx-proxy, que
# `network_connect_nginx` conecta durante o install) permanece conectado; o
# proprio `docker compose down` remove a rede depois de derrubar os
# containers do projeto, entao aqui so precisamos tirar o proxy do caminho
# antes. Uso: network_disconnect_project_networks <project_name>
network_disconnect_project_networks() {
    local project_name="$1"
    local networks
    networks=$(network_list_for_project "${project_name}")
    [[ -z "${networks}" ]] && return 0

    local net
    for net in ${networks}; do
        network_disconnect_nginx "${net}"
    done
}

# Desconecta o nginx-proxy e REMOVE as redes orfas do projeto — usado pelo
# `cctl clear-all` (etapa de redes) e pelo inicio do `cctl install` para se
# recuperar de uma instalacao/down anterior que falhou antes de desconectar
# o proxy, deixando uma rede orfa com endpoints ativos que bloqueia o
# `docker network rm` (e, por tabela, o `docker compose up` seguinte reusar
# a rede do zero). Uso: network_cleanup_orphans <project_name>
network_cleanup_orphans() {
    local project_name="$1"
    local networks
    networks=$(network_list_for_project "${project_name}")
    [[ -z "${networks}" ]] && return 0

    local net
    for net in ${networks}; do
        network_disconnect_nginx "${net}"
        if docker network rm "${net}" 2>/dev/null; then
            log_success "Rede orfa ${net} removida"
        else
            log_warn "Rede ${net} nao pode ser removida agora (ainda em uso por outro container?)"
        fi
    done
}
