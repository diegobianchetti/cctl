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

    local rc=0

    # 1. Dump do banco de dados (se DB_SERVICE definido) — falha aqui e
    # fatal para o backup como um todo: um "backup ok" que na verdade nao
    # gravou o banco e pior que um erro visivel (ver WORK_LOG).
    if [[ -n "${DB_SERVICE:-}" ]]; then
        if ! _backup_database "${backup_dir}" "${backup_name}"; then
            log_error "Backup abortado: falha no dump do banco de dados."
            return 1
        fi
    fi

    # 2. Backup dos volumes Docker
    _backup_volumes "${backup_dir}" "${backup_name}" || rc=1

    # 3. Rotacao
    _backup_rotate "${backup_dir}" || rc=1

    if [[ ${rc} -ne 0 ]]; then
        log_error "Backup concluido com falhas: ${backup_dir}/${backup_name}"
        return 1
    fi

    log_success "Backup concluido: ${backup_dir}/${backup_name}"
}

# Dump do banco de dados
#
# Resolve o alvo pelo compose (compose_exec, lib/compose.sh) em vez de
# montar o nome do container a mao: "${COMPOSE_PROJECT_NAME}-${DB_SERVICE}-1"
# nao bate com o nome real quando o compose v2 nao sufixa "-1" (ou quando o
# template fixa "container_name:") — ver WORK_LOG. "-T" desabilita o
# pseudo-tty, necessario porque a saida do exec vai para um pipe.
#
# Usuario do banco: DB_USER (project.conf) com fallback POSTGRES_USER e
# default "postgres" — nunca chumbado, cada template pode ter um superusuario
# diferente (ex: moodle define POSTGRES_USER=moodle no servico de banco).
_backup_database() {
    local backup_dir="$1"
    local backup_name="$2"
    local dump_file="${backup_dir}/${backup_name}-db.sql.gz"
    local db_user="${DB_USER:-${POSTGRES_USER:-postgres}}"

    msg_info "Dump do banco de dados (${DB_SERVICE}, usuario ${db_user})..."

    case "${DB_TYPE:-postgresql}" in
        postgresql)
            local err_file
            err_file="$(mktemp)"
            if ! compose_exec exec -T "${DB_SERVICE}" \
                pg_dumpall -U "${db_user}" 2>"${err_file}" \
                | gzip > "${dump_file}"; then
                log_error "Falha ao executar dump do banco (${DB_SERVICE}, usuario ${db_user}): $(tail -n 5 "${err_file}")"
                rm -f "${dump_file}" "${err_file}"
                return 1
            fi
            rm -f "${err_file}"
            ;;
        *)
            log_warn "Dump automatico nao suportado para DB_TYPE=${DB_TYPE}"
            return 0
            ;;
    esac

    # Guard real: gzip -t confere integridade do arquivo, mas um dump vazio
    # (ex: usuario/permissao errados, mas o pg_dumpall ainda "funciona" e
    # produz stdout vazio) gera um gzip VALIDO de conteudo vazio — poucos
    # bytes, passa em "-s". Descomprime e confere que ha conteudo de fato.
    if ! gzip -t "${dump_file}" 2>/dev/null \
        || [[ "$(gzip -dc "${dump_file}" 2>/dev/null | wc -c)" -eq 0 ]]; then
        log_error "Dump do banco invalido ou vazio (${dump_file}) — removendo."
        rm -f "${dump_file}"
        return 1
    fi

    local size
    size=$(du -h "${dump_file}" | cut -f1)
    log_success "Dump do banco: ${dump_file} (${size})"
}

# Backup dos volumes Docker
_backup_volumes() {
    local backup_dir="$1"
    local backup_name="$2"
    local volumes
    volumes=$(volumes_list_for_project "${COMPOSE_PROJECT_NAME}")

    if [[ -z "${volumes}" ]]; then
        log_debug "Nenhum volume para backup"
        return 0
    fi

    local vol
    for vol in ${volumes}; do
        local vol_backup
        vol_backup="${backup_dir}/${backup_name}-vol-${vol#"${COMPOSE_PROJECT_NAME}_"}.tar.gz"
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

# Rotacao de backups antigos (mantem os ultimos N CONJUNTOS, nao arquivos)
#
# Cada rodada de backup gera 1 dump + 1 tar por volume, todos com o mesmo
# prefixo "<projeto>-<timestamp>" (ex: moodle com 7 volumes = 8 arquivos por
# rodada). Contar/rotacionar por ARQUIVO fazia BACKUP_RETENTION significar
# "numero de arquivos" em vez de "numero de backups" — com poucos volumes ja
# e possivel a propria rodada recem-criada estourar o limite e ter arquivos
# (incluindo o dump) removidos na mesma rotacao que os gerou. Agrupa por
# conjunto e remove conjuntos inteiros.
_backup_rotate() {
    local backup_dir="$1"
    local keep="${BACKUP_RETENTION:-7}"

    # O padrao de -name/regex exige a forma exata do timestamp
    # (AAAAMMDD-HHMMSS) logo apos "${COMPOSE_PROJECT_NAME}-": um glob solto
    # "${COMPOSE_PROJECT_NAME}-*" tambem casa backups de outro projeto cujo
    # nome tem este como prefixo (ex: "moodle-*" casa
    # "moodle-lab-20260913-...tar.gz") — com BACKUP_DIR compartilhado entre
    # instancias, a rotacao de um projeto contaria/removeria os backups do
    # outro. O mesmo bloco de digitos serve como classe de caracteres tanto
    # para o glob do "find -name" quanto para o "[[ =~ ]]" abaixo.
    local -r ts_glob="[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]"

    # Agrupa os arquivos por CONJUNTO: o prefixo "<projeto>-<timestamp>"
    # comum a todos os arquivos de uma mesma rodada.
    local -A set_files=()
    local f base prefix
    while IFS= read -r -d '' f; do
        base="$(basename "${f}")"
        if [[ "${base}" =~ ^(${COMPOSE_PROJECT_NAME}-${ts_glob}) ]]; then
            prefix="${BASH_REMATCH[1]}"
            set_files["${prefix}"]+="${f}"$'\n'
        fi
    done < <(find "${backup_dir}" -maxdepth 1 -name "${COMPOSE_PROJECT_NAME}-${ts_glob}*" -type f -print0)

    local -a prefixes=()
    local p
    for p in "${!set_files[@]}"; do
        prefixes+=("${p}")
    done

    local set_count=${#prefixes[@]}
    if [[ ${set_count} -le ${keep} ]]; then
        return 0
    fi

    msg_info "Rotacionando backups (mantendo ultimos ${keep} conjunto(s))..."

    # O timestamp embutido no prefixo (AAAAMMDD-HHMMSS) e lexicograficamente
    # ordenavel — nao precisa de mtime de arquivo para saber a ordem
    # cronologica dos conjuntos.
    local -a ordered=()
    while IFS= read -r p; do
        ordered+=("${p}")
    done < <(printf '%s\n' "${prefixes[@]}" | sort)

    local to_remove=$(( set_count - keep ))
    local i
    for (( i = 0; i < to_remove; i++ )); do
        p="${ordered[i]}"
        while IFS= read -r f; do
            [[ -n "${f}" ]] && rm -f "${f}"
        done <<< "${set_files[${p}]}"
    done

    log_debug "Backups rotacionados (${to_remove} conjunto(s) removido(s))"
}
