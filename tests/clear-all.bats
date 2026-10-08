#!/usr/bin/env bats
# tests/clear-all.bats — testes para commands/clear-all.sh (classe B1: colisao
# de prefixo de nome de projeto, ex. "moodle" vs "moodle-lab") aplicada a
# volumes Docker — ver lib/volumes.sh:volumes_list_for_project.
#
# Isolamento: docker/sudo sempre mockados via bin/ temporario no PATH. Nenhum
# volume, container ou rede real e tocado.

bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh core.sh inventory.sh network.sh volumes.sh compose.sh nginx.sh vhost.sh cron.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    export COMPOSE_PROJECT_NAME="moodle"
    export CCTL_INVENTORY_DIR="${WORKDIR}/inventory"
    unset CCTL_PROJECT_NETWORK
    export CCTL_LOG_DIR="${WORKDIR}/logs"
    export CCTL_LOG_FILE=""
    unset COMPOSE_FILES DOMAIN_NAME 2>/dev/null || true

    mock_sudo_passthrough "${WORKDIR}/sudo.log"
    mock_crontab_forbidden "${WORKDIR}/crontab.calls"
    export CRON_DIR="${WORKDIR}/cron.d"
    export LOGROTATE_DIR="${WORKDIR}/logrotate.d"
    mkdir -p "${CRON_DIR}" "${LOGROTATE_DIR}"

    # shellcheck source=/dev/null
    source "${CCTL_ROOT}/commands/clear-all.sh"
}

