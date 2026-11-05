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
    assert_failure
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

@test "C6 cron_remove: falha de descoberta privilegiada preserva arquivos e nao chama rm" {
    local target="${CRON_DIR}/exec-cron-moodle-moodle"
    : > "${target}"
    core_priv_run() {
        [[ "$1" == "test" ]] && return 2
        return 99
    }
    mock_cmd rm 'echo "rm $*" >> "'"${WORKDIR}"'/rm.calls"; exit 0'

    run cron_remove
    assert_failure
    assert_output --partial "Nao foi possivel descobrir cron jobs"
    [[ -f "${target}" ]]
    [[ ! -e "${WORKDIR}/rm.calls" ]]
}

@test "C6 cron_remove: ./cron sem acesso nao vira fonte local vazia nem chama rm" {
    local target="${CRON_DIR}/exec-cron-moodle-moodle"
    : > "${target}"
    core_priv_run() {
        case "$1" in
            test) [[ "$2" == "-d" && "$3" == "./cron" ]] && return 0 ;;
            ls) [[ "$3" == "./cron" ]] && { echo "listagem negada" >&2; return 2; } ;;
        esac
        return 99
    }
    mock_cmd rm 'echo "rm $*" >> "'"${WORKDIR}"'/rm.calls"; exit 0'

    run cron_remove
    assert_failure
    assert_output --partial "Nao foi possivel descobrir cron jobs"
    [[ -f "${target}" ]]
    [[ ! -e "${WORKDIR}/rm.calls" ]]
}

@test "C6 cron_remove: fallback CRON_DIR sem acesso nao vira vazio nem chama rm" {
    rm -rf ./cron
    local target="${CRON_DIR}/exec-cron-moodle-moodle"
    : > "${target}"
    core_priv_run() {
        case "$1:$2:$3" in
            test:-d:./cron) return 1 ;;
            test:-d:"${CRON_DIR}") return 0 ;;
            ls:-1:--) echo "listagem negada" >&2; return 2 ;;
        esac
        return 99
    }
    mock_cmd rm 'echo "rm $*" >> "'"${WORKDIR}"'/rm.calls"; exit 0'

    run cron_remove
    assert_failure
    assert_output --partial "Nao foi possivel descobrir cron jobs"
    [[ -f "${target}" ]]
    [[ ! -e "${WORKDIR}/rm.calls" ]]
}

@test "C6 cron_remove: listagem parcial com erro nao remove o item listado" {
    local target="${CRON_DIR}/exec-cron-moodle-moodle"
    : > "${target}"
    core_priv_run() {
        case "$1" in
            test) return 0 ;;
            ls) printf 'exec-cron-moodle.cron\n'; echo "erro apos parcial" >&2; return 2 ;;
        esac
        return 99
    }
    mock_cmd rm 'echo "rm $*" >> "'"${WORKDIR}"'/rm.calls"; exit 0'

    run cron_remove
    assert_failure
    assert_output --partial "Nao foi possivel descobrir cron jobs"
    [[ -f "${target}" ]]
    [[ ! -e "${WORKDIR}/rm.calls" ]]
}

# O alvo fica atras de um pai sem travessia, forcando o wrapper real a usar
# sudo mockado. O mock restaura a travessia somente para executar o test real
# sobre o fixture; nenhum sudo real e chamado.
@test "B4 core_priv_run test: nonTTY falso logico devolve 1 apos sudo test" {
    local blocked="${WORKDIR}/sem-travessia" target="${WORKDIR}/sem-travessia/ausente"
    mkdir -p "${blocked}"
    chmod 000 "${blocked}"
    mock_cmd sudo 'printf "sudo" >> "'"${WORKDIR}"'/sudo.log"; printf " %s" "$@" >> "'"${WORKDIR}"'/sudo.log"; printf "\n" >> "'"${WORKDIR}"'/sudo.log"; [[ "$1" == "-n" ]] && shift; [[ "$1" == "true" ]] && exit 0; chmod 700 "'"${blocked}"'"; "$@"; rc=$?; chmod 000 "'"${blocked}"'"; exit ${rc}'

    local rc
    if core_priv_run test -f "${target}"; then rc=0; else rc=$?; fi
    chmod 700 "${blocked}"

    [[ ${rc} -eq 1 ]]
    grep -qxF "sudo -n true" "${WORKDIR}/sudo.log"
    grep -qxF "sudo -n test -f ${target}" "${WORKDIR}/sudo.log"
}

