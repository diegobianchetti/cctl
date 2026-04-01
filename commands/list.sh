#!/bin/bash
# commands/list.sh — Lista instancias instaladas no servidor

cmd_list() {
    local base_dir="${INSTANCE_BASE_DIR:-/var/docker}"

    msg_header "Instancias cctl instaladas em ${base_dir}"
    echo ""

    if [[ ! -d "${base_dir}" ]]; then
        msg_warn "Diretorio ${base_dir} nao encontrado."
        return 0
    fi

    local found=0
    local dir
    for dir in "${base_dir}"/*/; do
        local instance_file="${dir}.cctl-instance"
        [[ -f "${instance_file}" ]] || continue

        found=$((found + 1))

        # Le metadados
        local inst_project="" inst_client="" inst_domain="" inst_created=""
        while IFS= read -r line; do
            case "${line}" in
                PROJECT_TYPE=*)  inst_project="${line#*=}" ; inst_project="${inst_project//\"/}" ;;
                CLIENT_NAME=*)   inst_client="${line#*=}"  ; inst_client="${inst_client//\"/}" ;;
                DOMAIN_NAME=*)   inst_domain="${line#*=}"  ; inst_domain="${inst_domain//\"/}" ;;
                CREATED_AT=*)    inst_created="${line#*=}"  ; inst_created="${inst_created//\"/}" ;;
            esac
        done < "${instance_file}"

        local dir_name
        dir_name=$(basename "${dir}")

        printf "  ${CYAN}%-25s${RESET}  %-10s  %-15s  %-35s  ${DIM}%s${RESET}\n" \
            "${dir_name}" "${inst_project}" "${inst_client}" "${inst_domain}" "${inst_created}"
    done

    if [[ ${found} -eq 0 ]]; then
        echo "  Nenhuma instancia encontrada."
    else
        echo ""
        echo "  Total: ${found} instancia(s)"
    fi
}
