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
    if ! volumes=$(volumes_list_for_project "${project_name}"); then
        teardown_incomplete=true
        msg_warn "Nao foi possivel listar volumes; nenhuma remocao foi tentada."
        volumes=""
    fi
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
        # Um registro ainda pode ter uma reserva de versao anterior. Nao a
        # apagamos sem antes confirmar via C1 que a rede registrada sumiu.
        local inventory_rc=0
        inventory_read "${project_name}" || inventory_rc=$?
        if [[ ${inventory_rc} -eq 0 && -n "${INV_NETWORK:-}" ]]; then
            local reserved_state
            if ! reserved_state="$(docker_object_state network "${INV_NETWORK}")"; then
                teardown_incomplete=true
                msg_warn "Nao consegui consultar a rede registrada ${INV_NETWORK}; a reserva foi preservada."
            elif [[ "${reserved_state}" == "absent" ]]; then
                _clear_all_inventory_network "${project_name}" || {
                    teardown_incomplete=true
                    msg_warn "A rede registrada ${INV_NETWORK} ja nao existe, mas falhou a limpeza da reserva no inventario."
                }
            else
                teardown_incomplete=true
                msg_warn "A rede registrada ${INV_NETWORK} ainda existe; a reserva foi preservada e o teardown precisa ser concluido manualmente."
            fi
        elif [[ ${inventory_rc} -eq 0 ]]; then
            _clear_all_inventory_network "${project_name}" || {
                teardown_incomplete=true
                msg_warn "Falhou a limpeza da reserva no inventario; corrija o registro antes de destruir a instancia."
            }
        elif [[ ${inventory_rc} -eq 1 ]]; then
            local inventory_file
            if ! inventory_file="$(inventory_file_for "${project_name}")"; then
                teardown_incomplete=true
                msg_warn "Nao foi possivel determinar o registro de inventario; corrija antes de destruir."
            elif [[ -e "${inventory_file}" || -L "${inventory_file}" ]]; then
                teardown_incomplete=true
                msg_warn "O registro de inventario existe mas nao e arquivo regular legivel: ${inventory_file}; corrija antes de destruir."
            fi
        else
            teardown_incomplete=true
            msg_warn "Nao foi possivel ler a reserva no inventario; ela foi preservada."
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
    if ! cron_remove; then
        teardown_incomplete=true
        msg_warn "Falha ao remover cron jobs; o teardown precisa ser concluido manualmente."
    fi

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
