#!/usr/bin/env bats
# tests/network.bats — testes para lib/network.sh (mock de `docker network ...`)

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh network.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1
}

teardown() {
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

@test "network_list_for_project (uniao, regressao Blocker 2): rotulada E orfa sem label aparecem as duas" {
    # moodle_network tem label do compose; moodle_extra foi recriada a mao
    # e ficou sem label, mas casa o prefixo ancorado "^moodle_". Com o
    # antigo `if [[ -z ]]`, moodle_extra desaparece porque o ramo por
    # label ja devolveu algo.
    declare -A CCTL_TEST_NETS=(
        [moodle_network]="moodle"
        [moodle_extra]=""
        [moodle-lab_network]="moodle-lab"
    )
    mock_docker_with_networks CCTL_TEST_NETS "${WORKDIR}/docker_calls.log"

    run network_list_for_project "moodle"
    assert_success
    assert_output --partial "moodle_network"
    assert_output --partial "moodle_extra"
    refute_output --partial "moodle-lab_network"
}

@test "network_allocate_subnet: retorna a primeira subnet livre no range" {
    mock_cmd docker '
        if [[ "$1" == "network" && "$2" == "ls" ]]; then
            echo "netid1"
            exit 0
        fi
        if [[ "$1" == "network" && "$2" == "inspect" ]]; then
            echo "10.88.5.0/24"
            exit 0
        fi
        exit 0
    '
    export SUBNET_RANGE="10.88.0.0/16"
    export SUBNET_PREFIX_LEN="24"

    run network_allocate_subnet
    assert_success
    assert_output "10.88.1.0/24"
}

@test "network_allocate_subnet: pula subnets ja em uso" {
    mock_cmd docker '
        if [[ "$1" == "network" && "$2" == "ls" ]]; then
            echo "netid1"
            exit 0
        fi
        if [[ "$1" == "network" && "$2" == "inspect" ]]; then
            echo "10.88.1.0/24"
            exit 0
        fi
        exit 0
    '
    export SUBNET_RANGE="10.88.0.0/16"
    export SUBNET_PREFIX_LEN="24"

    run network_allocate_subnet
    assert_success
    assert_output "10.88.2.0/24"
}

@test "network_allocate_subnet: falha quando nenhuma rede docker existe (sem subnets usadas ainda aloca a primeira)" {
    mock_cmd docker '
        if [[ "$1" == "network" && "$2" == "ls" ]]; then
            exit 0
        fi
        exit 0
    '
    export SUBNET_RANGE="192.168.0.0/16"
    export SUBNET_PREFIX_LEN="24"

    run network_allocate_subnet
    assert_success
    assert_output "192.168.1.0/24"
}

@test "network_connect_nginx: chama docker network connect com alias quando DOMAIN_NAME definido" {
    mock_cmd docker '
        echo "docker $*" >> "'"${BATS_TEST_TMPDIR}"'/docker_calls.log"
        exit 0
    '
    export DOMAIN_NAME="app.example.com"
    export NGINX_CONTAINER_NAME="nginx-proxy"

    run network_connect_nginx "minha-rede"
    assert_success
    run cat "${BATS_TEST_TMPDIR}/docker_calls.log"
    assert_output --partial "network connect"
    assert_output --partial "--alias app.example.com"
    assert_output --partial "minha-rede nginx-proxy"
}

@test "network_disconnect_nginx: avisa mas nao falha quando container ja nao esta conectado" {
    mock_cmd docker 'exit 1'

    run network_disconnect_nginx "minha-rede"
    assert_success
    assert_output --partial "nao estava conectado"
}
