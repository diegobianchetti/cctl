#!/usr/bin/env bats
# tests/templates.bats — asserções estáticas sobre os templates (sem Docker
# real: só grep/estrutura de arquivo). Cobre a decisão de nao publicar o
# banco no host por padrao (ver WORK_LOG/CLAUDE.md do projeto).

setup() {
    load 'helpers/common'
    load_bats_libs
}

# --- moodle: moodle-db nao publica porta no compose base -------------------

@test "moodle: compose base nao tem 'ports:' no servico moodle-db" {
    local compose="${CCTL_ROOT}/templates/moodle/docker/docker-compose.yaml"
    [[ -f "${compose}" ]]
    # Extrai o bloco do servico moodle-db (da linha "  moodle-db:" ate o
    # proximo servico de nivel 2, "  moodle-app:") e confere que nao ha
    # "ports:" dentro dele.
    run bash -c "sed -n '/^  moodle-db:/,/^  moodle-app:/p' '${compose}' | grep -c '^\s*ports:'"
    assert_output "0"
}

@test "moodle: override docker-compose.db-port.yaml existe e publica so em 127.0.0.1" {
    local override="${CCTL_ROOT}/templates/moodle/docker/docker-compose.db-port.yaml"
    [[ -f "${override}" ]]

    # Bind explicito em loopback, na sintaxe curta "<ip>:<porta>:<alvo>".
    # NAO use a forma longa com o IP dentro de `published:` — medido na VM
    # (2026-09-13): o `docker compose config` aceita (o schema permite string),
    # mas o daemon rejeita na criacao do container com
    # "invalid port specification: \"127.0.0.1:5432\"". O container nunca sobe,
    # e a falha aparece no MEIO do deploy, depois de renderizar templates e
    # alocar subnet. Este teste existe para travar essa regressao.
    #
    # Conta apenas as linhas EFETIVAS: o cabecalho do arquivo cita `0.0.0.0` e a
    # propria forma invalida em comentario, de proposito (documenta o que NAO
    # fazer) — e um grep ingenuo sobre o arquivo inteiro daria falso positivo.
    local efetivo
    efetivo=$(mktemp)
    grep -v '^[[:space:]]*#' "${override}" > "${efetivo}"

    run grep -cE '^\s*-\s*"127\.0\.0\.1:\$\{MOODLE_DB_PORT\}:5432"' "${efetivo}"
    assert_output "1"

    # nunca aberto para a rede
    run grep -c '0\.0\.0\.0' "${efetivo}"
    assert_output "0"

    # `published:` com IP embutido e a forma invalida — nao pode voltar
    run grep -cE 'published:\s*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:' "${efetivo}"
    assert_output "0"

    rm -f "${efetivo}"
}

@test "moodle: project.conf mantem o override do db-port comentado (default fechado)" {
    local conf="${CCTL_ROOT}/templates/moodle/project.conf"
    run grep -c '^COMPOSE_FILES=.*db-port' "${conf}"
    assert_output "0"
    run grep -c '^# COMPOSE_FILES=.*db-port' "${conf}"
    assert_output "1"
}

# --- dspace: sem padrao equivalente a corrigir (so documentado) -----------

@test "dspace: nenhum servico do compose publica porta de banco no host" {
    local dir="${CCTL_ROOT}/templates/dspace/docker"
    [[ -d "${dir}" ]]
    run find "${dir}" -maxdepth 1 -name '*.y*ml' -exec grep -l '^\s*ports:' {} +
    assert_output ""
}
