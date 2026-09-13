#!/usr/bin/env bats
# tests/backup.bats — testes para lib/backup.sh (classe B1 aplicada ao
# backup de volumes: um backup do projeto "moodle" nao pode incluir volumes
# de "moodle-lab").

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh volumes.sh backup.sh

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
