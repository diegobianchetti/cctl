#!/usr/bin/env bats
# tests/up.bats — testes para commands/up.sh (garantir a rede antes do compose up)
#
# Isolamento: docker/ip mockados (mock_docker_netsim guarda o estado das
# redes); nenhum container, rede ou rota real e tocado.

bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh core.sh env.sh inventory.sh network.sh compose.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    export CCTL_INVENTORY_DIR="${WORKDIR}/inventory"
    export NGINX_CONTAINER_NAME="nginx-proxy"
    export COMPOSE_PROJECT_NAME="app"
    export DOMAIN_NAME="app.example.com"
    export CCTL_PROJECT_NETWORK="app_net"
    export COMPOSE_PROJECT_SUBNET="10.240.4.0/24"
    export CCTL_LOG_DIR="${WORKDIR}/logs"
    export CCTL_LOG_FILE=""
    unset COMPOSE_FILES 2>/dev/null || true

    setup_network_env
    mock_docker_netsim "${WORKDIR}/docker_calls.log"

    # shellcheck source=/dev/null
    source "${CCTL_ROOT}/commands/up.sh"
    # shellcheck source=/dev/null
    source "${CCTL_ROOT}/commands/update.sh"
}

teardown() {
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

@test "cmd_up: rede existe -> compose up roda, sem criar rede" {
    netsim_add_network "app_net" "app" "10.240.4.0/24" "app.example.com"
    netsim_connect "app_net" "app.example.com"

    run cmd_up
    assert_success
    grep -q "compose -f docker-compose.yml -p app up -d" "${WORKDIR}/docker_calls.log"
    run ! grep -q "network create" "${WORKDIR}/docker_calls.log"
}

@test "cmd_up: rede ausente e faixa livre -> recria com a mesma subnet ANTES do compose up" {
    run cmd_up
    assert_success

    [[ "$(netsim_subnet app_net)" == "10.240.4.0/24" ]]
    local create_line up_line
    create_line=$(grep -n "network create" "${WORKDIR}/docker_calls.log" | head -1 | cut -d: -f1)
    up_line=$(grep -n "compose .* up -d" "${WORKDIR}/docker_calls.log" | head -1 | cut -d: -f1)
    [[ -n "${create_line}" && -n "${up_line}" ]]
    (( create_line < up_line ))
}

@test "cmd_up: rede ausente e faixa tomada -> rc != 0, mensagem clara e compose up NAO chamado" {
    netsim_add_network "intrusa" "" "10.240.4.0/24"

    run cmd_up
    assert_failure
    assert_output --partial "foi tomada"
    assert_output --partial "intrusa"
    run ! grep -q "compose" "${WORKDIR}/docker_calls.log"
    run ! grep -q "network create" "${WORKDIR}/docker_calls.log"
}

@test "cmd_up: instancia sem rede registrada -> rc != 0 e compose up NAO chamado" {
    unset CCTL_PROJECT_NETWORK COMPOSE_PROJECT_SUBNET

    run cmd_up
    assert_failure
    assert_output --partial "cctl destroy"
    run ! grep -q "compose" "${WORKDIR}/docker_calls.log"
}

@test "cmd_up: repassa argumentos extras para o compose up" {
    netsim_add_network "app_net" "app" "10.240.4.0/24" "app.example.com"
    netsim_connect "app_net"

    run cmd_up --build
    assert_success
    grep -q "up -d --build" "${WORKDIR}/docker_calls.log"
}

@test "cmd_update: rede ausente e faixa livre -> recria a rede ANTES do compose up --force-recreate" {
    run cmd_update
    assert_success
    [[ "$(netsim_subnet app_net)" == "10.240.4.0/24" ]]
    local create_line up_line
    create_line=$(grep -n "network create" "${WORKDIR}/docker_calls.log" | head -1 | cut -d: -f1)
    up_line=$(grep -n "up -d --force-recreate" "${WORKDIR}/docker_calls.log" | head -1 | cut -d: -f1)
    [[ -n "${create_line}" && -n "${up_line}" ]]
    (( create_line < up_line ))
}

@test "cmd_update: rede ausente e faixa tomada -> rc != 0 e compose up NAO chamado" {
    netsim_add_network "intrusa" "" "10.240.4.0/24"

    run cmd_update
    assert_failure
    assert_output --partial "foi tomada"
    run ! grep -q "up -d" "${WORKDIR}/docker_calls.log"
}

@test "cmd_up: proxy existente com conexao recusada falha e nao chama compose up" {
    netsim_add_network "app_net" "app" "10.240.4.0/24" "app.example.com"
    netsim_fail_connect "app_net"

    run cmd_up
    assert_failure
    assert_output --partial "nginx-proxy existe"
    run ! grep -q "compose .* up -d" "${WORKDIR}/docker_calls.log"
}

@test "cmd_update: proxy existente com conexao recusada falha e nao chama compose up" {
    netsim_add_network "app_net" "app" "10.240.4.0/24" "app.example.com"
    netsim_fail_connect "app_net"

    run cmd_update
    assert_failure
    assert_output --partial "nginx-proxy existe"
    run ! grep -q "compose .* up -d" "${WORKDIR}/docker_calls.log"
}
