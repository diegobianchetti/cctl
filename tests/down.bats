#!/usr/bin/env bats
# tests/down.bats — testes para commands/down.sh (P2: desconexao do
# nginx-proxy da rede do projeto antes do compose down)
#
# Isolamento: docker/docker compose sempre mockados via bin/ temporario no
# PATH. Nenhum container, rede ou porta real e tocado.

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh network.sh compose.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    export COMPOSE_PROJECT_NAME="testproj"
    export CCTL_LOG_DIR="${WORKDIR}/logs"
    export CCTL_LOG_FILE=""
    unset COMPOSE_FILES 2>/dev/null || true

    declare -A CCTL_TEST_NETS=( [testproj_network]="testproj" )
    mock_docker_with_networks CCTL_TEST_NETS "${WORKDIR}/docker_calls.log"

    # shellcheck source=/dev/null
    source "${CCTL_ROOT}/commands/down.sh"
}

teardown() {
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

@test "cmd_down: desconecta o nginx-proxy da rede do projeto ANTES do compose down" {
    run cmd_down
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "network disconnect testproj_network nginx-proxy"

    # a desconexao precisa acontecer ANTES da chamada de compose down, para
    # que o "docker compose down" consiga remover a rede sem endpoints ativos
    local disconnect_line down_line
    disconnect_line=$(grep -n "network disconnect" "${WORKDIR}/docker_calls.log" | head -1 | cut -d: -f1)
    down_line=$(grep -n "compose .*down" "${WORKDIR}/docker_calls.log" | head -1 | cut -d: -f1)
    [[ -n "${disconnect_line}" && -n "${down_line}" ]]
    (( disconnect_line < down_line ))
}

@test "cmd_down: sem COMPOSE_PROJECT_NAME nao tenta desconectar nada (no-op seguro)" {
    unset COMPOSE_PROJECT_NAME

    run cmd_down
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    refute_output --partial "network disconnect"
}

@test "cmd_down: repassa argumentos extras para compose_down" {
    run cmd_down -v
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "down -v"
}

@test "cmd_down (regressao B1): projeto 'moodle' nao desconecta a rede de 'moodle-lab' (colisao de prefixo)" {
    # Redes criadas a mao (sem label de compose) — cenario real reportado:
    # "moodle" (filtro solto/nao ancorado) tambem casaria com
    # "moodle-lab_moodle-network". Sem o fix de B1 este teste falha porque
    # o disconnect tambem alcanca a rede do moodle-lab.
    export COMPOSE_PROJECT_NAME="moodle"
    declare -A CCTL_TEST_NETS=(
        [moodle_network]=""
        [moodle-lab_moodle-network]=""
    )
    mock_docker_with_networks CCTL_TEST_NETS "${WORKDIR}/docker_calls.log"

    run cmd_down
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "network disconnect moodle_network nginx-proxy"
    refute_output --partial "network disconnect moodle-lab_moodle-network nginx-proxy"
}
