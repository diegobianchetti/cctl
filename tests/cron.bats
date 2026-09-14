#!/usr/bin/env bats
# tests/cron.bats — testes para lib/cron.sh
#
# Cobre: instalacao via CRON_DIR (core_priv_run, sem sudo quando gravavel),
# fallback para a crontab do usuario quando CRON_DIR nao e gravavel e nao ha
# sudo, idempotencia do fallback, remocao nos dois lugares, e a regressao de
# colisao por substring (cron_list/cron_remove nao podem casar "moodle-lab"
# quando o projeto e "moodle").
#
# Isolamento: sudo e crontab sempre mockados via bin/ temporario no PATH e
# arquivo de estado local — nenhuma crontab real, /etc/cron.d real ou o host
# sao tocados.

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

@test "cron_install: CRON_DIR gravavel instala sem chamar sudo" {
    mock_sudo_passthrough "${WORKDIR}/sudo.log"
    mock_crontab "${WORKDIR}/crontab.store"

    run cron_install
    assert_success

    local dest="${CRON_DIR}/exec-cron-moodle-moodle"
    [[ -f "${dest}" ]]
    assert_output --partial "Cron instalado: ${dest}"

    # sudo nao deve ter sido chamado (CRON_DIR ja era gravavel)
    [[ ! -s "${WORKDIR}/sudo.log" ]]
}

@test "cron_install: CRON_DIR nao gravavel e sem sudo cai na crontab do usuario, sem campo de usuario" {
    chmod -w "${CRON_DIR}"
    mock_sudo_deny "${WORKDIR}/sudo.log"
    mock_crontab "${WORKDIR}/crontab.store"

    run cron_install
    assert_success
    assert_output --partial "crontab do usuario"

    run cat "${WORKDIR}/crontab.store"
    assert_success
    assert_output --partial "# cctl:begin:moodle:exec-cron-moodle"
    assert_output --partial "# cctl:end:moodle:exec-cron-moodle"
    # Sem o campo de usuario ("root"): a linha de job vai direto de "* * * * *"
    # para o comando.
    assert_output --partial '* * * * * /usr/bin/docker compose -p moodle exec moodle-app bash -c "/usr/local/bin/cron-moodle.sh"'
    refute_output --partial '* * * * * root'

    # nada deve ter sido escrito em CRON_DIR (permanece so o dir vazio)
    chmod +w "${CRON_DIR}"
    run bash -c "ls -A '${CRON_DIR}'"
    assert_output ""
}

@test "cron_install: reinstalar na crontab do usuario nao duplica (idempotencia)" {
    chmod -w "${CRON_DIR}"
    mock_sudo_deny "${WORKDIR}/sudo.log"
    mock_crontab "${WORKDIR}/crontab.store"

    run cron_install
    assert_success
    run cron_install
    assert_success

    run bash -c "grep -c '# cctl:begin:moodle:exec-cron-moodle' '${WORKDIR}/crontab.store'"
    assert_output "1"
    run bash -c "grep -c '/usr/local/bin/cron-moodle.sh' '${WORKDIR}/crontab.store'"
    assert_output "1"
}

@test "cron_remove: limpa CRON_DIR e a crontab do usuario" {
    mock_sudo_passthrough "${WORKDIR}/sudo.log"
    mock_crontab "${WORKDIR}/crontab.store"

    # Um arquivo em CRON_DIR (caminho de sistema)...
    cat > "${CRON_DIR}/exec-cron-moodle-moodle" <<'EOF'
SHELL=/bin/sh
* * * * * root /bin/true
EOF
    # ...e uma entrada na crontab do usuario (caminho de fallback), como se
    # um segundo job tivesse caido la.
    cat > "${WORKDIR}/crontab.store" <<'EOF'
# cctl:begin:moodle:backup-db
* * * * * /bin/true
# cctl:end:moodle:backup-db
EOF

    run cron_remove
    assert_success
    assert_output --partial "removido"

    [[ ! -f "${CRON_DIR}/exec-cron-moodle-moodle" ]]
    run cat "${WORKDIR}/crontab.store"
    refute_output --partial "cctl:begin:moodle:backup-db"
}

@test "cron_list/cron_remove (regressao colisao): projeto 'moodle' nao casa 'moodle-lab'" {
    mock_sudo_passthrough "${WORKDIR}/sudo.log"
    mock_crontab "${WORKDIR}/crontab.store"

    cat > "${CRON_DIR}/exec-cron-moodle-moodle" <<'EOF'
* * * * * root /bin/true
EOF
    cat > "${CRON_DIR}/exec-cron-moodle-moodle-lab" <<'EOF'
* * * * * root /bin/true
EOF
    cat > "${WORKDIR}/crontab.store" <<'EOF'
# cctl:begin:moodle-lab:exec-cron-moodle
* * * * * /bin/true
# cctl:end:moodle-lab:exec-cron-moodle
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
    # Entrada de crontab do outro projeto continua intacta
    run cat "${WORKDIR}/crontab.store"
    assert_output --partial "cctl:begin:moodle-lab:exec-cron-moodle"
}