teardown() {
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

@test "cmd_clear-all (regressao B1): projeto 'moodle' nao remove volumes de 'moodle-lab' (colisao de prefixo)" {
    # Volumes criados a mao (sem label de compose) — mesmo cenario real de
    # B1: "moodle" (filtro solto) tambem casaria "moodle-lab_dbdata". Sem o
    # fix, este teste falha porque o `docker volume rm` tambem alcanca o
    # volume do moodle-lab.
    declare -A CCTL_TEST_VOLS=(
        [moodle_dbdata]=""
        [moodle-lab_dbdata]=""
    )
    mock_docker_with_volumes CCTL_TEST_VOLS "${WORKDIR}/docker_calls.log"

    run cmd_clear-all <<< "moodle"
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "volume rm"
    assert_output --partial "moodle_dbdata"
    refute_output --partial "moodle-lab_dbdata"
}

@test "cmd_clear-all: com label exato do compose, remove so os volumes do projeto certo" {
    declare -A CCTL_TEST_VOLS=(
        [moodle_dbdata]="moodle"
        [moodle_moodledata]="moodle"
        [moodle-lab_dbdata]="moodle-lab"
    )
    mock_docker_with_volumes CCTL_TEST_VOLS "${WORKDIR}/docker_calls.log"

    run cmd_clear-all <<< "moodle"
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "moodle_dbdata"
    assert_output --partial "moodle_moodledata"
    refute_output --partial "moodle-lab_dbdata"
}

@test "cmd_clear-all: confirmacao errada cancela sem tocar em nada" {
    declare -A CCTL_TEST_VOLS=( [moodle_dbdata]="moodle" )
    mock_docker_with_volumes CCTL_TEST_VOLS "${WORKDIR}/docker_calls.log"

    run cmd_clear-all <<< "nome-errado"
    assert_failure
    run cat "${WORKDIR}/docker_calls.log"
    refute_output --partial "volume rm"
}

@test "cmd_clear-all: remove logrotate via core_priv_run sem sudo quando LOGROTATE_DIR e gravavel" {
    declare -A CCTL_TEST_VOLS=( [moodle_dbdata]="moodle" )
    mock_docker_with_volumes CCTL_TEST_VOLS "${WORKDIR}/docker_calls.log"

    local logrotate_file="${LOGROTATE_DIR}/rotate-apache-logs-moodle"
    : > "${logrotate_file}"

    run cmd_clear-all <<< "moodle"
    assert_success
    [[ ! -f "${logrotate_file}" ]]
    # LOGROTATE_DIR ja era gravavel: a remocao do logrotate nao deveria ter
    # precisado de sudo (docker volume rm neste round nao chama mais sudo
    # diretamente — ver commands/clear-all.sh:40 e lib/volumes.sh:179 — entao
    # o caminho feliz nao deveria ter nenhuma chamada de sudo registrada).
    # A asserção precisa ser real: sudo.log so e criado quando o mock e
    # efetivamente invocado, entao "nao existe" e o resultado esperado aqui;
    # se existir (regressao futura chamando sudo em algum ponto), o conteudo
    # tem que ser inspecionado de verdade em vez de um `cat` vazio que faria
    # o refute_output passar sem checar nada.
    if [[ -f "${WORKDIR}/sudo.log" ]]; then
        run cat "${WORKDIR}/sudo.log"
        assert_success
        refute_output --partial "rm -f ${logrotate_file}"
    else
        # Caminho esperado: nenhuma chamada de sudo foi feita.
        true
    fi
}

@test "cmd_clear-all: falha ao remover volume retorna erro agregado, mesmo sem rede" {
    declare -A CCTL_TEST_VOLS=( [moodle_dbdata]="moodle" )
    mock_docker_with_volumes CCTL_TEST_VOLS "${WORKDIR}/docker_calls.log"
    export MOCK_VOLUME_RM_FAIL=1

    run cmd_clear-all <<< "moodle"
    assert_failure
    assert_output --partial "Falha ao remover um ou mais volumes"
    assert_output --partial "nao foi removido completamente"
}

@test "cmd_clear-all: falha ao remover logrotate retorna erro agregado" {
    declare -A CCTL_TEST_VOLS=()
    mock_docker_with_volumes CCTL_TEST_VOLS "${WORKDIR}/docker_calls.log"
    : > "${LOGROTATE_DIR}/rotate-apache-logs-moodle"
    core_priv_run() { return 1; }

    run cmd_clear-all <<< "moodle"
    assert_failure
    assert_output --partial "Falha ao remover ${LOGROTATE_DIR}/rotate-apache-logs-moodle"
    assert_output --partial "nao foi removido completamente"
}

# --- rede do projeto: o clear-all e o unico que a apaga ---------------------

@test "cmd_clear-all: desconecta o proxy, apaga a rede do projeto e limpa NETWORK/SUBNET do inventario" {
    mock_docker_netsim "${WORKDIR}/docker_calls.log"
    export CCTL_PROJECT_NETWORK="moodle_net"
    netsim_add_network "moodle_net" "moodle" "10.240.0.0/24" "moodle.example.com"
    netsim_connect "moodle_net" "moodle.example.com"
    # rede de OUTRO projeto, conectada ao proxy: nao pode ser tocada
    netsim_add_network "moodle-lab_net" "moodle-lab" "10.240.1.0/24" "lab.example.com"
    netsim_connect "moodle-lab_net" "lab.example.com"
    inventory_mark_installed "moodle" "moodle" "c" "moodle.example.com" "${WORKDIR}/inst" "moodle_net" "10.240.0.0/24"

    run cmd_clear-all <<< "moodle"
    assert_success

    grep -q "network disconnect moodle_net nginx-proxy" "${WORKDIR}/docker_calls.log"
    grep -q "network rm moodle_net" "${WORKDIR}/docker_calls.log"
    run ! netsim_has_network "moodle_net"
    run ! netsim_is_connected "moodle_net"

    # a rede do outro projeto continua la e ligada ao proxy
    run ! grep -q "moodle-lab_net" <(grep -E "network (rm|disconnect)" "${WORKDIR}/docker_calls.log")
    netsim_has_network "moodle-lab_net"
    netsim_is_connected "moodle-lab_net"

    inventory_read "moodle"
    [[ -z "${INV_NETWORK}" && -z "${INV_SUBNET}" ]]
    [[ "${INV_STATUS}" == "installed" ]]
}

@test "cmd_clear-all: falha ao limpar reserva em registro existente torna o teardown incompleto" {
    mock_docker_netsim "${WORKDIR}/docker_calls.log"
    export CCTL_PROJECT_NETWORK="moodle_net"
    netsim_add_network "moodle_net" "moodle" "10.240.0.0/24" "moodle.example.com"
    inventory_mark_installed "moodle" "moodle" "c" "moodle.example.com" "${WORKDIR}/inst" "moodle_net" "10.240.0.0/24"
    inventory_clear_network() { return 1; }

    run cmd_clear-all <<< "moodle"
    assert_failure
    assert_output --partial "falhou a limpeza da reserva"
    run ! netsim_has_network "moodle_net"
}

@test "cmd_clear-all: sem CCTL_PROJECT_NETWORK nao procura rede por nome nem apaga nenhuma" {
    mock_docker_netsim "${WORKDIR}/docker_calls.log"
    netsim_add_network "moodle_net" "moodle" "10.240.0.0/24"

    run cmd_clear-all <<< "moodle"
    assert_success
    assert_output --partial "Nenhuma rede registrada"
    run ! grep -q "network rm" "${WORKDIR}/docker_calls.log"
    netsim_has_network "moodle_net"
}

@test "cmd_clear-all: se o 'network rm' falha, NETWORK/SUBNET continuam no inventario e o aviso diz o que fazer" {
    mock_docker_netsim "${WORKDIR}/docker_calls.log"
    export CCTL_PROJECT_NETWORK="moodle_net"
    netsim_add_network "moodle_net" "moodle" "10.240.0.0/24" "moodle.example.com"
    netsim_fail_rm
    inventory_mark_installed "moodle" "moodle" "c" "moodle.example.com" "${WORKDIR}/inst" "moodle_net" "10.240.0.0/24"

    run cmd_clear-all <<< "moodle"
    assert_failure
    assert_output --partial "continua existindo"
    assert_output --partial "nao foi removido completamente"
    assert_output --partial "docker network rm moodle_net"

    inventory_read "moodle"
    [[ "${INV_NETWORK}" == "moodle_net" ]]
    [[ "${INV_SUBNET}" == "10.240.0.0/24" ]]
}