@test "B4 core_priv_run test: nonTTY verdadeiro logico devolve 0 apos sudo test" {
    local blocked="${WORKDIR}/sem-travessia" target="${WORKDIR}/sem-travessia/presente"
    mkdir -p "${blocked}"
    : > "${target}"
    chmod 000 "${blocked}"
    mock_cmd sudo 'printf "sudo" >> "'"${WORKDIR}"'/sudo.log"; printf " %s" "$@" >> "'"${WORKDIR}"'/sudo.log"; printf "\n" >> "'"${WORKDIR}"'/sudo.log"; [[ "$1" == "-n" ]] && shift; [[ "$1" == "true" ]] && exit 0; chmod 700 "'"${blocked}"'"; "$@"; rc=$?; chmod 000 "'"${blocked}"'"; exit ${rc}'

    core_priv_run test -f "${target}"
    local rc=$?
    chmod 700 "${blocked}"

    [[ ${rc} -eq 0 ]]
    grep -qxF "sudo -n true" "${WORKDIR}/sudo.log"
    grep -qxF "sudo -n test -f ${target}" "${WORKDIR}/sudo.log"
}

@test "B4 core_priv_run test: nonTTY falha operacional devolve 2" {
    local blocked="${WORKDIR}/sem-travessia" target="${WORKDIR}/sem-travessia/ausente"
    mkdir -p "${blocked}"
    chmod 000 "${blocked}"
    mock_cmd sudo 'printf "sudo" >> "'"${WORKDIR}"'/sudo.log"; printf " %s" "$@" >> "'"${WORKDIR}"'/sudo.log"; printf "\n" >> "'"${WORKDIR}"'/sudo.log"; exit 1'

    local rc
    if core_priv_run test -d "${target}"; then rc=0; else rc=$?; fi
    chmod 700 "${blocked}"

    [[ ${rc} -eq 2 ]]
    grep -qxF "sudo -n true" "${WORKDIR}/sudo.log"
    ! grep -q ' test ' "${WORKDIR}/sudo.log"
}

@test "B4 core_priv_run test: TTY falso logico devolve 1 apos sudo test" {
    local blocked="${WORKDIR}/sem-travessia" target="${WORKDIR}/sem-travessia/ausente"
    mkdir -p "${blocked}"
    chmod 000 "${blocked}"
    _core_stdin_is_tty() { return 0; }
    mock_cmd sudo 'printf "sudo" >> "'"${WORKDIR}"'/sudo.log"; printf " %s" "$@" >> "'"${WORKDIR}"'/sudo.log"; printf "\n" >> "'"${WORKDIR}"'/sudo.log"; [[ "$1" == "true" ]] && exit 0; chmod 700 "'"${blocked}"'"; "$@"; rc=$?; chmod 000 "'"${blocked}"'"; exit ${rc}'

    local rc
    if core_priv_run test -d "${target}"; then rc=0; else rc=$?; fi
    chmod 700 "${blocked}"

    [[ ${rc} -eq 1 ]]
    grep -qxF "sudo true" "${WORKDIR}/sudo.log"
    grep -qxF "sudo test -d ${target}" "${WORKDIR}/sudo.log"
}

@test "B4 core_priv_run test: TTY verdadeiro logico devolve 0 apos sudo test" {
    local blocked="${WORKDIR}/sem-travessia" target="${WORKDIR}/sem-travessia/presente"
    mkdir -p "${blocked}"
    mkdir "${target}"
    chmod 000 "${blocked}"
    _core_stdin_is_tty() { return 0; }
    mock_cmd sudo 'printf "sudo" >> "'"${WORKDIR}"'/sudo.log"; printf " %s" "$@" >> "'"${WORKDIR}"'/sudo.log"; printf "\n" >> "'"${WORKDIR}"'/sudo.log"; [[ "$1" == "true" ]] && exit 0; chmod 700 "'"${blocked}"'"; "$@"; rc=$?; chmod 000 "'"${blocked}"'"; exit ${rc}'

    core_priv_run test -d "${target}"
    local rc=$?
    chmod 700 "${blocked}"

    [[ ${rc} -eq 0 ]]
    grep -qxF "sudo true" "${WORKDIR}/sudo.log"
    grep -qxF "sudo test -d ${target}" "${WORKDIR}/sudo.log"
}

