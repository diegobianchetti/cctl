#!/usr/bin/env bats
# tests/init.bats — testes para commands/init.sh (diretorio de destino vazio vs nao-vazio)

setup() {
    load 'helpers/common'
    load_bats_libs
    source_lib colors.sh log.sh validate.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    # CCTL_ROOT isolado com um template minimo, sem tocar no projeto real
    export CCTL_ROOT="${WORKDIR}/cctl-root"
    mkdir -p "${CCTL_ROOT}/templates/minimal/docker" "${CCTL_ROOT}/templates/minimal/nginx"

    cat > "${CCTL_ROOT}/templates/minimal/project.conf" <<'EOF'
ENV_FILE="docker/.env"
ENV_TEMPLATE="docker/.env.template"
PROJECT_TYPE="_CLIENT_NAME_"
COMPOSE_PROJECT_NAME="_COMPOSE_PROJECT_NAME_"
EOF

    cat > "${CCTL_ROOT}/templates/minimal/docker/.env.template" <<'EOF'
COMPOSE_PROJECT_NAME=_COMPOSE_PROJECT_NAME_
DOMAIN_NAME=_DOMAIN_NAME_
EOF

    local real_cctl_root
    real_cctl_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${real_cctl_root}/commands/init.sh"
}

teardown() {
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && chmod -R 777 "${WORKDIR}" 2>/dev/null || true
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

@test "cmd_init: cria projeto em destino inexistente" {
    local dest="${WORKDIR}/novo-projeto"

    run cmd_init minimal projeto1 --domain projeto1.example.com --dest "${dest}"
    assert_success
    [[ -f "${dest}/project.conf" ]]
}

@test "cmd_init: aceita e reaproveita destino existente porem vazio" {
    local dest="${WORKDIR}/dest-vazio"
    mkdir -p "${dest}"

    run cmd_init minimal projeto2 --domain projeto2.example.com --dest "${dest}"
    assert_success
    assert_output --partial "vazio"
    [[ -f "${dest}/project.conf" ]]
}

@test "cmd_init: nao sofre injecao de comando via caminho de destino com aspas simples" {
    local dest="${WORKDIR}/dest'com'aspas"
    mkdir -p "${WORKDIR}"

    run cmd_init minimal projeto-aspas --domain projeto.example.com --dest "${dest}"
    assert_success
    [[ -f "${dest}/project.conf" ]]
    # confirma que nada foi executado fora do escopo esperado (sem marcador de injecao)
    [[ ! -f "${WORKDIR}/pwned" ]]
}

@test "cmd_init: rejeita diretorio de destino sem permissao de leitura/escrita" {
    [[ "${EUID}" -eq 0 ]] && skip "Executando como root"

    local dest="${WORKDIR}/dest-sem-permissao"
    mkdir -p "${dest}"
    chmod 000 "${dest}"

    run cmd_init minimal projeto-perm --domain projeto.example.com --dest "${dest}"
    assert_failure
    assert_output --partial "Sem permissao"

    chmod 755 "${dest}"
}

@test "cmd_init: nao sofre injecao de comando via caminho de destino com payload de subshell/backtick" {
    local marker="${WORKDIR}/pwned-injecao"
    local dest="${WORKDIR}/dest-\$(touch ${marker})-e-\`touch ${marker}\`"

    run cmd_init minimal projeto-injecao --domain projeto.example.com --dest "${dest}"
    assert_success
    [[ -f "${dest}/project.conf" ]]
    # nem o $(...) nem o `...` devem ter sido executados pelo shell
    [[ ! -f "${marker}" ]]
}

@test "cmd_init: aborta quando cp -r do template falha" {
    [[ "${EUID}" -eq 0 ]] && skip "Executando como root"

    # template com arquivo ilegivel para forcar falha real do cp -r
    mkdir -p "${CCTL_ROOT}/templates/cp-falha"
    echo "conteudo" > "${CCTL_ROOT}/templates/cp-falha/segredo"
    chmod 000 "${CCTL_ROOT}/templates/cp-falha/segredo"

    local dest="${WORKDIR}/dest-cp-falha"
    run cmd_init cp-falha projeto-cp --domain projeto.example.com --dest "${dest}"
    assert_failure
    assert_output --partial "Falha ao copiar template"

    chmod 644 "${CCTL_ROOT}/templates/cp-falha/segredo"
}

@test "cmd_init: rejeita nome de projeto invalido (path traversal)" {
    local dest="${WORKDIR}/dest-traversal"

    run cmd_init minimal "../etc" --domain projeto.example.com --dest "${dest}"
    assert_failure
    [[ ! -d "${dest}" ]]
}

@test "cmd_init: rejeita nome de projeto invalido (pipe quebraria o sed)" {
    local dest="${WORKDIR}/dest-pipe"

    run cmd_init minimal "foo|bar" --domain projeto.example.com --dest "${dest}"
    assert_failure
    [[ ! -d "${dest}" ]]
}

@test "cmd_init: rejeita nome de projeto invalido (espacos)" {
    local dest="${WORKDIR}/dest-espaco"

    run cmd_init minimal "foo bar" --domain projeto.example.com --dest "${dest}"
    assert_failure
    [[ ! -d "${dest}" ]]
}

@test "cmd_init: aceita nome de projeto valido com underscore e digitos" {
    local dest="${WORKDIR}/dest-underscore"

    run cmd_init minimal "app_1" --domain projeto.example.com --dest "${dest}"
    assert_success
    [[ -f "${dest}/project.conf" ]]
}

@test "cmd_init: rejeita destino existente e nao-vazio" {
    local dest="${WORKDIR}/dest-ocupado"
    mkdir -p "${dest}"
    touch "${dest}/algum-arquivo.txt"

    run cmd_init minimal projeto3 --domain projeto3.example.com --dest "${dest}"
    assert_failure
    assert_output --partial "nao esta vazio"
    # nao deve ter sobrescrito nada
    [[ ! -f "${dest}/project.conf" ]]
    [[ -f "${dest}/algum-arquivo.txt" ]]
}
