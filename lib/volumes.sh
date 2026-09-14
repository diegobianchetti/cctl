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

# Lista os bind mounts (host paths) do compose do projeto atual — bash puro,
# sem jq. Antes deste parsing, `volumes_list` consultava
# `compose_exec config --format json` e filtrava com `jq -r 'select(.type ==
# "bind")'`, opcional (com fallback "(jq nao disponivel...)") — o unico uso
# de jq em todo o projeto, o que impedia o claim de "bash puro" ser literal
# (ver docs/README "Por que Bash puro, sem yq, jq ou Python?").
#
# Alternativa avaliada e descartada: `docker inspect` dos containers em
# execucao (`.Mounts[] | select(.Type=="bind")`) tambem exigiria jq (ou um
# parser Go-template mais fragil que a heuristica abaixo) e so cobre
# containers *up* no momento — `cctl volumes` deve funcionar tambem com o
# ambiente parado, contra o compose resolvido.
#
# Escolha: mesma heuristica de parsing por indentacao que
# `compose_buildable_services`/`compose_service_image` (lib/compose.sh) ja
# usam sobre `docker compose config` (YAML resolvido, sem --format json).
# Formato real de um bind mount no YAML resolvido (docker compose v2):
#   services:
#     <servico>:            # 2 espacos
#       volumes:             # 4 espacos
#         - type: bind        # 6 espacos, inicio do item da lista
#           source: /host/..  # 8 espacos
#           target: /dst/..   # 8 espacos
#           bind: {}
# Dentro do bloco "volumes:" de um servico, cada item comeca em "type:" (6
# espacos); quando o tipo e "bind", acumula "source:"/"target:" (8 espacos)
# e imprime ao encontrar o proximo item, o fim do bloco de volumes (linha
# com menos de 6 espacos de indentacao) ou o fim do arquivo. Mesma limitacao
# conhecida das duas funcoes irmas: assume a indentacao padrao de 2 espacos
# por nivel do `docker compose config` atual.
_volumes_bind_mounts() {
    local config
    config=$(compose_exec config 2>/dev/null) || return 1

    echo "${config}" | awk '
        /^services:[[:space:]]*$/ { in_services = 1; next }
        in_services && /^[A-Za-z0-9_-]+:[[:space:]]*$/ { in_services = 0 }
        in_services && /^  [A-Za-z0-9._-]+:[[:space:]]*$/ { in_volumes = 0; next }
        in_services && /^    volumes:[[:space:]]*$/ { in_volumes = 1; next }
        in_services && in_volumes && /^      - type:[[:space:]]*/ {
            if (is_bind && source != "") print "  " source "  ->  " target
            t = $0
            sub(/^      - type:[[:space:]]*/, "", t)
            is_bind = (t == "bind")
            source = ""; target = ""
            next
        }
        in_services && in_volumes && is_bind && /^        source:[[:space:]]*/ {
            s = $0; sub(/^        source:[[:space:]]*/, "", s); gsub(/^"|"$/, "", s)
            source = s; next
        }
        in_services && in_volumes && is_bind && /^        target:[[:space:]]*/ {
            s = $0; sub(/^        target:[[:space:]]*/, "", s); gsub(/^"|"$/, "", s)
            target = s; next
        }
        in_services && in_volumes && !/^      / {
            if (is_bind && source != "") print "  " source "  ->  " target
            in_volumes = 0; is_bind = 0; source = ""; target = ""
        }
        END { if (is_bind && source != "") print "  " source "  ->  " target }
    '
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
    local binds
    if binds=$(_volumes_bind_mounts); then
        if [[ -n "${binds}" ]]; then
            echo "${binds}"
        else
            echo "  Nenhum bind mount encontrado"
        fi
    else
        echo "  Nao foi possivel listar bind mounts"
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
        echo "${volumes}" | xargs -r docker volume rm
        msg_success "Volumes removidos"
    else
        msg_info "Nenhum volume encontrado"
    fi

    echo ""
    msg_success "Volumes do projeto ${project_name} removidos com sucesso!"
}