@test "B4 core_priv_run test: TTY falha operacional devolve 2" {
    local blocked="${WORKDIR}/sem-travessia" target="${WORKDIR}/sem-travessia/ausente"
    mkdir -p "${blocked}"
    chmod 000 "${blocked}"
    _core_stdin_is_tty() { return 0; }
    mock_cmd sudo 'printf "sudo" >> "'"${WORKDIR}"'/sudo.log"; printf " %s" "$@" >> "'"${WORKDIR}"'/sudo.log"; printf "\n" >> "'"${WORKDIR}"'/sudo.log"; [[ "$1" == "true" ]] && exit 0; exit 2'

    local rc
    if core_priv_run test -f "${target}"; then rc=0; else rc=$?; fi
    chmod 700 "${blocked}"

    [[ ${rc} -eq 2 ]]
    grep -qxF "sudo true" "${WORKDIR}/sudo.log"
    grep -qxF "sudo test -f ${target}" "${WORKDIR}/sudo.log"
}

@test "B4 cron_remove: sudo -n true falho preserva familia sem test nem rm" {
    local target="${CRON_DIR}/exec-cron-moodle-moodle" rc
    : > "${target}"
    chmod 000 "${CRON_DIR}"
    mock_cmd sudo 'printf "sudo" >> "'"${WORKDIR}"'/sudo.log"; printf " %s" "$@" >> "'"${WORKDIR}"'/sudo.log"; printf "\n" >> "'"${WORKDIR}"'/sudo.log"; exit 1'
    mock_cmd rm 'printf "rm %s\n" "$*" >> "'"${WORKDIR}"'/rm.calls"; exec /bin/rm "$@"'

    if cron_remove; then rc=0; else rc=$?; fi
    chmod 700 "${CRON_DIR}"

    [[ ${rc} -ne 0 ]]
    [[ -f "${target}" ]]
    grep -qxF "sudo -n true" "${WORKDIR}/sudo.log"
    ! grep -q ' test ' "${WORKDIR}/sudo.log"
    [[ ! -e "${WORKDIR}/rm.calls" ]]
}

@test "N1 cron symlink com alvo protegido escala sudo e cron_remove chama rm" {
    local protected="${WORKDIR}/protegido" target
    target="${protected}/cron-real"
    local system_cron="${CRON_DIR}/exec-cron-moodle-moodle"
    mkdir -p "${protected}"
    : > "${target}"
    ln -s "${target}" "${system_cron}"
    chmod 000 "${protected}"
    mock_cmd sudo 'printf "sudo" >> "'"${WORKDIR}"'/sudo.log"; printf " %s" "$@" >> "'"${WORKDIR}"'/sudo.log"; printf "\n" >> "'"${WORKDIR}"'/sudo.log"; [[ "$1" == "-n" ]] && shift; [[ "$1" == "true" ]] && exit 0; chmod 700 "'"${protected}"'"; "$@"; rc=$?; chmod 000 "'"${protected}"'"; exit ${rc}'
    mock_cmd rm 'printf "rm %s\n" "$*" >> "'"${WORKDIR}"'/rm.calls"; exec /bin/rm "$@"'

    run cron_remove
    local rc=${status}
    chmod 700 "${protected}"

    [[ ${rc} -eq 0 ]]
    [[ ! -L "${system_cron}" ]]
    grep -qxF "sudo -n true" "${WORKDIR}/sudo.log"
    grep -qxF "sudo -n test -f ${system_cron}" "${WORKDIR}/sudo.log"
    grep -qF -- "-f ${system_cron}" "${WORKDIR}/rm.calls"
}

