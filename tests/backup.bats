#!/usr/bin/env bats
# tests/backup.bats — testes para lib/backup.sh (classe B1 aplicada ao
# backup de volumes: um backup do projeto "moodle" nao pode incluir volumes
# de "moodle-lab").

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh volumes.sh compose.sh backup.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    export COMPOSE_PROJECT_NAME="moodle"
    export CCTL_LOG_DIR="${WORKDIR}/logs"
    export CCTL_LOG_FILE=""
    export BACKUP_DIR="${WORKDIR}/backups"
    unset DB_SERVICE 2>/dev/null || true

    mock_sudo_passthrough "${WORKDIR}/sudo.log"
    mkdir -p "${BACKUP_DIR}"

    # docker run (usado pelo tar do volume) e docker volume ls (via
    # mock_docker_with_volumes) precisam conviver no mesmo mock: o helper
    # registra qualquer subcomando fora de "volume" apenas no log e retorna
    # sucesso, entao "docker run ... alpine tar czf ..." e um no-op que so
    # aparece no log — suficiente para provar QUAIS volumes entraram no
    # backup sem precisar de tar real.
}

teardown() {
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

@test "_backup_volumes (regressao B1): backup de 'moodle' nao inclui volume de 'moodle-lab'" {
    declare -A CCTL_TEST_VOLS=(
        [moodle_dbdata]=""
        [moodle-lab_dbdata]=""
    )
    mock_docker_with_volumes CCTL_TEST_VOLS "${WORKDIR}/docker_calls.log"

    run _backup_volumes "${WORKDIR}/backups" "moodle-20260913-000000"
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "moodle_dbdata"
    refute_output --partial "moodle-lab_dbdata"
}

@test "_backup_volumes (uniao, regressao Blocker 2): inclui volume orfao sem label (cobertura de backup)" {
    # moodle_dbdata tem label; moodle_moodledata foi recriado a mao apos um
    # incidente e ficou sem label. Antes do fix (if [[ -z ]]), o ramo por
    # nome nunca rodava porque o ramo por label ja devolvia algo — o backup
    # perdia moodle_moodledata silenciosamente (so log_debug, sem aviso).
    declare -A CCTL_TEST_VOLS=(
        [moodle_dbdata]="moodle"
        [moodle_moodledata]=""
        [moodle-lab_dbdata]="moodle-lab"
    )
    mock_docker_with_volumes CCTL_TEST_VOLS "${WORKDIR}/docker_calls.log"

    run _backup_volumes "${WORKDIR}/backups" "moodle-20260913-000000"
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "moodle_dbdata"
    assert_output --partial "moodle_moodledata"
    refute_output --partial "moodle-lab_dbdata"
}

@test "_backup_rotate (regressao B2): rotacao de 'moodle' nao remove nem conta backups de 'moodle-lab'" {
    # Nomes reais gerados por _backup_generic:
    # "${COMPOSE_PROJECT_NAME}-<AAAAMMDD-HHMMSS>-vol-*.tar.gz". Um glob solto
    # "moodle-*" tambem casaria "moodle-lab-...", entao a rotacao de "moodle"
    # apagaria/contaria os backups do outro projeto quando BACKUP_DIR e
    # compartilhado.
    local dir="${WORKDIR}/backups"
    mkdir -p "${dir}"

    local i ts
    for i in 1 2 3; do
        ts="$(printf '2026091%d-00000%d' "${i}" "${i}")"
        : > "${dir}/moodle-${ts}-vol-dbdata.tar.gz"
        touch -d "2026-09-1${i} 00:00:0${i}" "${dir}/moodle-${ts}-vol-dbdata.tar.gz"
    done
    for i in 1 2; do
        ts="$(printf '2026092%d-00000%d' "${i}" "${i}")"
        : > "${dir}/moodle-lab-${ts}-vol-dbdata.tar.gz"
        touch -d "2026-09-2${i} 00:00:0${i}" "${dir}/moodle-lab-${ts}-vol-dbdata.tar.gz"
    done

    export BACKUP_RETENTION=1
    run _backup_rotate "${dir}"
    assert_success

    local moodle_count moodle_lab_count
    moodle_count=$(find "${dir}" -maxdepth 1 -name 'moodle-2*' -type f | wc -l)
    moodle_lab_count=$(find "${dir}" -maxdepth 1 -name 'moodle-lab-*' -type f | wc -l)

    # "moodle" foi rotacionado para o keep=1
    [[ "${moodle_count}" -eq 1 ]]
    # "moodle-lab" permanece intocado (2 arquivos, nenhum removido/contado)
    [[ "${moodle_lab_count}" -eq 2 ]]
}

# --- _backup_database (P: nome de container montado a mao / usuario chumbado / dump vazio) --

@test "_backup_database: resolve o servico via compose_exec, nao via nome de container montado a mao" {
    export DB_SERVICE="moodle-db"
    export DB_TYPE="postgresql"
    export DB_USER="moodle"

    mock_cmd docker '
        echo "docker $*" >> "'"${WORKDIR}"'/docker_calls.log"
        case "$1" in
            exec)
                # Padrao antigo: "docker exec <container-montado-a-mao> ...".
                # Tem que falhar — prova que o codigo novo nao usa esse caminho.
                exit 1
                ;;
            compose)
                shift
                found_exec=0
                found_service=0
                for a in "$@"; do
                    [[ "${a}" == "exec" ]] && found_exec=1
                    [[ "${a}" == "moodle-db" ]] && found_service=1
                done
                if [[ ${found_exec} -eq 1 && ${found_service} -eq 1 ]]; then
                    echo "-- fake pg_dumpall output --"
                    exit 0
                fi
                exit 1
                ;;
            *) exit 0 ;;
        esac
    '

    run _backup_database "${BACKUP_DIR}" "moodle-20260913-000000"
    assert_success
    [[ -f "${BACKUP_DIR}/moodle-20260913-000000-db.sql.gz" ]]

    run cat "${WORKDIR}/docker_calls.log"
    refute_output --partial "docker exec "
    assert_output --partial "docker compose"
}

