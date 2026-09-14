#!/usr/bin/env bats
# tests/install.bats — testes para commands/install.sh (bootstrap ACME,
# selecao de vhost nginx conforme SSL_MODE, e _install_set_ssl_paths)
#
# Isolamento: nenhum comando externo real e chamado — docker e sudo sao
# sempre mockados via bin/ temporario no PATH. Nenhum container, porta ou
# config real do host e tocado.

bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh core.sh env.sh network.sh compose.sh nginx.sh ssl.sh
    # shellcheck source=/dev/null
    source "${CCTL_ROOT}/commands/install.sh"

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    export NGINX_VHOSTS_DIR="${WORKDIR}/vhosts"
    mkdir -p "${NGINX_VHOSTS_DIR}"
    mkdir -p nginx

    # sudo mockado: registra chamada e executa o comando real por baixo
    mock_sudo_passthrough
    # docker sempre sucesso (nginx -t / -s reload / inspect / network ls)
    mock_cmd docker 'exit 0'
}

teardown() {
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && chmod -R 777 "${WORKDIR}" 2>/dev/null || true
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

# ============================================================
# _install_bootstrap_letsencrypt_http_vhost
# ============================================================

@test "_install_bootstrap_letsencrypt_http_vhost: cria vhost isolado em .acme-bootstrap.conf com rota ACME" {
    export DOMAIN_NAME="app.example.com"
    export COMPOSE_PROJECT_NAME="app"
    echo "CONTEUDO-HTTPS-FINAL-NAO-TOCAR" > ./nginx/site.conf

    run _install_bootstrap_letsencrypt_http_vhost
    assert_success

    # o vhost aplicado no nginx-proxy contem a rota do desafio ACME
    grep -q "acme-challenge" "${NGINX_VHOSTS_DIR}/app.conf"
    grep -q "listen 80" "${NGINX_VHOSTS_DIR}/app.conf"
}

@test "_install_bootstrap_letsencrypt_http_vhost: NUNCA sobrescreve ./nginx/site.conf" {
    export DOMAIN_NAME="app.example.com"
    export COMPOSE_PROJECT_NAME="app"
    echo "CONTEUDO-HTTPS-FINAL-NAO-TOCAR" > ./nginx/site.conf

    run _install_bootstrap_letsencrypt_http_vhost
    assert_success

    [[ "$(cat ./nginx/site.conf)" == "CONTEUDO-HTTPS-FINAL-NAO-TOCAR" ]]
    run ! grep -q "CONTEUDO-HTTPS-FINAL-NAO-TOCAR" "${NGINX_VHOSTS_DIR}/app.conf"
}

@test "_install_bootstrap_letsencrypt_http_vhost: remove o vhost temporario ao final" {
    export DOMAIN_NAME="app.example.com"
    export COMPOSE_PROJECT_NAME="app"

    run _install_bootstrap_letsencrypt_http_vhost
    assert_success

    [[ ! -f ./nginx/.acme-bootstrap.conf ]]
}

@test "_install_bootstrap_letsencrypt_http_vhost: vhost final aplicado depois e o HTTPS (nao o bootstrap)" {
    export DOMAIN_NAME="app.example.com"
    export COMPOSE_PROJECT_NAME="app"

    run _install_bootstrap_letsencrypt_http_vhost
    assert_success
    grep -q "acme-challenge" "${NGINX_VHOSTS_DIR}/app.conf"

    # simula o passo seguinte do fluxo real: _install_nginx aplica o vhost
    # HTTPS final (./nginx/site.conf), sobrescrevendo o bootstrap no proxy
    cat > ./nginx/site.conf <<'EOF'
server {
    listen 443 ssl;
    server_name app.example.com;
    ssl_certificate     /etc/letsencrypt/live/app.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/app.example.com/privkey.pem;
}
EOF
    export HOST_NGINX=true
    export SSL_MODE=letsencrypt
    export HOST_SSL=true

    run _install_nginx
    assert_success

    grep -q "listen 443 ssl" "${NGINX_VHOSTS_DIR}/app.conf"
    run ! grep -q "acme-challenge" "${NGINX_VHOSTS_DIR}/app.conf"
}

# ============================================================
# _install_nginx — selecao de vhost conforme SSL_MODE
# ============================================================

@test "_install_nginx: SSL_MODE=none com site-nossl.conf.template renderiza o nossl para site.conf" {
    export HOST_NGINX=true
    export DOMAIN_NAME="app.example.com"
    export COMPOSE_PROJECT_NAME="app"
    export SSL_MODE=none

    echo "DOMAIN_NAME=app.example.com" > .env
    cat > ./nginx/site-nossl.conf.template <<'EOF'
server {
    listen 80;
    server_name {{DOMAIN_NAME}};
}
EOF
    echo "CONTEUDO-ANTIGO-DEVE-SER-SUBSTITUIDO" > ./nginx/site.conf

    run _install_nginx
    assert_success

    grep -q "server_name app.example.com" ./nginx/site.conf
    run ! grep -q "CONTEUDO-ANTIGO-DEVE-SER-SUBSTITUIDO" ./nginx/site.conf
    grep -q "app.example.com" "${NGINX_VHOSTS_DIR}/app.conf"
}

@test "_install_nginx: SSL_MODE=none sem site-nossl.conf.template limpa diretivas ssl_certificate vazias" {
    export HOST_NGINX=true
    export DOMAIN_NAME="app.example.com"
    export COMPOSE_PROJECT_NAME="app"
    export SSL_MODE=none

    cat > ./nginx/site.conf <<'EOF'
server {
    listen 443 ssl;
    server_name app.example.com;
    ssl_certificate     ;
    ssl_certificate_key ;
}
EOF

    run _install_nginx
    assert_success

    run ! grep -q "ssl_certificate" ./nginx/site.conf
    grep -q "server_name app.example.com" ./nginx/site.conf
    # vhost aplicado no proxy tambem reflete a limpeza
    run ! grep -q "ssl_certificate" "${NGINX_VHOSTS_DIR}/app.conf"
}

@test "_install_nginx: retorna 1 quando nginx_enable_site falha" {
    export HOST_NGINX=true
    export DOMAIN_NAME="app.example.com"
    export COMPOSE_PROJECT_NAME="app"
    export SSL_MODE=letsencrypt
    export HOST_SSL=true
    # diretorio de vhosts inexistente -> nginx_enable_site retorna 1
    export NGINX_VHOSTS_DIR="${WORKDIR}/vhosts-inexistente"

    echo "server { listen 443 ssl; }" > ./nginx/site.conf

    run _install_nginx
    assert_failure
}

# ============================================================
# _install_cleanup_orphan_network (P2: recuperacao de rede orfa)
# ============================================================

@test "_install_cleanup_orphan_network: desconecta o proxy e remove rede orfa antes de recriar" {
    export COMPOSE_PROJECT_NAME="app"

    declare -A CCTL_TEST_NETS=( [app_network]="app" )
    mock_docker_with_networks CCTL_TEST_NETS "${WORKDIR}/docker_calls.log"

    run _install_cleanup_orphan_network
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "network disconnect app_network nginx-proxy"
    assert_output --partial "network rm app_network"
}

@test "_install_cleanup_orphan_network: sem rede orfa nao chama disconnect/rm" {
    export COMPOSE_PROJECT_NAME="app"

    declare -A CCTL_TEST_NETS=()
    mock_docker_with_networks CCTL_TEST_NETS "${WORKDIR}/docker_calls.log"

    run _install_cleanup_orphan_network
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    refute_output --partial "network disconnect"
    refute_output --partial "network rm"
}

@test "_install_cleanup_orphan_network (regressao B1): projeto 'moodle' nao toca a rede de 'moodle-lab'" {
    export COMPOSE_PROJECT_NAME="moodle"

    declare -A CCTL_TEST_NETS=(
        [moodle_network]=""
        [moodle-lab_moodle-network]=""
    )
    mock_docker_with_networks CCTL_TEST_NETS "${WORKDIR}/docker_calls.log"

    run _install_cleanup_orphan_network
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "network disconnect moodle_network nginx-proxy"
    assert_output --partial "network rm moodle_network"
    refute_output --partial "network disconnect moodle-lab_moodle-network nginx-proxy"
    refute_output --partial "network rm moodle-lab_moodle-network"
}

# ============================================================
# _install_set_ssl_paths
# ============================================================

@test "_install_set_ssl_paths: modo letsencrypt seta SSL_CERT_PATH/SSL_KEY_PATH no .env" {
    touch .env
    export DOMAIN_NAME="app.example.com"
    export SSL_MODE=letsencrypt

    run _install_set_ssl_paths
    assert_success

    grep -q "^SSL_CERT_PATH=/etc/letsencrypt/live/app.example.com/fullchain.pem$" .env
    grep -q "^SSL_KEY_PATH=/etc/letsencrypt/live/app.example.com/privkey.pem$" .env
}

@test "_install_set_ssl_paths: modo manual/self-signed aponta para /etc/letsencrypt (sem 'live')" {
    touch .env
    export DOMAIN_NAME="app.example.com"
    export SSL_MODE=manual

    run _install_set_ssl_paths
    assert_success

    grep -q "^SSL_CERT_PATH=/etc/letsencrypt/app.example.com/fullchain.pem$" .env
    grep -q "^SSL_KEY_PATH=/etc/letsencrypt/app.example.com/privkey.pem$" .env
}

@test "_install_set_ssl_paths: modo none seta paths vazios" {
    touch .env
    export DOMAIN_NAME="app.example.com"
    export SSL_MODE=none

    run _install_set_ssl_paths
    assert_success

    grep -qE "^SSL_CERT_PATH=$" .env
    grep -qE "^SSL_KEY_PATH=$" .env
}
