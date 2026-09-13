#!/bin/bash
# lib/volumes.sh — Listar e limpar volumes Docker do projeto

# Lista os nomes dos volumes Docker do projeto (usado por volumes_list,
# volumes_clear, clear-all, status e backup). Mesma estrategia de
# network_list_for_project (lib/network.sh): o filtro "name=" do
# `docker volume ls` faz match por SUBSTRING (nao aceita "^" de ancora), o
# que faz um projeto "moodle" tambem casar volumes de "moodle-lab" — colisao
# da mesma classe do bug B1 de redes.
#
# UNIAO, nao fallback condicional: um recurso rotulado pelo compose (label
# exato) E um recurso orfao/recriado a mao sem label (mesmo prefixo
# "<projeto>_") podem coexistir no mesmo host — ex: apos um incidente em que
# um volume foi recriado manualmente e perdeu o label. Um `if [[ -z ]]` que
# so consulta o ramo por nome quando o ramo por label vem vazio faz o orfao
# desaparecer silenciosamente sempre que ao menos um volume rotulado existe
# (perda de cobertura de backup/limpeza/contagem). Por isso os dois ramos
# sempre rodam e o resultado e a uniao (dedup com `sort -u`).
#
# O pos-filtro do ramo por nome usa casamento de PREFIXO LITERAL (awk
# index(), nao grep -E com o nome interpolado num padrao de regex): o nome
# do projeto so passa por `validate_project_name` em `cctl init`
# (commands/init.sh:53) — em runtime ele chega de project.conf/.env e nunca
# e revalidado, entao um caractere de metacaractere de ERE (ex: "|") num
# manifest editado a mao nao pode ser interpretado como regex.
# Uso: volumes_list_for_project <projeto>
volumes_list_for_project() {
    local project_name="$1"
    local by_label by_name

    # Label exato do compose (nao sofre colisao de prefixo)
    by_label=$(docker volume ls -q --filter "label=com.docker.compose.project=${project_name}")

    # Filtro por nome (substring, o volume ls nao aceita "^") + pos-filtro
    # de prefixo literal "<projeto>_" (cobre volumes orfaos/sem label)
    by_name=$(docker volume ls -q --filter "name=${project_name}" \
        | awk -v p="${project_name}_" 'index($0,p)==1')

    # printf sempre com exit 0 (mesmo com string vazia) e sed remove as
    # linhas em branco resultantes — evita depender de `[[ -n ]] && printf`
    # dentro do grupo, que sob `set -e` do chamador aborta o script quando
    # ambos os ramos vem vazios (o `&&` propaga o status de falha do teste).
    printf '%s\n%s\n' "${by_label}" "${by_name}" | sed '/^$/d' | sort -u
}

# Lista volumes Docker e bind mounts do projeto
volumes_list() {
    local project_name="${COMPOSE_PROJECT_NAME}"

    echo -e "Volumes e Bind Mounts da instalacao ${YELLOW}${project_name}${RESET}\n"

    # 1. Volumes Docker (named volumes)
    echo -e "${YELLOW}=== Volumes Docker ===${RESET}"
    local volumes
    volumes=$(volumes_list_for_project "${project_name}")

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
    volumes=$(volumes_list_for_project "${project_name}")

    if [[ -n "${volumes}" ]]; then
        echo -e "${BLUE}Volumes encontrados (inclui volumes orfaos sem label do compose):${RESET}"
        echo "${volumes}" | sed 's/^/  - /'
        echo "${volumes}" | xargs -r sudo docker volume rm
        msg_success "Volumes removidos"
    else
        msg_info "Nenhum volume encontrado"
    fi

    echo ""
    msg_success "Volumes do projeto ${project_name} removidos com sucesso!"
}