@test "_backup_database: dump vazio (stdout vazio do pg_dumpall) -- remove o arquivo e retorna erro" {
    export DB_SERVICE="moodle-db"
    export DB_TYPE="postgresql"

    mock_cmd docker '
        case "$1" in
            compose)
                shift
                found=0
                for a in "$@"; do [[ "${a}" == "exec" ]] && found=1; done
                # "sucesso" do exec, mas SEM nenhuma saida em stdout — o caso
                # real medido: gzip de conteudo vazio, 20 bytes, gzip -t passa.
                [[ ${found} -eq 1 ]] && exit 0
                exit 1
                ;;
            *) exit 0 ;;
        esac
    '

    run _backup_database "${BACKUP_DIR}" "moodle-empty"
    assert_failure
    [[ ! -f "${BACKUP_DIR}/moodle-empty-db.sql.gz" ]]
}

# --- _backup_rotate por CONJUNTO (nao por arquivo) -------------------------

@test "_backup_rotate: com 2 conjuntos de 3 arquivos e retencao=1, mantem o CONJUNTO inteiro mais recente" {
    local dir="${BACKUP_DIR}"
    local suf
    for suf in db vol-a vol-b; do
        : > "${dir}/moodle-20260910-000000-${suf}.tar.gz"
    done
    for suf in db vol-a vol-b; do
        : > "${dir}/moodle-20260912-000000-${suf}.tar.gz"
    done

    export BACKUP_RETENTION=1
    run _backup_rotate "${dir}"
    assert_success

    local remaining
    remaining=$(find "${dir}" -maxdepth 1 -name 'moodle-2*' -type f | wc -l)
    [[ "${remaining}" -eq 3 ]]
    [[ -f "${dir}/moodle-20260912-000000-db.tar.gz" ]]
    [[ -f "${dir}/moodle-20260912-000000-vol-a.tar.gz" ]]
    [[ -f "${dir}/moodle-20260912-000000-vol-b.tar.gz" ]]
    [[ ! -f "${dir}/moodle-20260910-000000-db.tar.gz" ]]
}

# --- backup_run: delega para ./scripts/backup.sh quando existe -------------

@test "backup_run: usa ./scripts/backup.sh quando existe e nao chama o backup generico" {
    mkdir -p ./scripts
    cat > ./scripts/backup.sh <<'SCRIPTEOF'
#!/bin/bash
echo "script proprio executado"
exit 0
SCRIPTEOF
    chmod +x ./scripts/backup.sh

    # Se o generico rodasse, chamaria "docker" (via _backup_volumes/database)
    # sem nenhum mock configurado aqui — sinalizador de que o generico NAO
    # deveria ser alcancado neste teste.
    run backup_run
    assert_success
    assert_output --partial "script proprio executado"
}

# --- template moodle: scripts/backup.sh existe e e executavel --------------

@test "templates/moodle/scripts/backup.sh existe, tem shebang bash e e executavel" {
    local script="${CCTL_ROOT}/templates/moodle/scripts/backup.sh"
    [[ -f "${script}" ]]
    [[ -x "${script}" ]]
    run head -n1 "${script}"
    assert_output "#!/bin/bash"
}

@test "_backup_volumes: com label exato do compose, so processa volumes do projeto certo" {
    declare -A CCTL_TEST_VOLS=(
        [moodle_dbdata]="moodle"
        [moodle_moodledata]="moodle"
        [moodle-lab_dbdata]="moodle-lab"
    )
    mock_docker_with_volumes CCTL_TEST_VOLS "${WORKDIR}/docker_calls.log"

    run _backup_volumes "${WORKDIR}/backups" "moodle-20260913-000000"
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "moodle_dbdata"
    assert_output --partial "moodle_moodledata"
    refute_output --partial "moodle-lab_dbdata"
}
