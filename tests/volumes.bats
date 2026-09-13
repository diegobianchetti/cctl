#!/usr/bin/env bats
# tests/volumes.bats — testes para lib/volumes.sh (classe B1 aplicada a
# volumes Docker: colisao de prefixo de nome de projeto).

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh volumes.sh compose.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    export COMPOSE_PROJECT_NAME="moodle"
    export CCTL_LOG_DIR="${WORKDIR}/logs"
    export CCTL_LOG_FILE=""

    mock_sudo_passthrough "${WORKDIR}/sudo.log"
}

teardown() {
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

@test "volumes_list_for_project: label exato do compose isola o projeto certo" {
    declare -A CCTL_TEST_VOLS=(
        [moodle_dbdata]="moodle"
        [moodle-lab_dbdata]="moodle-lab"
    )
    mock_docker_with_volumes CCTL_TEST_VOLS "${WORKDIR}/docker_calls.log"

    run volumes_list_for_project "moodle"
    assert_success
    assert_output "moodle_dbdata"
}

@test "volumes_list_for_project (regressao B1): sem label, fallback ancorado nao inclui 'moodle-lab'" {
    declare -A CCTL_TEST_VOLS=(
        [moodle_dbdata]=""
        [moodle-lab_dbdata]=""
    )
    mock_docker_with_volumes CCTL_TEST_VOLS "${WORKDIR}/docker_calls.log"

    run volumes_list_for_project "moodle"
    assert_success
    assert_output "moodle_dbdata"
    refute_output --partial "moodle-lab_dbdata"
}

@test "volumes_list_for_project: nenhum volume do projeto retorna vazio sem quebrar sob set -e" {
    declare -A CCTL_TEST_VOLS=( [outro-projeto_dbdata]="" )
    mock_docker_with_volumes CCTL_TEST_VOLS "${WORKDIR}/docker_calls.log"

    run bash -c 'set -euo pipefail; source '"${CCTL_ROOT}"'/lib/volumes.sh; volumes_list_for_project "moodle"'
    assert_success
    assert_output ""
}

@test "volumes_list_for_project (uniao, regressao Blocker 2): rotulado E orfao sem label aparecem os dois" {
    # moodle_dbdata tem label do compose; moodle_moodledata foi recriado a
    # mao apos um incidente e ficou sem label, mas casa o prefixo literal
    # "moodle_". Com o antigo `if [[ -z ]]` (so consulta o ramo por nome
    # quando o ramo por label vem vazio), moodle_moodledata desaparece
    # porque o ramo por label ja devolveu algo.
    declare -A CCTL_TEST_VOLS=(
        [moodle_dbdata]="moodle"
        [moodle_moodledata]=""
        [moodle-lab_dbdata]="moodle-lab"
    )
    mock_docker_with_volumes CCTL_TEST_VOLS "${WORKDIR}/docker_calls.log"

    run volumes_list_for_project "moodle"
    assert_success
    assert_output --partial "moodle_dbdata"
    assert_output --partial "moodle_moodledata"
    refute_output --partial "moodle-lab_dbdata"
}

@test "volumes_list_for_project: prefixo literal nao interpreta metacaractere de regex do nome do projeto" {
    # O filtro real de "docker volume ls --filter name=X" ja e substring
    # LITERAL (sem suporte a regex) e, por isso, sozinho ja barraria
    # qualquer volume que nao contenha X como substring — o que esconderia
    # uma regressao no POS-filtro (awk index(), lib/volumes.sh) caso ele
    # fosse trocado por algo como `grep -E "^${project_name}_"` (interpola o
    # nome do projeto — vindo de project.conf, nunca revalidado em runtime —
    # direto num padrao de regex). Este mock ignora deliberadamente o filtro
    # recebido e devolve TODOS os candidatos, isolando a seguranca no
    # pos-filtro de producao (pior caso: se o pre-filtro do Docker um dia
    # se comportar diferente, o pos-filtro precisa segurar sozinho).
    #
    # project_name = "a.b" (o "." e metacaractere ERE = "qualquer
    # caractere"). "a.b_data" comeca literalmente com "a.b_" (deve entrar).
    # "azb_data" so casaria se o "." fosse interpretado como wildcard de
    # regex (^a.b_ casando "azb_") — sob prefixo literal, deve ficar de
    # fora.
    mock_cmd docker '
        log="'"${WORKDIR}"'/docker_calls.log"
        echo "docker $*" >> "${log}"

        if [[ "$1" == "volume" && "$2" == "ls" ]]; then
            if [[ "$*" == *"label=com.docker.compose.project="* ]]; then
                exit 0
            fi
            printf "a.b_data\nazb_data\n"
            exit 0
        fi
        exit 0
    '

    run volumes_list_for_project "a.b"
    assert_success
    assert_output "a.b_data"
    refute_output --partial "azb_data"
}

@test "volumes_clear (regressao B1): nao remove volume de 'moodle-lab'" {
    declare -A CCTL_TEST_VOLS=(
        [moodle_dbdata]=""
        [moodle-lab_dbdata]=""
    )
    mock_docker_with_volumes CCTL_TEST_VOLS "${WORKDIR}/docker_calls.log"

    run volumes_clear <<< "moodle"
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "moodle_dbdata"
    refute_output --partial "moodle-lab_dbdata"
}
