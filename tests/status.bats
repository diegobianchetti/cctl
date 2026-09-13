#!/usr/bin/env bats
# tests/status.bats — testes para commands/status.sh (classe B1 aplicada a
# contagem de volumes: "moodle" nao pode contar volumes de "moodle-lab").

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh network.sh volumes.sh compose.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    export COMPOSE_PROJECT_NAME="moodle"
    export CCTL_LOG_DIR="${WORKDIR}/logs"
    export CCTL_LOG_FILE=""

    # shellcheck source=/dev/null
    source "${CCTL_ROOT}/commands/status.sh"
}

teardown() {
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

@test "cmd_status (regressao B1): contagem de volumes nao inclui os de 'moodle-lab'" {
    declare -A CCTL_TEST_VOLS=(
        [moodle_dbdata]=""
        [moodle_moodledata]=""
        [moodle-lab_dbdata]=""
    )
    mock_docker_with_volumes CCTL_TEST_VOLS "${WORKDIR}/docker_calls.log"

    run cmd_status
    assert_success
    assert_output --partial "Volumes: 2"
}

@test "cmd_status (regressao B1): tamanho estimado nao incorpora volume de 'moodle-lab'" {
    declare -A CCTL_TEST_VOLS=(
        [moodle_dbdata]=""
        [moodle_moodledata]=""
        [moodle-lab_dbdata]=""
    )
    mock_docker_with_volumes CCTL_TEST_VOLS "${WORKDIR}/docker_calls.log"

    # Mock de "docker system df -v" da 10MB por volume listado na fixture
    # (label ou nao) — se o filtro de status.sh vazar o volume de
    # "moodle-lab", o total sobe para 30.0MB em vez de 20.0MB.
    run cmd_status
    assert_success
    assert_output --partial "Tamanho estimado: 20.0MB"
}

@test "cmd_status (regressao B1 unidade): soma normaliza GB/MB para MB antes de somar, nao rotula GB como MB" {
    # "docker system df -v" emite SIZE com unidade embutida — um volume de
    # 2GB tratado como "2" (numero cru em MB) reportaria "2.0MB" em vez de
    # "2048.0MB". Combinado com um volume de 512.3MB: total correto
    # 2048 + 512.3 = 2560.3MB.
    declare -A CCTL_TEST_VOLS=(
        [moodle_dbdata]=""
        [moodle_moodledata]=""
    )
    declare -A CCTL_TEST_SIZES=(
        [moodle_dbdata]="2GB"
        [moodle_moodledata]="512.3MB"
    )
    mock_docker_with_volumes CCTL_TEST_VOLS "${WORKDIR}/docker_calls.log" CCTL_TEST_SIZES

    run cmd_status
    assert_success
    assert_output --partial "Tamanho estimado: 2560.3MB"
    refute_output --partial "Tamanho estimado: 2.0MB"
}
