#!/usr/bin/env bash
# tests/helpers/common.bash — helpers compartilhados entre baterias .bats
#
# Isolamento: nenhum teste toca o host real. Comandos externos (docker, ss,
# host, certbot, sudo) sao sempre mockados via bin/ temporario no PATH.

# Raiz do projeto cctl (dois niveis acima deste arquivo: tests/helpers/..)
CCTL_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
export CCTL_ROOT

load_bats_libs() {
    load "${BATS_TEST_DIRNAME}/vendor/bats-support/load.bash"
    load "${BATS_TEST_DIRNAME}/vendor/bats-assert/load.bash"
}

# Cria um diretorio de binarios mockados e o antepoe ao PATH.
# Chamar no setup() de cada bateria que precise isolar comandos externos.
setup_mock_bin() {
    MOCK_BIN="$(mktemp -d)"
    export MOCK_BIN
    export PATH="${MOCK_BIN}:${PATH}"
}

# Remove o diretorio de mocks. Chamar no teardown().
teardown_mock_bin() {
    [[ -n "${MOCK_BIN:-}" && -d "${MOCK_BIN}" ]] && rm -rf "${MOCK_BIN}"
}

# Cria um comando mockado executavel em MOCK_BIN.
# Uso: mock_cmd <nome> '<corpo do script bash>'
mock_cmd() {
    local name="$1"
    local body="$2"

    cat > "${MOCK_BIN}/${name}" <<MOCKEOF
#!/usr/bin/env bash
${body}
MOCKEOF
    chmod +x "${MOCK_BIN}/${name}"
}

# Sourcea libs sem depender do core_bootstrap completo (evita puxar libs que
# fazem chamadas externas nao relacionadas ao que esta sendo testado).
# Uso: source_lib validate.sh log.sh colors.sh
source_lib() {
    local f
    for f in "$@"; do
        # shellcheck source=/dev/null
        source "${CCTL_ROOT}/lib/${f}"
    done
}

# Cria um diretorio temporario de trabalho e cd nele. Ecoa o path.
make_tmp_workdir() {
    local d
    d="$(mktemp -d)"
    echo "${d}"
}

# Mocka sudo repassando de fato para o comando real (sob o mock), em vez de
# so registrar a chamada. Trata a flag "-n" (usada por core_priv_run em
# contexto nao-interativo) para que o comando real seja executado tambem
# nesse caminho — sem isso, "$@" comecaria com "-n" e o exec falharia,
# fazendo os testes validarem so a escrita em sudo.log e nao o efeito real
# da operacao no disco.
# Uso: mock_sudo_passthrough [caminho-do-log]  (default: ${WORKDIR}/sudo.log)
mock_sudo_passthrough() {
    local logfile="${1:-${WORKDIR}/sudo.log}"
    mock_cmd sudo '
        echo "sudo-called" >> "'"${logfile}"'"
        [[ "$1" == "-n" ]] && shift
        exec "$@"
    '
}
