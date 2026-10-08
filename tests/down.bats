#!/usr/bin/env bats
# tests/down.bats — testes para commands/down.sh
#
# O "down" so derruba os containers: a rede do projeto e do cctl e fica (com a
# faixa reservada) enquanto o projeto esta parado; o nginx-proxy continua
# conectado a ela.
#
# Isolamento: docker/docker compose sempre mockados via bin/ temporario no
# PATH. Nenhum container, rede ou porta real e tocado.

bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh network.sh compose.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    export COMPOSE_PROJECT_NAME="testproj"
    export CCTL_PROJECT_NETWORK="testproj_net"
    export CCTL_LOG_DIR="${WORKDIR}/logs"
    export CCTL_LOG_FILE=""
    unset COMPOSE_FILES 2>/dev/null || true

    mock_docker_netsim "${WORKDIR}/docker_calls.log"
    netsim_add_network "testproj_net" "testproj" "10.240.0.0/24" "testproj.example.com"
    netsim_connect "testproj_net" "testproj.example.com"

    # shellcheck source=/dev/null
    source "${CCTL_ROOT}/commands/down.sh"
}

teardown() {
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

@test "cmd_down: roda o compose down do projeto" {
    run cmd_down
    assert_success
    grep -q "compose -f docker-compose.yml -p testproj down" "${WORKDIR}/docker_calls.log"
}

@test "cmd_down: NAO apaga a rede e NAO desconecta o nginx-proxy" {
    run cmd_down
    assert_success

    run ! grep -q "network rm" "${WORKDIR}/docker_calls.log"
    run ! grep -q "network disconnect" "${WORKDIR}/docker_calls.log"
    # estado real: a rede continua e o proxy continua ligado nela
    netsim_has_network "testproj_net"
    netsim_is_connected "testproj_net"
}

@test "cmd_down: repassa argumentos extras para compose_down" {
    run cmd_down -v
    assert_success
    grep -q "down -v" "${WORKDIR}/docker_calls.log"
}
