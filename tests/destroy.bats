#!/usr/bin/env bats
# tests/destroy.bats — testes para commands/destroy.sh (F2.4: ordem entre
# remocao do diretorio e remocao do registro de inventario)
#
# Isolamento: cmd_clear-all e stubado (fake CCTL_ROOT/commands/clear-all.sh)
# para nao puxar compose/docker/network/cron reais — o que importa aqui e
# so o comportamento de destroy.sh em si: confirmacao, remocao do diretorio
# e a ordem com inventory_remove.

bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh core.sh inventory.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    export CCTL_INVENTORY_DIR="${WORKDIR}/inventory"
    mock_sudo_passthrough

    # Stub de cmd_clear-all: destroy.sh faz
    # "source \"${CCTL_ROOT}/commands/clear-all.sh\"" com CCTL_ROOT real do
    # projeto no momento do source do PROPRIO destroy.sh (abaixo). Para
    # isolar do compose/docker/network real, trocamos CCTL_ROOT por um
    # diretorio fake SO na hora de chamar cmd_destroy (dentro do @test).
    FAKE_CCTL_ROOT="${WORKDIR}/fake-cctl-root"
    mkdir -p "${FAKE_CCTL_ROOT}/commands"
    cat > "${FAKE_CCTL_ROOT}/commands/clear-all.sh" <<'EOF'
cmd_clear-all() {
    echo "STUB-CLEAR-ALL-CHAMADO"
}
EOF

    # shellcheck source=/dev/null
    source "${CCTL_ROOT}/commands/destroy.sh"

    export INSTANCE_DIR="${WORKDIR}/instances/app1"
    mkdir -p "${INSTANCE_DIR}"
    touch "${INSTANCE_DIR}/.cctl-instance"
}

teardown() {
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && chmod -R 777 "${WORKDIR}" 2>/dev/null || true
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

@test "cmd_destroy: confirmacao correta remove diretorio E registro de inventario" {
    export COMPOSE_PROJECT_NAME="app1"
    inventory_mark_installed "app1" "moodle" "app1" "app1.example.com" "${INSTANCE_DIR}"
    [[ -f "${CCTL_INVENTORY_DIR}/app1.tsv" ]]

    cd "${INSTANCE_DIR}" || return 1

    run bash -c '
        source "'"${CCTL_ROOT}"'/lib/colors.sh"
        source "'"${CCTL_ROOT}"'/lib/log.sh"
        source "'"${CCTL_ROOT}"'/lib/core.sh"
        source "'"${CCTL_ROOT}"'/lib/inventory.sh"
        export CCTL_ROOT="'"${FAKE_CCTL_ROOT}"'"
        export CCTL_INVENTORY_DIR="'"${CCTL_INVENTORY_DIR}"'"
        source "'"${CCTL_ROOT}"'/commands/destroy.sh"
        echo "app1" | cmd_destroy
    '
    assert_success
    assert_output --partial "STUB-CLEAR-ALL-CHAMADO"
    assert_output --partial "destruida completamente"

    [[ ! -d "${INSTANCE_DIR}" ]]
    [[ ! -f "${CCTL_INVENTORY_DIR}/app1.tsv" ]]
}

@test "cmd_destroy: confirmacao errada cancela -- diretorio e registro preservados" {
    export COMPOSE_PROJECT_NAME="app1"
    inventory_mark_installed "app1" "moodle" "app1" "app1.example.com" "${INSTANCE_DIR}"

    cd "${INSTANCE_DIR}" || return 1

    run bash -c '
        source "'"${CCTL_ROOT}"'/lib/colors.sh"
        source "'"${CCTL_ROOT}"'/lib/log.sh"
        source "'"${CCTL_ROOT}"'/lib/core.sh"
        source "'"${CCTL_ROOT}"'/lib/inventory.sh"
        export CCTL_ROOT="'"${FAKE_CCTL_ROOT}"'"
        export CCTL_INVENTORY_DIR="'"${CCTL_INVENTORY_DIR}"'"
        source "'"${CCTL_ROOT}"'/commands/destroy.sh"
        echo "nome-errado" | cmd_destroy
    '
    assert_failure
    refute_output --partial "STUB-CLEAR-ALL-CHAMADO"

    [[ -d "${INSTANCE_DIR}" ]]
    [[ -f "${CCTL_INVENTORY_DIR}/app1.tsv" ]]
}

@test "cmd_destroy (F2.4): falha ao remover o diretorio preserva o registro de inventario" {
    export COMPOSE_PROJECT_NAME="app1"
    inventory_mark_installed "app1" "moodle" "app1" "app1.example.com" "${INSTANCE_DIR}"

    cd "${INSTANCE_DIR}" || return 1

    # torna o PAI do diretorio da instancia nao-gravavel e nega sudo: simula
    # falha real de remocao (core_priv_run rm -rf retorna 1)
    chmod 555 "${WORKDIR}/instances"
    mock_sudo_deny

    run bash -c '
        source "'"${CCTL_ROOT}"'/lib/colors.sh"
        source "'"${CCTL_ROOT}"'/lib/log.sh"
        source "'"${CCTL_ROOT}"'/lib/core.sh"
        source "'"${CCTL_ROOT}"'/lib/inventory.sh"
        export CCTL_ROOT="'"${FAKE_CCTL_ROOT}"'"
        export CCTL_INVENTORY_DIR="'"${CCTL_INVENTORY_DIR}"'"
        source "'"${CCTL_ROOT}"'/commands/destroy.sh"
        echo "app1" | cmd_destroy
    '
    assert_success
    assert_output --partial "remova manualmente"

    chmod 755 "${WORKDIR}/instances"

    [[ -d "${INSTANCE_DIR}" ]]
    [[ -f "${CCTL_INVENTORY_DIR}/app1.tsv" ]]
}
