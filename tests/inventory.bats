#!/usr/bin/env bats
# tests/inventory.bats — testes para lib/inventory.sh (F2.4)
#
# Isolamento: CCTL_INVENTORY_DIR sempre dentro do WORKDIR temporario (nunca
# toca /opt/cctl). sudo e mockado como passthrough (grava de fato, so
# registra a chamada) para exercitar o caminho core_priv_run sem exigir
# privilegio real.

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
}

teardown() {
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && chmod -R 777 "${WORKDIR}" 2>/dev/null || true
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

# ============================================================
# inventory_upsert / mark_prepared / mark_installed
# ============================================================

@test "inventory_mark_prepared: cria registro com STATUS=prepared" {
    run inventory_mark_prepared "app1" "moodle" "app1" "app1.example.com" "${WORKDIR}/instances/app1"
    assert_success

    [[ -f "${CCTL_INVENTORY_DIR}/app1.tsv" ]]
    run grep -q $'STATUS\tprepared' "${CCTL_INVENTORY_DIR}/app1.tsv"
    assert_success
}

@test "inventory_mark_installed: cria registro novo direto em installed (adocao, sem prepared previo)" {
    run inventory_mark_installed "app1" "moodle" "app1" "app1.example.com" "${WORKDIR}/instances/app1"
    assert_success

    run grep -q $'STATUS\tinstalled' "${CCTL_INVENTORY_DIR}/app1.tsv"
    assert_success
}

@test "inventory_mark_installed: atualiza um registro prepared existente para installed" {
    local dir="${WORKDIR}/instances/app1"

    inventory_mark_prepared "app1" "moodle" "app1" "app1.example.com" "${dir}"
    run inventory_mark_installed "app1" "moodle" "app1" "app1.example.com" "${dir}"
    assert_success

    run grep -q $'STATUS\tinstalled' "${CCTL_INVENTORY_DIR}/app1.tsv"
    assert_success
    # so deve existir UM arquivo de registro para este projeto (update, nao
    # um segundo registro)
    [[ "$(find "${CCTL_INVENTORY_DIR}" -maxdepth 1 -name 'app1.tsv' | wc -l)" -eq 1 ]]
}

@test "inventory_upsert: preserva CREATED_AT e atualiza UPDATED_AT numa atualizacao" {
    local dir="${WORKDIR}/instances/app1"

    inventory_mark_prepared "app1" "moodle" "app1" "app1.example.com" "${dir}"
    inventory_read "app1"
    local created_1="${INV_CREATED_AT}"

    sleep 1
    inventory_mark_installed "app1" "moodle" "app1" "app1.example.com" "${dir}"
    inventory_read "app1"

    [[ "${INV_CREATED_AT}" == "${created_1}" ]]
    [[ "${INV_UPDATED_AT}" != "${created_1}" ]]
}

@test "inventory_upsert: colisao de nome com instance_dir diferente falha e NAO sobrescreve" {
    mkdir -p "${WORKDIR}/instances/app1-original"
    inventory_mark_prepared "app1" "moodle" "app1" "app1.example.com" "${WORKDIR}/instances/app1-original"

    run inventory_upsert "app1" "moodle" "app1" "outro.example.com" "${WORKDIR}/instances/app1-outro" "prepared"
    assert_failure
    assert_output --partial "Colisao de inventario"

    inventory_read "app1"
    [[ "${INV_INSTANCE_DIR}" == "${WORKDIR}/instances/app1-original" ]]
    [[ "${INV_DOMAIN_NAME}" == "app1.example.com" ]]
}

@test "inventory_upsert: reaplicar o MESMO instance_dir nao e colisao (idempotente)" {
    local dir="${WORKDIR}/instances/app1"
    inventory_mark_prepared "app1" "moodle" "app1" "app1.example.com" "${dir}"

    run inventory_mark_prepared "app1" "moodle" "app1" "app1.example.com" "${dir}"
    assert_success
}

@test "inventory_upsert: substitui registro stale apontando para destino removido" {
    local old_dir="${WORKDIR}/instances/antigo"
    local new_dir="${WORKDIR}/instances/novo"
    inventory_mark_prepared "app1" "moodle" "app1" "app1.example.com" "${old_dir}"

    run inventory_mark_prepared "app1" "moodle" "app1" "novo.example.com" "${new_dir}"
    assert_success
    assert_output --partial "stale"

    inventory_read "app1"
    [[ "${INV_INSTANCE_DIR}" == "${new_dir}" ]]
    [[ "${INV_DOMAIN_NAME}" == "novo.example.com" ]]
}

@test "inventory_upsert: compara caminhos canonicos quando um acesso usa symlink" {
    local real_dir="${WORKDIR}/instances/real"
    local link_dir="${WORKDIR}/instances/link"
    mkdir -p "${real_dir}"
    ln -s "${real_dir}" "${link_dir}"

    inventory_mark_prepared "app1" "moodle" "app1" "app1.example.com" "${real_dir}"
    run inventory_mark_installed "app1" "moodle" "app1" "app1.example.com" "${link_dir}"
    assert_success
}

@test "inventory_upsert: rejeita chave de projeto insegura e status desconhecido" {
    run inventory_upsert "../escape" "moodle" "app1" "app1.example.com" "${WORKDIR}/app" "prepared"
    assert_failure

    run inventory_upsert "app1" "moodle" "app1" "app1.example.com" "${WORKDIR}/app" "unknown"
    assert_failure
    [[ ! -e "${WORKDIR}/escape.tsv" ]]
}

@test "inventory_upsert: falha com instance_dir vazio e nao cria arquivo" {
    run inventory_upsert "app1" "moodle" "app1" "app1.example.com" "" "prepared"
    assert_failure
    [[ ! -f "${CCTL_INVENTORY_DIR}/app1.tsv" ]]
}

@test "inventory_upsert: sanitiza tab/newline nos campos (nao corrompe o formato)" {
    run inventory_mark_prepared "app1" "moodle" $'cliente\tcom\ttab' $'dominio\ncom\nnewline' "${WORKDIR}/instances/app1"
    assert_success

    # exatamente 10 campos reconhecidos (8 + NETWORK/SUBNET) — nenhum
    # tab/newline do valor sanitizado injetou uma 11a linha ou quebrou uma
    # chave em duas.
    # Pattern com tab literal via $'...' (bash expande \t antes do grep
    # ver o argumento) — -E deste host (ugrep) nao interpreta \t como
    # escape de regex.
    run grep -cE $'^[A-Z_]+\t' "${CCTL_INVENTORY_DIR}/app1.tsv"
    assert_output "10"

    inventory_read "app1"
    assert_success
    [[ "${INV_CLIENT_NAME}" == "cliente com tab" ]]
    [[ "${INV_DOMAIN_NAME}" == "dominio com newline" ]]
}

@test "inventory_upsert: escrita e atomica -- falha de core_priv_run nao deixa lixo nem apaga o registro anterior" {
    local dir="${WORKDIR}/instances/app1"
    inventory_mark_prepared "app1" "moodle" "app1" "app1.example.com" "${dir}"

    # torna o diretorio do inventario somente-leitura para o usuario atual
    # E faz o sudo mockado negar: simula falha real de core_priv_run cp/mv
    chmod 555 "${CCTL_INVENTORY_DIR}"
    mock_sudo_deny

    run inventory_mark_installed "app1" "moodle" "app1" "app1.example.com" "${dir}"
    assert_failure

    chmod 755 "${CCTL_INVENTORY_DIR}"

    # registro antigo intacto (ainda prepared) -- nao ficou parcialmente escrito
    run grep -q $'STATUS\tprepared' "${CCTL_INVENTORY_DIR}/app1.tsv"
    assert_success
    # nenhum temp-file sobrou no /tmp ou no diretorio do inventario
    [[ -z "$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'cctl_inventory.*' 2>/dev/null)" ]]
    [[ -z "$(find "${CCTL_INVENTORY_DIR}" -maxdepth 1 -name '*.tmp.*' 2>/dev/null)" ]]
}

# ============================================================
# inventory_remove
# ============================================================

@test "inventory_remove: remove o arquivo de registro" {
    inventory_mark_prepared "app1" "moodle" "app1" "app1.example.com" "${WORKDIR}/instances/app1"
    [[ -f "${CCTL_INVENTORY_DIR}/app1.tsv" ]]

    run inventory_remove "app1"
    assert_success
    [[ ! -f "${CCTL_INVENTORY_DIR}/app1.tsv" ]]
}

@test "inventory_remove: registro inexistente e um no-op bem-sucedido" {
    run inventory_remove "nao-existe"
    assert_success
}

# ============================================================
# inventory_list
# ============================================================

@test "inventory_list: sem CCTL_INVENTORY_DIR nao emite nada e nao falha" {
    run inventory_list
    assert_success
    [[ -z "${output}" ]]
}

@test "inventory_list: instancia com instance_dir existente e .cctl-instance -> STATE=ok" {
    local dir="${WORKDIR}/instances/app1"
    mkdir -p "${dir}"
    touch "${dir}/.cctl-instance"
    inventory_mark_installed "app1" "moodle" "app1" "app1.example.com" "${dir}"

    run inventory_list
    assert_success
    assert_output --partial $'app1\tmoodle\tapp1\tapp1.example.com\t'"${dir}"$'\tinstalled\tok'
}

@test "inventory_list: instance_dir inexistente -> STATE=stale" {
    inventory_mark_prepared "app1" "moodle" "app1" "app1.example.com" "${WORKDIR}/instances/nao-existe"

    run inventory_list
    assert_success
    assert_output --partial "stale"
}

@test "inventory_list: STATUS=installed sem .cctl-instance no diretorio -> STATE=stale" {
    local dir="${WORKDIR}/instances/app1"
    mkdir -p "${dir}"
    # sem .cctl-instance de proposito
    inventory_mark_installed "app1" "moodle" "app1" "app1.example.com" "${dir}"

    run inventory_list
    assert_success
    assert_output --partial "stale"
}

@test "inventory_list: registro corrompido nao aborta a listagem dos demais" {
    mkdir -p "${CCTL_INVENTORY_DIR}"
    printf 'LIXO\tsem campos minimos\n' > "${CCTL_INVENTORY_DIR}/quebrado.tsv"

    local dir="${WORKDIR}/instances/app-ok"
    mkdir -p "${dir}"
    touch "${dir}/.cctl-instance"
    inventory_mark_installed "app-ok" "moodle" "app-ok" "ok.example.com" "${dir}"

    run inventory_list
    assert_success
    assert_output --partial "corrupted"
    assert_output --partial "app-ok"
    assert_output --partial $'\tok'
}

# --- NETWORK / SUBNET (rede do projeto) ---------------------------------------

@test "inventory: registro novo nasce com NETWORK e SUBNET vazios" {
    inventory_mark_prepared "app1" "moodle" "c" "app1.example.com" "${WORKDIR}/instances/app1"
    inventory_read "app1"
    [[ -z "${INV_NETWORK}" && -z "${INV_SUBNET}" ]]
}

@test "inventory_set_network: grava rede e faixa sem mexer no resto do registro" {
    inventory_mark_prepared "app1" "moodle" "cli" "app1.example.com" "${WORKDIR}/instances/app1"
    inventory_read "app1"
    local created="${INV_CREATED_AT}"

    run inventory_set_network "app1" "app1_net" "10.240.3.0/24"
    assert_success

    inventory_read "app1"
    [[ "${INV_NETWORK}" == "app1_net" ]]
    [[ "${INV_SUBNET}" == "10.240.3.0/24" ]]
    [[ "${INV_STATUS}" == "prepared" ]]
    [[ "${INV_CLIENT_NAME}" == "cli" ]]
    [[ "${INV_DOMAIN_NAME}" == "app1.example.com" ]]
    [[ "${INV_CREATED_AT}" == "${created}" ]]
}

@test "inventory_set_network: sem registro previo -> rc 1 e nada e criado" {
    run inventory_set_network "naoexiste" "x_net" "10.240.3.0/24"
    assert_failure
    [[ ! -e "${CCTL_INVENTORY_DIR}/naoexiste.tsv" ]]
}

@test "inventory: mark_installed e mark_prepared PRESERVAM a rede ja gravada" {
    inventory_mark_prepared "app1" "moodle" "c" "app1.example.com" "${WORKDIR}/instances/app1"
    inventory_set_network "app1" "app1_net" "10.240.3.0/24"

    inventory_mark_installed "app1" "moodle" "c" "app1.example.com" "${WORKDIR}/instances/app1"
    inventory_read "app1"
    [[ "${INV_STATUS}" == "installed" ]]
    [[ "${INV_NETWORK}" == "app1_net" ]]
    [[ "${INV_SUBNET}" == "10.240.3.0/24" ]]
}

@test "inventory_mark_installed: rede informada no 6o/7o argumento e gravada (adocao sem registro previo)" {
    inventory_mark_installed "app1" "moodle" "c" "app1.example.com" "${WORKDIR}/instances/app1" "app1_net" "10.240.3.0/24"
    inventory_read "app1"
    [[ "${INV_NETWORK}" == "app1_net" ]]
    [[ "${INV_SUBNET}" == "10.240.3.0/24" ]]
}

@test "inventory_clear_network: limpa NETWORK/SUBNET e mantem o registro" {
    inventory_mark_installed "app1" "moodle" "c" "app1.example.com" "${WORKDIR}/instances/app1" "app1_net" "10.240.3.0/24"

    run inventory_clear_network "app1"
    assert_success
    inventory_read "app1"
    [[ -z "${INV_NETWORK}" && -z "${INV_SUBNET}" ]]
    [[ "${INV_STATUS}" == "installed" ]]
}

@test "inventory_read: registro antigo (sem as linhas NETWORK/SUBNET) continua valido, com campos vazios" {
    mkdir -p "${CCTL_INVENTORY_DIR}"
    printf 'PROJECT_NAME\told\nPROJECT_TYPE\tmoodle\nCLIENT_NAME\tc\nDOMAIN_NAME\td.example.com\nINSTANCE_DIR\t%s\nSTATUS\tinstalled\nCREATED_AT\tx\nUPDATED_AT\ty\n' \
        "${WORKDIR}/instances/old" > "${CCTL_INVENTORY_DIR}/old.tsv"

    run inventory_read "old"
    assert_success
    inventory_read "old"
    [[ -z "${INV_NETWORK}" && -z "${INV_SUBNET}" ]]
}

@test "inventory_network_list: NAME STATUS NETWORK SUBNET por registro; lista nao muda o contrato do inventory_list" {
    inventory_mark_installed "aa" "moodle" "c" "aa.example.com" "${WORKDIR}/i/aa" "aa_net" "10.240.0.0/24"
    inventory_mark_prepared "bb" "moodle" "c" "bb.example.com" "${WORKDIR}/i/bb"

    run inventory_network_list
    assert_success
    assert_line $'aa\tinstalled\taa_net\t10.240.0.0/24'
    assert_line $'bb\tprepared\t\t'

    # inventory_list continua com 9 colunas
    run inventory_list
    assert_success
    local first
    # (stderr vem junto no output do `run`: pega so uma linha de dados TSV)
    first="$(grep -m1 $'\t' <<< "${output}")"
    [[ "$(awk -F'\t' '{print NF}' <<< "${first}")" -eq 9 ]]
}
