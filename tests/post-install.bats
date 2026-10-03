#!/usr/bin/env bats
# tests/post-install.bats — templates/moodle/scripts/post-install.sh
#
# Isolamento: sudo mockado, LOGROTATE_DIR apontando para dentro do WORKDIR.
# Nenhum arquivo real em /etc e tocado.

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1
    mkdir -p cron
    echo "/var/log/apache2/*.log { daily }" > cron/logrotate-apache

    export CCTL_ROOT
    export COMPOSE_PROJECT_NAME="moodle"
    export CCTL_LOG_DIR="${WORKDIR}/logs"
    export CCTL_LOG_FILE=""
    SCRIPT="${CCTL_ROOT}/templates/moodle/scripts/post-install.sh"
}

teardown() {
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && chmod -R 777 "${WORKDIR}" 2>/dev/null || true
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

@test "post-install moodle: logrotate instalado no destino -> rc 0" {
    export LOGROTATE_DIR="${WORKDIR}/logrotate.d"
    mkdir -p "${LOGROTATE_DIR}"

    run bash "${SCRIPT}" < /dev/null
    assert_success
    [[ -f "${LOGROTATE_DIR}/rotate-apache-logs-moodle" ]]
}

@test "post-install moodle: falha ao instalar o logrotate -> rc != 0, ERRO e comando manual na mensagem" {
    # destino nao gravavel e sudo negado: core_priv_run install falha de verdade
    # (como root o chmod 555 nao impede a escrita, entao o teste nao prova nada)
    [[ ${EUID} -ne 0 ]] || skip "rodando como root: diretorio nao gravavel nao bloqueia a escrita"
    export LOGROTATE_DIR="${WORKDIR}/logrotate.d"
    mkdir -p "${LOGROTATE_DIR}"
    chmod 555 "${LOGROTATE_DIR}"
    mock_sudo_deny "${WORKDIR}/sudo.log"

    run bash "${SCRIPT}" < /dev/null
    assert_failure
    assert_output --partial "ERRO"
    assert_output --partial "Instale manualmente como root: cp ./cron/logrotate-apache"
    [[ ! -e "${LOGROTATE_DIR}/rotate-apache-logs-moodle" ]]
}

@test "post-install moodle: sem arquivo de origem do logrotate -> rc 0" {
    rm -f cron/logrotate-apache
    export LOGROTATE_DIR="${WORKDIR}/logrotate.d"
    mkdir -p "${LOGROTATE_DIR}"

    run bash "${SCRIPT}" < /dev/null
    assert_success
}