@test "cron_list/cron_remove (regressao B1, direcao oposta): projeto 'moodle' nao casa 'prod-moodle'" {
    # Direcao complementar ao teste de 'moodle-lab' acima: ali o nome do
    # OUTRO projeto tinha o projeto atual como PREFIXO ("moodle-lab"); aqui
    # o nome do projeto atual e SUFIXO do outro ("prod-moodle"). O glob
    # antigo "${CRON_DIR}/*-${prefix}" ancora so a direita — "*-moodle"
    # tambem casa "exec-cron-moodle-prod-moodle" — e sob esse glob
    # cron_remove apagaria o cron do projeto errado.
    mock_sudo_passthrough "${WORKDIR}/sudo.log"
    mock_crontab "${WORKDIR}/crontab.store"

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

@test "_cron_strip_user_block (B2): instalar 'backup-db' nao apaga o bloco de 'backup' (prefixo de marcador)" {
    mock_crontab "${WORKDIR}/crontab.store"

    mkdir -p ./cron
    cat > ./cron/backup.cron <<'EOF'
0 3 * * * root /bin/true backup-principal
EOF
    cat > ./cron/backup-db.cron <<'EOF'
0 4 * * * root /bin/true backup-db-principal
EOF

    # Ordem importa para expor o bug: instala primeiro o marcador MAIS
    # LONGO (backup-db) e depois o mais curto (backup, prefixo do anterior).
    # Com "index($0, b) == 1" o strip de "# cctl:begin:moodle:backup" tambem
    # casava a linha "# cctl:begin:moodle:backup-db" (comeca com o mesmo
    # texto), apagando o bloco de backup-db silenciosamente a cada
    # reinstalacao do "backup".
    _cron_install_user_crontab "moodle" "backup-db" "./cron/backup-db.cron"
    _cron_install_user_crontab "moodle" "backup" "./cron/backup.cron"

    run cat "${WORKDIR}/crontab.store"
    assert_success
    assert_output --partial "# cctl:begin:moodle:backup-db"
    assert_output --partial "# cctl:end:moodle:backup-db"
    assert_output --partial "backup-db-principal"
    assert_output --partial "# cctl:begin:moodle:backup"
    assert_output --partial "backup-principal"
}

@test "_cron_strip_user_block (B2): marcador de abertura sem fechamento correspondente e preservado com aviso" {
    source_lib cron.sh

    run _cron_strip_user_block "$(printf '%s\n' 'linha-anterior' '# cctl:begin:moodle:backup' 'algo-do-usuario')" "# cctl:begin:moodle:backup"
    assert_success
    assert_output --partial "linha-anterior"
    assert_output --partial "# cctl:begin:moodle:backup"
    assert_output --partial "algo-do-usuario"
}

@test "_cron_install_user_crontab (B3a): 'crontab -' falhando nao reporta sucesso" {
    mock_crontab_write_fails

    mkdir -p ./cron
    cat > ./cron/backup.cron <<'EOF'
0 3 * * * root /bin/true
EOF

    run _cron_install_user_crontab "moodle" "backup" "./cron/backup.cron"
    assert_failure
    refute_output --partial "instalado na crontab do usuario"
    assert_output --partial "Falha ao instalar"
}

@test "_cron_install_user_crontab (B3a): sem 'crontab' no PATH, nao promete fallback" {
    mkdir -p ./cron
    cat > ./cron/backup.cron <<'EOF'
0 3 * * * root /bin/true
EOF

    local minimal_bin
    minimal_bin="$(make_minimal_path_without "${WORKDIR}/minimal-bin" crontab)"

    PATH="${minimal_bin}" run _cron_install_user_crontab "moodle" "backup" "./cron/backup.cron"
    assert_failure
    assert_output --partial "NAO foi agendado"
}

@test "cron_remove (B3b): rm falhando no arquivo de sistema nao conta como removido nem reporta sucesso mentiroso" {
    mock_cmd rm '
        for a in "$@"; do
            [[ "${a}" == *exec-cron-moodle-moodle ]] && { echo "rm mockado: falha forcada" >&2; exit 1; }
        done
        exec /bin/rm "$@"
    '
    mock_crontab "${WORKDIR}/crontab.store"

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
