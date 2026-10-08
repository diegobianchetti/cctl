#!/bin/bash
# commands/clear-all.sh — Remove tudo: containers, volumes, configs do host

# Limpa a reserva somente se ha registro de inventario. Instancias legadas nao
# tem registro; para elas, a ausencia e tolerada. Se o registro existe, falha
# ao gravar a limpeza deixa uma reserva stale e precisa tornar o teardown
# incompleto, nunca ser convertida em sucesso.
_clear_all_inventory_network() {
    local project_name="$1" file
    file="$(inventory_file_for "${project_name}")" || return 1
    [[ -e "${file}" ]] || return 0

    inventory_clear_network "${project_name}"
}

# O destroy chama esta funcao dentro de `if !`, o que inibe o errexit aqui
# dentro: toda falha que deve impedir a exclusao definitiva e agregada em
# teardown_incomplete, nunca deixada a cargo do `set -e`.
cmd_clear-all() {
    local project_name="${COMPOSE_PROJECT_NAME}"
    local teardown_incomplete=false

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
    volumes=$(volumes_list_for_project "${project_name}")
    if [[ -n "${volumes}" ]]; then
        echo -e "${BLUE}Volumes encontrados (inclui volumes orfaos sem label do compose):${RESET}"
        echo "${volumes}" | sed 's/^/  - /'
        if echo "${volumes}" | xargs -r docker volume rm; then
            msg_success "Volumes removidos"
        else
            teardown_incomplete=true
            msg_warn "Falha ao remover um ou mais volumes; o teardown precisa ser concluido manualmente."
        fi
    else
        msg_info "Nenhum volume encontrado"
    fi

    # Etapa 3/6: Rede do projeto (a unica operacao do cctl que apaga a rede)
    msg_step "ETAPA 3/6" "Removendo a rede do projeto..."
    local project_network="${CCTL_PROJECT_NETWORK:-}"
    if [[ -n "${project_network}" ]]; then
        if network_remove_project_network "${project_network}"; then
            # A faixa deixa de estar reservada no inventario. Sem registro e
            # legado tolerado; erro ao atualizar registro existente impede
            # reportar teardown completo com reserva stale.
            if ! _clear_all_inventory_network "${project_name}"; then
                teardown_incomplete=true
                msg_warn "A rede ${project_network} foi removida, mas falhou a limpeza da reserva no inventario; corrija o registro antes de destruir a instancia."
            fi
        else
            teardown_incomplete=true
            msg_warn "A rede ${project_network} continua existindo (provavelmente ha um container ainda conectado a ela, ex.: o slot green de um rollout) e a faixa continua reservada no inventario."
            msg_warn "Veja quem esta nela: docker network inspect ${project_network}. Depois remova: docker network rm ${project_network}"
        fi
    else
        msg_info "Nenhuma rede registrada para o projeto (CCTL_PROJECT_NETWORK ausente no .env)"
        if ! _clear_all_inventory_network "${project_name}"; then
            teardown_incomplete=true
            msg_warn "Falhou a limpeza da reserva no inventario; corrija o registro antes de destruir a instancia."
        fi
    fi

    # Etapa 4/6: Nginx compose config
    msg_step "ETAPA 4/6" "Atualizando configuracao do Nginx..."
    if [[ -n "${project_network}" ]] && ! nginx_remove_network_config "${project_network}"; then
        teardown_incomplete=true
        msg_warn "Falha ao atualizar a configuracao de rede do nginx; o teardown precisa ser concluido manualmente."
    fi

    # Etapa 5/6: Arquivos do sistema (cron, logrotate)
    msg_step "ETAPA 5/6" "Removendo arquivos do sistema..."
    cron_remove

    # Logrotate
    local logrotate_file="${LOGROTATE_DIR}/rotate-apache-logs-${project_name}"
    if [[ -f "${logrotate_file}" ]]; then
        echo -e "  Removendo: ${CYAN}${logrotate_file}${RESET}"
        if ! core_priv_run rm -f "${logrotate_file}"; then
            teardown_incomplete=true
            msg_warn "Falha ao remover ${logrotate_file}; o teardown precisa ser concluido manualmente."
        fi
    fi

    # Etapa 6/6: Config do site nginx
    msg_step "ETAPA 6/6" "Limpando configuracao do site..."
    if [[ -n "${DOMAIN_NAME:-}" ]]; then
        nginx_disable_site "${DOMAIN_NAME}" || msg_warn "Falha ao limpar config nginx para ${DOMAIN_NAME}"
    fi

    echo ""
    if [[ "${teardown_incomplete}" == "true" ]]; then
        msg_error "Projeto ${project_name} nao foi removido completamente. Corrija as falhas indicadas acima antes de destruir a instancia."
        return 1
    fi
    msg_success "Projeto ${project_name} removido com sucesso!"
}
