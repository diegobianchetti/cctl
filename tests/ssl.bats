#!/usr/bin/env bats
# tests/ssl.bats — testes para core_priv_run (lib/core.sh) via lib/ssl.sh
# (mkdir recursivo, cp/install de certificados) e para _ssl_issue_manual

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh core.sh nginx.sh ssl.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    # sudo mockado: registra que foi chamado e executa o comando de verdade
    mock_sudo_passthrough
    mock_cmd docker 'exit 0'
}

teardown() {
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && chmod -R 777 "${WORKDIR}" 2>/dev/null || true
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

# --- core_priv_run: mkdir --------------------------------------------------

@test "core_priv_run: mkdir -p recursivo nao usa sudo quando o primeiro ancestral existente e gravavel" {
    run core_priv_run mkdir -p "${WORKDIR}/a/b/c"
    assert_success
    [[ -d "${WORKDIR}/a/b/c" ]]
    [[ ! -f sudo.log ]]
}

@test "core_priv_run: mkdir -p recursivo usa sudo quando o primeiro ancestral existente nao e gravavel" {
    [[ "${EUID}" -eq 0 ]] && skip "root ignora permissoes de diretorio"

    mkdir -p base_ro
    chmod 555 base_ro

    run core_priv_run mkdir -p "${WORKDIR}/base_ro/x/y"
    chmod 755 base_ro

    [[ -f sudo.log ]]
}

@test "core_priv_run: mkdir -p sobe varios niveis ate achar ancestral existente" {
    mkdir -p existente
    run core_priv_run mkdir -p "${WORKDIR}/existente/nivel1/nivel2/nivel3"
    assert_success
    [[ -d "${WORKDIR}/existente/nivel1/nivel2/nivel3" ]]
    [[ ! -f sudo.log ]]
}

# --- core_priv_run: cp / install (origem/destino) --------------------------

@test "core_priv_run: cp nao usa sudo quando origem legivel e destino gravavel" {
    echo "cert" > cert.pem
    mkdir -p dest

    run core_priv_run cp cert.pem dest/fullchain.pem
    assert_success
    [[ -f dest/fullchain.pem ]]
    [[ ! -f sudo.log ]]
}

@test "core_priv_run: cp usa sudo quando a ORIGEM nao e legivel, mesmo com destino gravavel" {
    [[ "${EUID}" -eq 0 ]] && skip "root ignora permissoes de arquivo"

    echo "cert" > cert.pem
    chmod 000 cert.pem
    mkdir -p dest

    run core_priv_run cp cert.pem dest/fullchain.pem

    chmod 644 cert.pem
    [[ -f sudo.log ]]
}

@test "core_priv_run: cp usa sudo quando o destino ja existe e nao e gravavel" {
    [[ "${EUID}" -eq 0 ]] && skip "root ignora permissoes de arquivo"

    echo "novo" > cert.pem
    mkdir -p dest
    echo "velho" > dest/fullchain.pem
    chmod 444 dest/fullchain.pem

    run core_priv_run cp cert.pem dest/fullchain.pem || true

    chmod 644 dest/fullchain.pem
    [[ -f sudo.log ]]
}

@test "core_priv_run: install -m 600 nao usa sudo quando origem legivel e destino gravavel" {
    echo "chave" > key.pem
    mkdir -p dest

    run core_priv_run install -m 600 key.pem dest/privkey.pem
    assert_success
    [[ -f dest/privkey.pem ]]
    [[ ! -f sudo.log ]]

    local perms
    perms="$(stat -c '%a' dest/privkey.pem)"
    assert_equal "${perms}" "600"
}

@test "core_priv_run: install usa sudo quando a origem (chave privada) nao e legivel" {
    [[ "${EUID}" -eq 0 ]] && skip "root ignora permissoes de arquivo"

    echo "chave" > key.pem
    chmod 000 key.pem
    mkdir -p dest

    run core_priv_run install -m 600 key.pem dest/privkey.pem

    chmod 644 key.pem
    [[ -f sudo.log ]]
}

# --- _ssl_issue_manual (integracao) ----------------------------------------

@test "_ssl_issue_manual: instala certificado e chave sem sudo em diretorio gravavel" {
    echo "cert" > cert.pem
    echo "chave" > key.pem
    export SSL_CERT_FILE="${WORKDIR}/cert.pem"
    export SSL_KEY_FILE="${WORKDIR}/key.pem"
    export SSL_CERTS_DIR="${WORKDIR}/certs"

    run _ssl_issue_manual "app.example.com"
    assert_success
    [[ -f "${SSL_CERTS_DIR}/app.example.com/fullchain.pem" ]]
    [[ -f "${SSL_CERTS_DIR}/app.example.com/privkey.pem" ]]
    [[ ! -f sudo.log ]]
}

@test "_ssl_issue_manual: aborta quando o certificado de origem nao e legivel" {
    [[ "${EUID}" -eq 0 ]] && skip "root ignora permissoes de arquivo"

    echo "cert" > cert.pem
    chmod 000 cert.pem
    echo "chave" > key.pem
    export SSL_CERT_FILE="${WORKDIR}/cert.pem"
    export SSL_KEY_FILE="${WORKDIR}/key.pem"
    export SSL_CERTS_DIR="${WORKDIR}/certs"
    mock_cmd sudo 'exit 1'

    run _ssl_issue_manual "app.example.com"
    assert_failure
    assert_output --partial "Falha ao copiar certificado"

    chmod 644 cert.pem
}
