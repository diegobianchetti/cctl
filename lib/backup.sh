#!/bin/bash
# lib/backup.sh — Orquestrar backup e rotacao

# Executa backup do ambiente
# Delega para o script de backup do template (se existir) ou faz backup generico
backup_run() {
    local backup_script="./scripts/backup.sh"

    # Se existe script de backup especifico do template, usa ele
    if [[ -f "${backup_script}" ]]; then
        msg_step "BACKUP" "Executando script de backup do projeto..."
        bash "${backup_script}" "$@"
        return $?
    fi

    # Backup generico: dump dos volumes
    _backup_generic "$@"
}

# Backup generico baseado em volumes
_backup_generic() {
    local backup_dir="${BACKUP_DIR:-./backups}"
    local timestamp
    timestamp=$(date +%Y%m%d-%H%M%S)
    local backup_name="${COMPOSE_PROJECT_NAME}-${timestamp}"

    mkdir -p "${backup_dir}"

    msg_step "BACKUP" "Backup generico do projeto ${COMPOSE_PROJECT_NAME}..."

    # 1. Dump do banco de dados (se DB_SERVICE definido)
    if [[ -n "${DB_SERVICE:-}" ]]; then
        _backup_database "${backup_dir}" "${backup_name}"
    fi

    # 2. Backup dos volumes Docker
    _backup_volumes "${backup_dir}" "${backup_name}"

    # 3. Rotacao
    _backup_rotate "${backup_dir}"

    log_success "Backup concluido: ${backup_dir}/${backup_name}"
}

# Dump do banco de dados
_backup_database() {
    local backup_dir="$1"
    local backup_name="$2"
    local container_name="${COMPOSE_PROJECT_NAME}-${DB_SERVICE}-1"
    local dump_file="${backup_dir}/${backup_name}-db.sql.gz"

    msg_info "Dump do banco de dados (${DB_SERVICE})..."

    case "${DB_TYPE:-postgresql}" in
        postgresql)
            docker exec "${container_name}" \
                pg_dumpall -U postgres 2>/dev/null \
                | gzip > "${dump_file}"
            ;;
        *)
            log_warn "Dump automatico nao suportado para DB_TYPE=${DB_TYPE}"
            return 0
            ;;
    esac

    if [[ -s "${dump_file}" ]]; then
        local size
        size=$(du -h "${dump_file}" | cut -f1)
        log_success "Dump do banco: ${dump_file} (${size})"
    else
        log_warn "Dump do banco vazio ou falhou"
        rm -f "${dump_file}"
    fi
}

# Backup dos volumes Docker
_backup_volumes() {
    local backup_dir="$1"
    local backup_name="$2"
    local volumes
    volumes=$(docker volume ls -q --filter "name=${COMPOSE_PROJECT_NAME}")

    if [[ -z "${volumes}" ]]; then
        log_debug "Nenhum volume para backup"
        return 0
    fi

    local vol
    for vol in ${volumes}; do
        local vol_backup="${backup_dir}/${backup_name}-vol-$(echo "${vol}" | sed "s/${COMPOSE_PROJECT_NAME}_//").tar.gz"
        msg_info "Backup do volume: ${vol}..."

        docker run --rm \
            -v "${vol}:/data:ro" \
            -v "$(realpath "${backup_dir}"):/backup" \
            alpine tar czf "/backup/$(basename "${vol_backup}")" -C /data . 2>/dev/null

        if [[ -f "${vol_backup}" ]]; then
            local size
            size=$(du -h "${vol_backup}" | cut -f1)
            log_debug "Volume ${vol}: ${size}"
        fi
    done
}

# Rotacao de backups antigos (mantem os ultimos N)
_backup_rotate() {
    local backup_dir="$1"
    local keep="${BACKUP_RETENTION:-7}"

    local count
    count=$(find "${backup_dir}" -name "${COMPOSE_PROJECT_NAME}-*" -type f | wc -l)

    if [[ ${count} -le ${keep} ]]; then
        return 0
    fi

    msg_info "Rotacionando backups (mantendo ultimos ${keep})..."

    find "${backup_dir}" -name "${COMPOSE_PROJECT_NAME}-*" -type f -printf '%T@ %p\n' \
        | sort -n \
        | head -n -"${keep}" \
        | cut -d' ' -f2- \
        | xargs -r rm -f

    log_debug "Backups rotacionados"
}
