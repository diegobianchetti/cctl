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

# --- contrato de rede dos templates -------------------------------------------
# Sem Docker real: le os compose e confere o contrato — rede de topo
# `external: true` com `name: ${CCTL_PROJECT_NETWORK}`, sem driver/ipam/subnet
# (quem cria a rede e escolhe a faixa e o cctl, nao o template).

# Imprime o bloco do "networks:" de topo de um compose (ate a proxima chave de
# topo), sem as linhas de comentario.
_top_level_networks_block() {
    awk '
        /^networks:[[:space:]]*$/ { in_block = 1; next }
        in_block && /^[A-Za-z0-9_-]+:/ { in_block = 0 }
        in_block && !/^[[:space:]]*#/ { print }
    ' "$1"
}

_network_contract_compose_files() {
    echo "${CCTL_ROOT}/templates/moodle/docker/docker-compose.yaml"
    echo "${CCTL_ROOT}/templates/dspace/docker/docker-compose.yaml"
    echo "${CCTL_ROOT}/templates/dspace/docker/docker-compose.frontend.yaml"
}

@test "templates: rede de topo de cada compose e external e aponta para CCTL_PROJECT_NETWORK" {
    local f block
    while IFS= read -r f; do
        [[ -f "${f}" ]]
        block="$(_top_level_networks_block "${f}")"
        # o bloco existe e nao esta vazio (senao o grep abaixo passaria no vazio)
        [[ -n "${block}" ]] || { echo "sem bloco networks: em ${f}"; return 1; }
        grep -qE '^[[:space:]]+external:[[:space:]]*true[[:space:]]*$' <<< "${block}" \
            || { echo "falta 'external: true' em ${f}"; return 1; }
        grep -qF 'name: ${CCTL_PROJECT_NETWORK}' <<< "${block}" \
            || { echo "falta 'name: \${CCTL_PROJECT_NETWORK}' em ${f}"; return 1; }
    done < <(_network_contract_compose_files)
}

@test "templates: nenhum compose tem ipam, subnet ou driver na rede (o cctl cria a rede)" {
    local f block
    while IFS= read -r f; do
        block="$(_top_level_networks_block "${f}")"
        [[ -n "${block}" ]]
        if grep -qE 'ipam|subnet|driver' <<< "${block}"; then
            echo "bloco de rede com ipam/subnet/driver em ${f}:"
            echo "${block}"
            return 1
        fi
    done < <(_network_contract_compose_files)
}

@test "templates: os servicos continuam ligados a rede logica (moodle-network / dspacenet)" {
    run grep -c '^      - moodle-network$' "${CCTL_ROOT}/templates/moodle/docker/docker-compose.yaml"
    assert_output "2"
    # os servicos do dspace usam as duas sintaxes (lista e mapa)
    run grep -cE '^      (- dspacenet|dspacenet:)$' "${CCTL_ROOT}/templates/dspace/docker/docker-compose.yaml"
    assert_output "3"
    run grep -c '^      - dspacenet$' "${CCTL_ROOT}/templates/dspace/docker/docker-compose.frontend.yaml"
    assert_output "1"
}

@test "templates: project.conf nao define faixa de rede (SUBNET_RANGE/SUBNET_PREFIX_LEN) em codigo ativo" {
    local t
    for t in moodle dspace; do
        run grep -vE '^[[:space:]]*#' "${CCTL_ROOT}/templates/${t}/project.conf"
        refute_output --partial "SUBNET_RANGE"
        refute_output --partial "SUBNET_PREFIX_LEN"
    done
}

@test "templates: .env.template deixa CCTL_PROJECT_NETWORK e COMPOSE_PROJECT_SUBNET vazios (preenchidos pelo cctl install)" {
    local t
    for t in moodle dspace; do
        grep -qxF 'CCTL_PROJECT_NETWORK=' "${CCTL_ROOT}/templates/${t}/docker/.env.template"
        grep -qxF 'COMPOSE_PROJECT_SUBNET=' "${CCTL_ROOT}/templates/${t}/docker/.env.template"
        grep -q 'preenchido pelo cctl install' "${CCTL_ROOT}/templates/${t}/docker/.env.template"
    done
}

@test "templates: dspace continua entregando a subnet como proxy confiavel do backend" {
    grep -qF 'proxies__P__trusted__P__ipranges: "${COMPOSE_PROJECT_SUBNET}"' \
        "${CCTL_ROOT}/templates/dspace/docker/docker-compose.yaml"
}

# --- vhosts dos templates: alvo <container>.<rede> -------------------------------

@test "templates: todo 'set \$target' dos vhosts usa {{COMPOSE_PROJECT_NAME}}-<servico>.{{CCTL_PROJECT_NETWORK}}:<porta>" {
    local f n=0 line
    while IFS= read -r f; do
        while IFS= read -r line; do
            n=$((n + 1))
            [[ "${line}" =~ set\ \$target\ \{\{COMPOSE_PROJECT_NAME\}\}-[a-z-]+\.\{\{CCTL_PROJECT_NETWORK\}\}:[0-9]+\; ]] \
                || { echo "alvo fora do formato em ${f}: ${line}"; return 1; }
        done < <(grep -E 'set \$target' "${f}")
    done < <(find "${CCTL_ROOT}/templates" -path '*/nginx/*.template' -print)
    # moodle (ssl + nossl) = 2, dspace (backend + frontend) = 2
    [[ "${n}" -eq 4 ]]
}

@test "templates: nenhum alvo curto (nome do servico sem projeto/rede) sobra nos templates" {
    run grep -rnE 'set \$target [a-z-]+:' "${CCTL_ROOT}/templates"
    assert_failure
}

@test "templates: o container_name de cada servico-alvo e exatamente \${COMPOSE_PROJECT_NAME}-<servico>" {
    local base="${CCTL_ROOT}/templates"
    run awk '/^  moodle-app:/{f=1;next} /^  [a-z-]+:/{f=0} f && /container_name:/{print $2}' "${base}/moodle/docker/docker-compose.yaml"
    assert_output '${COMPOSE_PROJECT_NAME}-moodle-app'
    run awk '/^  dspace:/{f=1;next} /^  [a-z-]+:/{f=0} f && /container_name:/{print $2}' "${base}/dspace/docker/docker-compose.yaml"
    assert_output '${COMPOSE_PROJECT_NAME}-dspace'
    run awk '/^  dspace-angular:/{f=1;next} /^  [a-z-]+:/{f=0} f && /container_name:/{print $2}' "${base}/dspace/docker/docker-compose.frontend.yaml"
    assert_output '${COMPOSE_PROJECT_NAME}-dspace-angular'
}
