#!/usr/bin/env bats
# tests/list.bats — testes para commands/list.sh (F2.4: le so o inventario,
# nunca varre o disco — R4)

bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/common'
    load_bats_libs
    source_lib colors.sh log.sh core.sh inventory.sh
    # shellcheck source=/dev/null
    source "${CCTL_ROOT}/commands/list.sh"

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    export CCTL_INVENTORY_DIR="${WORKDIR}/inventory"
}

teardown() {
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && chmod -R 777 "${WORKDIR}" 2>/dev/null || true
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

@test "cmd_list: sem inventario, avisa e nao falha" {
    run cmd_list
    assert_success
    assert_output --partial "nao existe"
}

@test "cmd_list: sem registros, informa inventario vazio" {
    mkdir -p "${CCTL_INVENTORY_DIR}"
    run cmd_list
    assert_success
    assert_output --partial "Nenhuma instancia registrada"
}

@test "cmd_list: mostra instancia prepared (cctl init, sem install ainda)" {
    local dir="${WORKDIR}/instances/app1"
    inventory_mark_prepared "app1" "moodle" "app1" "app1.example.com" "${dir}"

    run cmd_list
    assert_success
    assert_output --partial "app1"
    assert_output --partial "moodle"
    assert_output --partial "app1.example.com"
    assert_output --partial "prepared"
}

@test "cmd_list: mostra instancia installed criada com --dest fora da base (R4)" {
    local dir="/tmp/fora-da-base-$$"
    mkdir -p "${dir}"
    touch "${dir}/.cctl-instance"
    inventory_mark_installed "fora" "moodle" "fora" "fora.example.com" "${dir}"

    run cmd_list
    assert_success
    assert_output --partial "fora"
    assert_output --partial "installed"
    assert_output --partial "${dir}"

    rm -rf "${dir}"
}

@test "cmd_list: instancia stale (diretorio removido) aparece marcada, nao esconde as outras" {
    local dir_ok="${WORKDIR}/instances/app-ok"
    mkdir -p "${dir_ok}"
    touch "${dir_ok}/.cctl-instance"
    inventory_mark_installed "app-ok" "moodle" "app-ok" "ok.example.com" "${dir_ok}"

    inventory_mark_prepared "app-stale" "moodle" "app-stale" "stale.example.com" "${WORKDIR}/instances/nao-existe-mais"

    run cmd_list
    assert_success
    assert_output --partial "app-ok"
    assert_output --partial "app-stale"
    assert_output --partial "stale"
    # total conta os dois registros, com aviso para o stale
    assert_output --partial "2 registro(s), 1 com aviso"
}

@test "cmd_list: registro corrompido aparece como aviso sem derrubar a listagem" {
    mkdir -p "${CCTL_INVENTORY_DIR}"
    printf 'LIXO\tsem campos minimos\n' > "${CCTL_INVENTORY_DIR}/quebrado.tsv"

    local dir="${WORKDIR}/instances/app-ok"
    mkdir -p "${dir}"
    touch "${dir}/.cctl-instance"
    inventory_mark_installed "app-ok" "moodle" "app-ok" "ok.example.com" "${dir}"

    run cmd_list
    assert_success
    assert_output --partial "app-ok"
    assert_output --partial "quebrado"
    assert_output --partial "corrompido"
}
