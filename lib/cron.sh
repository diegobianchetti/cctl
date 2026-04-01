#!/bin/bash
# lib/cron.sh — Instalar/remover crontab entries no host

# Instala cron jobs a partir dos arquivos em cron/
cron_install() {
    local cron_dir="./cron"

    if [[ ! -d "${cron_dir}" ]]; then
        log_debug "Diretorio cron/ nao encontrado"
        return 0
    fi

    local cron_file
    for cron_file in "${cron_dir}"/*.cron; do
        [[ -f "${cron_file}" ]] || continue

        local cron_name
        cron_name=$(basename "${cron_file}" .cron)
        local dest="/etc/cron.d/${cron_name}-${COMPOSE_PROJECT_NAME}"

        sudo cp "${cron_file}" "${dest}"
        sudo chmod 644 "${dest}"
        log_success "Cron instalado: ${dest}"
    done
}

# Remove todos os cron jobs do projeto
cron_remove() {
    local prefix="${COMPOSE_PROJECT_NAME}"
    local removed=0

    local cron_file
    for cron_file in /etc/cron.d/*-"${prefix}"; do
        [[ -f "${cron_file}" ]] || continue
        echo -e "  Removendo: ${CYAN}${cron_file}${RESET}"
        sudo rm -f "${cron_file}"
        removed=$((removed + 1))
    done

    # Tenta tambem o padrao inverso (prefixo-nome)
    for cron_file in /etc/cron.d/"${prefix}"-*; do
        [[ -f "${cron_file}" ]] || continue
        echo -e "  Removendo: ${CYAN}${cron_file}${RESET}"
        sudo rm -f "${cron_file}"
        removed=$((removed + 1))
    done

    if [[ ${removed} -gt 0 ]]; then
        log_success "${removed} cron job(s) removido(s)"
    else
        log_debug "Nenhum cron job encontrado para ${prefix}"
    fi
}

# Lista cron jobs do projeto
cron_list() {
    local prefix="${COMPOSE_PROJECT_NAME}"
    local found=0

    msg_header "Cron jobs do projeto ${prefix}"
    echo ""

    local cron_file
    for cron_file in /etc/cron.d/*"${prefix}"*; do
        [[ -f "${cron_file}" ]] || continue
        found=$((found + 1))
        echo -e "  ${CYAN}${cron_file}${RESET}"
        grep -v '^#' "${cron_file}" | grep -v '^$' | sed 's/^/    /'
        echo ""
    done

    if [[ ${found} -eq 0 ]]; then
        echo "  Nenhum cron job encontrado."
    fi
}
