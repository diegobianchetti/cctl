#!/usr/bin/env bats
# tests/cron.bats — testes para lib/cron.sh
#
# Cobre: instalacao dos jobs em CRON_DIR (via core_priv_run), falha quando a
# instalacao nao e possivel (cron_install retorna 1 e nao tenta crontab de
# usuario), remocao/listagem so em CRON_DIR, e a regressao de colisao por
# substring (cron_list/cron_remove nao podem casar "moodle-lab" quando o
# projeto e "moodle").
#
# Isolamento: sudo e crontab sempre mockados via bin/ temporario no PATH —
# nenhuma crontab real, /etc/cron.d real ou o host sao tocados.

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh core.sh cron.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    export COMPOSE_PROJECT_NAME="moodle"
    export CCTL_LOG_DIR="${WORKDIR}/logs"
    export CCTL_LOG_FILE=""
    export CRON_DIR="${WORKDIR}/cron.d"
    mkdir -p "${CRON_DIR}"

    mkdir -p ./cron
    cat > ./cron/exec-cron-moodle.cron <<'EOF'
SHELL=/bin/sh
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

* * * * * root	/usr/bin/docker compose -p moodle exec moodle-app bash -c "/usr/local/bin/cron-moodle.sh"
EOF
}

teardown() {
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

@test "cron_install: CRON_DIR gravavel instala o job com modo 644, sem chamar sudo nem crontab" {
    mock_sudo_passthrough "${WORKDIR}/sudo.log"
    mock_crontab_forbidden "${WORKDIR}/crontab.calls"

    run cron_install
    assert_success

    local dest="${CRON_DIR}/exec-cron-moodle-moodle"
    [[ -f "${dest}" ]]
    assert_output --partial "Cron instalado: ${dest}"
    # conteudo copiado de verdade e modo 644
    cmp -s ./cron/exec-cron-moodle.cron "${dest}"
    [[ "$(stat -c '%a' "${dest}")" == "644" ]]

    # sudo nao deve ter sido chamado (CRON_DIR ja era gravavel)
    [[ ! -s "${WORKDIR}/sudo.log" ]]
    [[ ! -s "${WORKDIR}/crontab.calls" ]]
}

@test "cron_install: core_priv_run falhando -> rc 1, erro acionavel e nenhuma chamada a crontab" {
    mock_crontab_forbidden "${WORKDIR}/crontab.calls"
    core_priv_run() { return 1; }

    run cron_install
    assert_failure
    assert_output --partial "NAO foi agendado"
    assert_output --partial "${CRON_DIR}/exec-cron-moodle-moodle"
    refute_output --partial "Cron instalado"

    [[ ! -e "${CRON_DIR}/exec-cron-moodle-moodle" ]]
    # nao pode ter caido em crontab de usuario
    [[ ! -s "${WORKDIR}/crontab.calls" ]]
}

@test "cron_install: um job falha e outro funciona -> rc 1 (nao reporta sucesso pela metade)" {
    cat > ./cron/outro.cron <<'EOF'
0 3 * * * root /bin/true
EOF
    # falha so para o job "outro"; os demais sao instalados de verdade
    core_priv_run() {
        [[ "$*" == *outro-moodle* ]] && return 1
        "$@"
    }

    run cron_install
    assert_failure
    [[ -f "${CRON_DIR}/exec-cron-moodle-moodle" ]]
    [[ ! -e "${CRON_DIR}/outro-moodle" ]]
}

@test "cron_remove/cron_list: operam so em CRON_DIR, sem chamar crontab" {
    mock_sudo_passthrough "${WORKDIR}/sudo.log"
    mock_crontab_forbidden "${WORKDIR}/crontab.calls"

    cat > "${CRON_DIR}/exec-cron-moodle-moodle" <<'EOF'
SHELL=/bin/sh
* * * * * root /bin/true
EOF

    run cron_list
    assert_success
    assert_output --partial "exec-cron-moodle-moodle"

    run cron_remove
    assert_success
    assert_output --partial "removido"
    [[ ! -f "${CRON_DIR}/exec-cron-moodle-moodle" ]]

    run cron_list
    assert_success
    assert_output --partial "Nenhum cron job encontrado"

    [[ ! -s "${WORKDIR}/crontab.calls" ]]
}

@test "cron_list/cron_remove (regressao colisao): projeto 'moodle' nao casa 'moodle-lab'" {
    mock_sudo_passthrough "${WORKDIR}/sudo.log"

    cat > "${CRON_DIR}/exec-cron-moodle-moodle" <<'EOF'
* * * * * root /bin/true
EOF
    cat > "${CRON_DIR}/exec-cron-moodle-moodle-lab" <<'EOF'
* * * * * root /bin/true
EOF

    run cron_list
    assert_success
    assert_output --partial "exec-cron-moodle-moodle"
    refute_output --partial "moodle-lab"

    run cron_remove
    assert_success
    # Arquivo do outro projeto continua no lugar
    [[ -f "${CRON_DIR}/exec-cron-moodle-moodle-lab" ]]
    [[ ! -f "${CRON_DIR}/exec-cron-moodle-moodle" ]]
}

@test "cron_list/cron_remove (regressao B1, direcao oposta): projeto 'moodle' nao casa 'prod-moodle'" {
    # Direcao complementar ao teste de 'moodle-lab' acima: ali o nome do
    # OUTRO projeto tinha o projeto atual como PREFIXO ("moodle-lab"); aqui
    # o nome do projeto atual e SUFIXO do outro ("prod-moodle"). O glob
    # antigo "${CRON_DIR}/*-${prefix}" ancora so a direita — "*-moodle"
    # tambem casa "exec-cron-moodle-prod-moodle" — e sob esse glob
    # cron_remove apagaria o cron do projeto errado.
    mock_sudo_passthrough "${WORKDIR}/sudo.log"

    cat > "${CRON_DIR}/exec-cron-moodle-moodle" <<'EOF'
* * * * * root /bin/true
EOF
    cat > "${CRON_DIR}/exec-cron-moodle-prod-moodle" <<'EOF'
* * * * * root /bin/true
EOF

    run cron_list
    assert_success
    assert_output --partial "exec-cron-moodle-moodle"
    refute_output --partial "prod-moodle"

    run cron_remove
    assert_success
    [[ ! -f "${CRON_DIR}/exec-cron-moodle-moodle" ]]
    # Arquivo do "prod-moodle" tem que sobreviver — este e o assert que
    # falha (rm destrutivo) contra o glob antigo e passa com nome exato.
    [[ -f "${CRON_DIR}/exec-cron-moodle-prod-moodle" ]]
}

@test "cron_remove (B3b): rm falhando no arquivo de sistema nao conta como removido nem reporta sucesso mentiroso" {
    mock_cmd rm '
        for a in "$@"; do
            [[ "${a}" == *exec-cron-moodle-moodle ]] && { echo "rm mockado: falha forcada" >&2; exit 1; }
        done
        exec /bin/rm "$@"
    '

    cat > "${CRON_DIR}/exec-cron-moodle-moodle" <<'EOF'
* * * * * root /bin/true
EOF

    run cron_remove
    assert_success
    # O arquivo continua no disco porque o rm mockado falhou de proposito.
    [[ -f "${CRON_DIR}/exec-cron-moodle-moodle" ]]
    # Nao pode reportar "1 cron job(s) removido(s)" — nada foi removido.
    refute_output --partial "removido(s)"
    assert_output --partial "Falha ao remover"
}

# --- ramo best-effort de _cron_system_files (sem ./cron) --------------------

@test "_cron_system_files (ramo best-effort): o aviso vai para STDERR e nao entra no stream de caminhos" {
    # O setup cria ./cron; removendo, cai no ramo best-effort sobre CRON_DIR.
    rm -rf ./cron
    touch "${CRON_DIR}/exec-cron-moodle-moodle" "${CRON_DIR}/exec-cron-moodle-prod-moodle"

    # O stdout desta funcao E a lista de caminhos consumida por
    # `done < <(_cron_system_files ...)` em cron_remove/cron_list. O aviso do
    # ramo best-effort tem que sair por stderr: se saisse por stdout, o chamador
    # tentaria `rm -f` no texto do aviso, contaria remocao que nao houve e o
    # `dirname` do texto cairia num diretorio nao gravavel (podendo disparar
    # `sudo` interativo pedindo senha).
    #
    # Nota: `run` do bats captura stdout E stderr juntos, entao a separacao tem
    # que ser explicita aqui — um `run` simples passaria mesmo com o bug.
    local so se
    so="$(_cron_system_files "moodle" 2>/dev/null)"
    se="$(_cron_system_files "moodle" 2>&1 >/dev/null)"

    # o aviso NAO pode estar no stdout...
    [[ "${so}" != *"[AVISO]"* ]]
    # ...e tem que estar no stderr (senao foi simplesmente engolido)
    [[ "${se}" == *"[AVISO]"* ]]

    # cada linha do stdout tem que ser um arquivo existente
    local linha
    while IFS= read -r linha; do
        [[ -z "${linha}" ]] && continue
        [[ -f "${linha}" ]] || { echo "linha nao e arquivo: ${linha}"; return 1; }
    done <<< "${so}"

    # o ramo best-effort e documentado como permissivo: inclui o de outro
    # projeto cujo nome termina igual (por isso o aviso existe)
    [[ "${so}" == *"${CRON_DIR}/exec-cron-moodle-moodle"* ]]
    [[ "${so}" == *"${CRON_DIR}/exec-cron-moodle-prod-moodle"* ]]
}
