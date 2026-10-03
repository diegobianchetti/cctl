#!/bin/bash
# commands/list.sh — Lista instancias registradas no inventario do cctl
#
# F2.4 (R4): antes, varria CCTL_INSTANCE_BASE_DIR/* procurando
# .cctl-instance — nao via instancias com --dest fora da base, e nao
# distinguia "prepared" (so `cctl init`) de "installed". Agora le
# EXCLUSIVAMENTE o inventario (lib/inventory.sh:inventory_list), nunca o
# disco direto.

cmd_list() {
    msg_header "Instancias cctl registradas"
    echo ""

    if [[ ! -d "${CCTL_INVENTORY_DIR}" ]]; then
        msg_warn "Inventario vazio (${CCTL_INVENTORY_DIR} nao existe)."
        msg_info "Use 'cctl init' para registrar um novo projeto."
        return 0
    fi

    local found=0 warned=0
    # created/updated: lidos por posicao (formato TSV de inventory_list),
    # nao exibidos nesta tabela — shellcheck disable=SC2034 abaixo.
    local name type client domain instance_dir status state created updated

    # shellcheck disable=SC2034
    while IFS=$'\t' read -r name type client domain instance_dir status state created updated; do
        [[ -n "${name}" ]] || continue
        found=$((found + 1))

        local state_label
        case "${state}" in
            ok)        state_label="${GREEN}${status}${RESET}" ;;
            stale)     state_label="${YELLOW}${status} (stale)${RESET}"; warned=$((warned + 1)) ;;
            corrupted) state_label="${RED}corrompido${RESET}"; warned=$((warned + 1)) ;;
            *)         state_label="${status}" ;;
        esac

        printf "  ${CYAN}%-25s${RESET}  %-10s  %-15s  %-35s  %b\n" \
            "${name}" "${type}" "${client}" "${domain}" "${state_label}"
        printf "    ${DIM}%s${RESET}\n" "${instance_dir}"
    done < <(inventory_list)

    echo ""
    if [[ ${found} -eq 0 ]]; then
        echo "  Nenhuma instancia registrada."
    else
        if [[ ${warned} -gt 0 ]]; then
            echo "  Total: ${found} registro(s), ${warned} com aviso (ver mensagens acima)"
        else
            echo "  Total: ${found} registro(s)"
        fi
    fi
}