@test "N1 cron symlink valido e descoberto pelo protocolo sudo em TTY" {
    local locked_dir="${WORKDIR}/protegido-tty" target system_cron output
    target="${locked_dir}/cron-real"
    system_cron="${CRON_DIR}/exec-cron-moodle-moodle"
    mkdir -p "${locked_dir}"
    : > "${target}"
    ln -s "${target}" "${system_cron}"
    chmod 000 "${locked_dir}"
    _core_stdin_is_tty() { return 0; }
    mock_cmd sudo 'printf "sudo" >> "'"${WORKDIR}"'/sudo.log"; printf " %s" "$@" >> "'"${WORKDIR}"'/sudo.log"; printf "\n" >> "'"${WORKDIR}"'/sudo.log"; [[ "$1" == "true" ]] && exit 0; chmod 700 "'"${locked_dir}"'"; "$@"; rc=$?; chmod 000 "'"${locked_dir}"'"; exit ${rc}'
    mock_cmd rm 'printf "rm %s\n" "$*" >> "'"${WORKDIR}"'/rm.calls"; exec /bin/rm "$@"'

    output="$(_cron_system_files "moodle")"
    local rc=$?
    [[ ${rc} -eq 0 ]]
    [[ "${output}" == "${system_cron}" ]]

    run cron_remove
    rc=${status}
    chmod 700 "${locked_dir}"

    [[ ${rc} -eq 0 ]]
    [[ ! -L "${system_cron}" ]]
    grep -qxF "sudo true" "${WORKDIR}/sudo.log"
    grep -qxF "sudo test -f ${system_cron}" "${WORKDIR}/sudo.log"
    grep -qF -- "-f ${system_cron}" "${WORKDIR}/rm.calls"
}

@test "N2 CRON_DIR ausente e fonte presente e descoberta vazia nos modos sudo" {
    rm -rf "${CRON_DIR}"
    mock_cmd sudo 'printf "sudo" >> "'"${WORKDIR}"'/sudo.log"; printf " %s" "$@" >> "'"${WORKDIR}"'/sudo.log"; printf "\n" >> "'"${WORKDIR}"'/sudo.log"; [[ "$1" == "-n" ]] && shift; [[ "$1" == "true" ]] && exit 0; "$@"'
    mock_cmd rm 'echo "rm $*" >> "'"${WORKDIR}"'/rm.calls"; exit 99'
    local mode output rc
    for mode in nonTTY TTY; do
        [[ "${mode}" == TTY ]] && _core_stdin_is_tty() { return 0; } || _core_stdin_is_tty() { return 1; }
        output="$(_cron_system_files "moodle")"
        rc=$?
        [[ ${rc} -eq 0 && -z "${output}" ]] || return 1
        cron_remove || return 1
    done
    [[ ! -e "${WORKDIR}/rm.calls" ]]
}

@test "B4 core_priv_run test: sudo test rc maior que um devolve 2" {
    local blocked="${WORKDIR}/sem-travessia" target="${WORKDIR}/sem-travessia/ausente"
    mkdir -p "${blocked}"
    chmod 000 "${blocked}"
    mock_cmd sudo 'printf "sudo" >> "'"${WORKDIR}"'/sudo.log"; printf " %s" "$@" >> "'"${WORKDIR}"'/sudo.log"; printf "\n" >> "'"${WORKDIR}"'/sudo.log"; [[ "$1" == "-n" ]] && shift; [[ "$1" == "true" ]] && exit 0; exit 2'

    local rc
    if core_priv_run test -f "${target}"; then rc=0; else rc=$?; fi
    chmod 700 "${blocked}"

    [[ ${rc} -eq 2 ]]
    grep -qxF "sudo -n test -f ${target}" "${WORKDIR}/sudo.log"
}

@test "cron_list: falha de descoberta nao anuncia nenhum cron job" {
    core_priv_run() { return 2; }

    run cron_list
    assert_failure
    assert_output --partial "Nao foi possivel descobrir cron jobs"
    refute_output --partial "Nenhum cron job encontrado"
}
