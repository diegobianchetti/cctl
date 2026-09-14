#!/usr/bin/env bats
# tests/nginx.bats — testes para lib/nginx.sh (sudo condicional e enable/disable site)

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh core.sh nginx.sh vhost.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    # sudo mockado: registra que foi chamado e executa o comando de verdade
    mock_sudo_passthrough
}

teardown() {
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && chmod -R 777 "${WORKDIR}" 2>/dev/null || true
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

# --- _nginx_priv -----------------------------------------------------------

@test "_nginx_priv: nao usa sudo quando o destino e gravavel pelo usuario" {
    mkdir -p vhosts
    echo "conteudo" > src.conf

    _nginx_priv cp src.conf vhosts/dst.conf

    [[ -f vhosts/dst.conf ]]
    [[ ! -f sudo.log ]]
}

@test "_nginx_priv: usa sudo quando o diretorio de destino nao e gravavel" {
    [[ "${EUID}" -eq 0 ]] && skip "root ignora permissoes de diretorio"

    mkdir -p vhosts_ro
    chmod 555 vhosts_ro
    echo "conteudo" > src.conf

    # a copia real vai falhar (dir read-only e sem sudo real), mas o que
    # importa aqui e confirmar que o helper tentou via sudo
    _nginx_priv cp src.conf vhosts_ro/dst.conf || true

    chmod 755 vhosts_ro
    [[ -f sudo.log ]]
}

@test "_nginx_priv: cp usa sudo quando o alvo ja existe e nao e gravavel" {
    [[ "${EUID}" -eq 0 ]] && skip "root ignora permissoes de arquivo"

    mkdir -p vhosts
    echo "velho" > vhosts/dst.conf
    chmod 444 vhosts/dst.conf
    echo "novo" > src.conf

    _nginx_priv cp src.conf vhosts/dst.conf || true

    chmod 644 vhosts/dst.conf
    [[ -f sudo.log ]]
}

@test "_nginx_priv: rm nao usa sudo quando o diretorio-pai e gravavel, mesmo com arquivo read-only" {
    mkdir -p vhosts
    touch vhosts/dst.conf
    chmod 444 vhosts/dst.conf

    _nginx_priv rm -f vhosts/dst.conf

    [[ ! -f vhosts/dst.conf ]]
    [[ ! -f sudo.log ]]
}

@test "_nginx_priv: rm usa sudo quando o diretorio-pai nao e gravavel (independente do arquivo)" {
    [[ "${EUID}" -eq 0 ]] && skip "root ignora permissoes de diretorio"

    mkdir -p vhosts_ro
    touch vhosts_ro/dst.conf
    chmod 555 vhosts_ro

    _nginx_priv rm -f vhosts_ro/dst.conf || true

    chmod 755 vhosts_ro
    [[ -f sudo.log ]]
}

# --- nginx_enable_site / nginx_disable_site --------------------------------

@test "nginx_enable_site: falha quando a config de origem nao existe" {
    export NGINX_VHOSTS_DIR="${WORKDIR}/vhosts"
    mkdir -p "${NGINX_VHOSTS_DIR}"

    run nginx_enable_site "app.example.com" "./nginx/site.conf"
    assert_failure
    assert_output --partial "nao encontrada"
}

@test "nginx_enable_site: falha quando NGINX_VHOSTS_DIR nao existe" {
    mkdir -p nginx
    echo "server {}" > nginx/site.conf
    export NGINX_VHOSTS_DIR="${WORKDIR}/vhosts-inexistente"

    run nginx_enable_site "app.example.com" "./nginx/site.conf"
    assert_failure
    assert_output --partial "nao existe"
}

@test "nginx_enable_site: copia vhost e nao usa sudo em diretorio gravavel" {
    mkdir -p nginx vhosts
    echo "server {}" > nginx/site.conf
    export NGINX_VHOSTS_DIR="${WORKDIR}/vhosts"
    export COMPOSE_PROJECT_NAME="app"
    mock_cmd docker 'exit 0' # nginx -t / -s reload sempre validos

    run nginx_enable_site "app.example.com" "./nginx/site.conf"
    assert_success
    [[ -f "${NGINX_VHOSTS_DIR}/app.conf" ]]
    [[ ! -f sudo.log ]]
}

@test "nginx_disable_site: remove vhost e nao usa sudo em diretorio gravavel" {
    mkdir -p vhosts
    export NGINX_VHOSTS_DIR="${WORKDIR}/vhosts"
    export COMPOSE_PROJECT_NAME="app"
    touch "${NGINX_VHOSTS_DIR}/app.conf"
    mock_cmd docker 'exit 0'

    run nginx_disable_site "app.example.com"
    assert_success
    [[ ! -f "${NGINX_VHOSTS_DIR}/app.conf" ]]
    [[ ! -f sudo.log ]]
}

@test "nginx_enable_site: aborta quando a copia do vhost falha" {
    mkdir -p nginx vhosts_ro
    echo "server {}" > nginx/site.conf
    chmod 555 vhosts_ro
    export NGINX_VHOSTS_DIR="${WORKDIR}/vhosts_ro"
    export COMPOSE_PROJECT_NAME="app"
    # sudo mockado falha tambem, simulando ausencia de privilegio real
    mock_cmd sudo 'exit 1'
    mock_cmd docker 'exit 0'

    run nginx_enable_site "app.example.com" "./nginx/site.conf"
    assert_failure
    assert_output --partial "Falha ao copiar"

    chmod 755 vhosts_ro
}

@test "nginx_disable_site: aborta quando a copia de backup do vhost falha (origem ilegivel)" {
    [[ "${EUID}" -eq 0 ]] && skip "root ignora permissoes de arquivo"

    mkdir -p vhosts
    export NGINX_VHOSTS_DIR="${WORKDIR}/vhosts"
    export COMPOSE_PROJECT_NAME="app"
    touch "${NGINX_VHOSTS_DIR}/app.conf"
    chmod 000 "${NGINX_VHOSTS_DIR}/app.conf"
    # sudo mockado falha tambem, simulando ausencia de privilegio real
    mock_cmd sudo 'exit 1'
    mock_cmd docker 'exit 0'

    run nginx_disable_site "app.example.com"
    assert_failure
    assert_output --partial "Falha ao criar backup"

    chmod 644 "${NGINX_VHOSTS_DIR}/app.conf"
}

@test "nginx_disable_site: config invalida apos remocao aciona restauracao do backup" {
    mkdir -p vhosts
    export NGINX_VHOSTS_DIR="${WORKDIR}/vhosts"
    export COMPOSE_PROJECT_NAME="app"
    echo "server { original }" > "${NGINX_VHOSTS_DIR}/app.conf"

    # nginx -t sempre falha => forca o caminho de restauracao do backup
    mock_cmd docker 'for a in "$@"; do [[ "$a" == "-t" ]] && exit 1; done; exit 0'

    run nginx_disable_site "app.example.com"
    assert_failure
    assert_output --partial "Restaurando"
    # restauracao real: o vhost volta a existir com o conteudo original
    [[ -f "${NGINX_VHOSTS_DIR}/app.conf" ]]
    grep -q "original" "${NGINX_VHOSTS_DIR}/app.conf"
}

@test "nginx_disable_site: usa diretorio de backup unico via mktemp (nao reutiliza caminho previsivel em /tmp)" {
    mkdir -p vhosts
    export NGINX_VHOSTS_DIR="${WORKDIR}/vhosts"
    export COMPOSE_PROJECT_NAME="app"
    touch "${NGINX_VHOSTS_DIR}/app.conf"
    mock_cmd docker 'exit 0'

    run nginx_disable_site "app.example.com"
    assert_success
    # backup e limpo ao final (sucesso), e nao deve sobrar em caminho previsivel
    [[ ! -d "/tmp/nginx_backup_app" ]]
}

# --- regressao R1 (F2.2): nginx_enable_site restaura, nao apaga ------------
#
# Ate a F2.2, nginx_enable_site (lib/nginx.sh) apagava o vhost (`rm -f`) se
# o `nginx -t` falhasse apos aplicar a config nova — diferente dos outros
# dois donos (nginx_disable_site, _rollout_switch_vhost), que sempre
# restauravam do backup. Espelha "nginx_disable_site: config invalida apos
# remocao aciona restauracao do backup" (acima), mas para o caminho do
# enable, com um vhost JA instalado (cenario de reinstall/update). Este
# teste tem de FALHAR se a linha `rm -f` do vhost voltar.
@test "nginx_enable_site (regressao R1): config invalida apos aplicar RESTAURA o vhost original, nao apaga" {
    mkdir -p nginx vhosts
    export NGINX_VHOSTS_DIR="${WORKDIR}/vhosts"
    export COMPOSE_PROJECT_NAME="app"
    # vhost ja instalado ANTES desta chamada (cenario de update)
    echo "server { original }" > "${NGINX_VHOSTS_DIR}/app.conf"
    echo "server { novo }" > nginx/site.conf

    # nginx -t sempre falha => forca o caminho de restauracao do backup
    mock_cmd docker 'for a in "$@"; do [[ "$a" == "-t" ]] && exit 1; done; exit 0'

    run nginx_enable_site "app.example.com" "./nginx/site.conf"
    assert_failure
    assert_output --partial "Restaurando"

    # o vhost tem de existir com o conteudo ORIGINAL restaurado — nunca
    # apagado, nunca com o conteudo novo aplicado pela metade.
    [[ -f "${NGINX_VHOSTS_DIR}/app.conf" ]]
    grep -q "original" "${NGINX_VHOSTS_DIR}/app.conf"
    run grep -q "novo" "${NGINX_VHOSTS_DIR}/app.conf"
    assert_failure
}

@test "nginx_enable_site (garantia do modulo): primeira instalacao com nginx -t falho nao deixa vhost parcial para tras" {
    mkdir -p nginx vhosts
    export NGINX_VHOSTS_DIR="${WORKDIR}/vhosts"
    export COMPOSE_PROJECT_NAME="app"
    # sem vhost previo (primeira instalacao) — nao ha nada para restaurar
    echo "server { novo }" > nginx/site.conf

    mock_cmd docker 'for a in "$@"; do [[ "$a" == "-t" ]] && exit 1; done; exit 0'

    run nginx_enable_site "app.example.com" "./nginx/site.conf"
    assert_failure

    # restaurar o estado original (sem vhost previo) significa: sem vhost
    [[ ! -f "${NGINX_VHOSTS_DIR}/app.conf" ]]
}
