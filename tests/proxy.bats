#!/usr/bin/env bats
# tests/proxy.bats — testes para commands/proxy.sh e lib/nginx.sh (nginx_proxy_*)
#
# Isolamento total: nenhum container real, nenhuma porta bindada. `docker` e
# `sudo` sao sempre mockados via bin/ temporario no PATH (setup_mock_bin).

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh core.sh nginx.sh
    # shellcheck source=/dev/null
    source "${CCTL_ROOT}/commands/proxy.sh"

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    export NGINX_CONTAINER_NAME="nginx-proxy"
    export PROXY_NETWORK="cctl-proxy-net"
    export NGINX_PROXY_IMAGE="ghcr.io/diegobianchetti/nginx-proxy:latest"
    export PROXY_HTTP_PORT="80"
    export PROXY_HTTPS_PORT="443"
    export CCTL_BASE_DIR="${WORKDIR}/base"
    export CCTL_INSTANCE_BASE_DIR="${WORKDIR}/base/instances"
    export NGINX_VHOSTS_DIR="${WORKDIR}/vhosts.d"
    export LETSENCRYPT_DIR="${WORKDIR}/letsencrypt"

    mock_sudo_passthrough
}

teardown() {
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && chmod -R 777 "${WORKDIR}" 2>/dev/null || true
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

# Mock generico de docker parametrizavel por variaveis de ambiente:
#   DOCKER_NETWORK_EXISTS=1     -> "docker network inspect <net>" sucede
#   DOCKER_CONTAINER_STATE=""   -> vazio = nao existe; "running"/"exited" etc
#   DOCKER_NGINX_T_FAIL=1       -> "nginx -t" via docker exec falha
#   DOCKER_RUN_FAIL=1           -> "docker run" falha
#   DOCKER_RM_FAIL=1            -> "docker rm" falha
_mock_docker_proxy() {
    mock_cmd docker '
        log="'"${WORKDIR}"'/docker.log"
        echo "$*" >> "${log}"

        case "$1" in
            network)
                case "$2" in
                    inspect)
                        [[ "'"${DOCKER_NETWORK_EXISTS:-0}"'" == "1" ]] && exit 0
                        exit 1
                        ;;
                    create)
                        exit 0
                        ;;
                esac
                ;;
            inspect)
                state="'"${DOCKER_CONTAINER_STATE:-}"'"
                [[ -z "${state}" ]] && exit 1
                # -f "{{.State.Status}}" (up) ou outro formato (status/status)
                for a in "$@"; do
                    if [[ "$a" == *".State.Health.Status"* ]]; then
                        echo "healthy"
                        exit 0
                    fi
                    if [[ "$a" == *".NetworkSettings.Ports"* ]]; then
                        echo "80/tcp 443/tcp "
                        exit 0
                    fi
                    if [[ "$a" == *".State.Status"* ]]; then
                        echo "${state}"
                        exit 0
                    fi
                done
                exit 0
                ;;
            run)
                [[ "'"${DOCKER_RUN_FAIL:-0}"'" == "1" ]] && exit 1
                exit 0
                ;;
            start)
                exit 0
                ;;
            stop)
                exit 0
                ;;
            rm)
                [[ "'"${DOCKER_RM_FAIL:-0}"'" == "1" ]] && exit 1
                exit 0
                ;;
            exec)
                for a in "$@"; do
                    if [[ "$a" == "-t" ]]; then
                        [[ "'"${DOCKER_NGINX_T_FAIL:-0}"'" == "1" ]] && exit 1
                        exit 0
                    fi
                done
                exit 0
                ;;
            logs)
                echo "LOGS_CALLED $*"
                exit 0
                ;;
        esac
        exit 0
    '
}

# --- nginx_proxy_up ---------------------------------------------------------

@test "nginx_proxy_up: cria a rede quando ela nao existe" {
    DOCKER_NETWORK_EXISTS=0 DOCKER_CONTAINER_STATE="" _mock_docker_proxy

    run nginx_proxy_up
    assert_success
    grep -q "network create cctl-proxy-net" "${WORKDIR}/docker.log"
}

@test "nginx_proxy_up: nao recria a rede quando ela ja existe" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy

    run nginx_proxy_up
    assert_success
    run grep -q "network create" "${WORKDIR}/docker.log"
    assert_failure
}

@test "nginx_proxy_up: cria os diretorios de host necessarios (incluindo letsencrypt)" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy

    run nginx_proxy_up
    assert_success
    [[ -d "${NGINX_VHOSTS_DIR}" ]]
    [[ -d "${LETSENCRYPT_DIR}" ]]
}

@test "nginx_proxy_up: cria a arvore inteira a partir de CCTL_BASE_DIR (incluindo instances/)" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy

    run nginx_proxy_up
    assert_success
    [[ -d "${CCTL_BASE_DIR}" ]]
    [[ -d "${CCTL_INSTANCE_BASE_DIR}" ]]
}

@test "nginx_proxy_up: sobe o container via docker run quando ele nao existe" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy

    run nginx_proxy_up
    assert_success
    grep -q "^run " "${WORKDIR}/docker.log"
    grep -q "nginx-proxy" "${WORKDIR}/docker.log"
}

@test "nginx_proxy_up: monta vhosts no subdiretorio conf.d/vhosts (nao sobrepoe conf.d inteiro)" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy

    run nginx_proxy_up
    assert_success
    grep -q -- "-v ${NGINX_VHOSTS_DIR}:/etc/nginx/conf.d/vhosts:ro" "${WORKDIR}/docker.log"
    run grep -q -- "-v ${NGINX_VHOSTS_DIR}:/etc/nginx/conf.d:ro" "${WORKDIR}/docker.log"
    assert_failure
}

@test "nginx_proxy_up: monta /etc/letsencrypt em leitura-escrita (RW) — certbot escreve la dentro" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy

    run nginx_proxy_up
    assert_success
    grep -q -- "-v ${LETSENCRYPT_DIR}:/etc/letsencrypt:rw" "${WORKDIR}/docker.log"
    # prova de aceite: NAO pode ter regredido para :ro
    run grep -q -- "-v ${LETSENCRYPT_DIR}:/etc/letsencrypt:ro" "${WORKDIR}/docker.log"
    assert_failure
}

@test "nginx_proxy_up: NAO monta um segundo destino de certificado (/etc/nginx/certs)" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy

    run nginx_proxy_up
    assert_success
    run grep -q -- "/etc/nginx/certs" "${WORKDIR}/docker.log"
    assert_failure
}

@test "nginx_proxy_up: NAO monta o webroot do certbot (interno a imagem)" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy

    run nginx_proxy_up
    assert_success
    run grep -q -- "/var/www/certbot" "${WORKDIR}/docker.log"
    assert_failure
}

# --- nginx_proxy_up: chown das folhas (regressao B2) -----------------------
#
# Nao da para simular dono real diferente sem root — a arvore criada pelo
# proprio teste sempre pertence ao usuario que roda a suite. Para exercitar
# o ramo "precisa chown", forca via override de _nginx_dir_needs_chown (seam
# de teste documentada em lib/nginx.sh) em vez de manipular permissoes reais.

@test "nginx_proxy_up: chown atinge as folhas operacionais mas NAO o letsencrypt (regressao B2)" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy
    _nginx_dir_needs_chown() { return 0; }

    run nginx_proxy_up
    assert_success

    local owner
    owner="$(id -un)"

    # (a) as folhas operacionais estao no alvo do chown
    grep -q -- "sudo-called: chown -R ${owner}:${owner} ${CCTL_INSTANCE_BASE_DIR}" "${WORKDIR}/sudo.log"
    grep -q -- "sudo-called: chown -R ${owner}:${owner} ${NGINX_VHOSTS_DIR}" "${WORKDIR}/sudo.log"
    # CCTL_BASE_DIR em si recebe chown, mas SEM "-R"
    grep -q -- "sudo-called: chown ${owner}:${owner} ${CCTL_BASE_DIR}" "${WORKDIR}/sudo.log"

    # (b) letsencrypt NAO aparece em nenhuma chamada de chown — e a
    # regressao do B2: sem esta assercao, o blocker volta sem ninguem notar
    run grep -- "chown.*${LETSENCRYPT_DIR}" "${WORKDIR}/sudo.log"
    assert_failure
}

@test "nginx_proxy_up: nao chama sudo chown quando a arvore ja pertence ao operador" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy
    # comportamento real (sem override): dirs criados pelo proprio teste ja
    # pertencem a quem roda a suite — sudo chown incondicional viraria
    # prompt de senha em todo "proxy up" do dia a dia (observacao 2)

    run nginx_proxy_up
    assert_success

    run grep -- "chown" "${WORKDIR}/sudo.log"
    assert_failure
}

@test "nginx_proxy_up: inclui --cap-add NET_RAW (contrato do docker-compose do nginx-proxy)" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy

    run nginx_proxy_up
    assert_success
    grep -q -- "--cap-add NET_RAW" "${WORKDIR}/docker.log"
}

@test "nginx_proxy_up: publica as portas HTTP e HTTPS configuradas" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy

    run nginx_proxy_up
    assert_success
    grep -q -- "-p 80:80" "${WORKDIR}/docker.log"
    grep -q -- "-p 443:443" "${WORKDIR}/docker.log"
}

@test "nginx_proxy_up: idempotente — avisa sem falhar se o container ja esta rodando" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="running" _mock_docker_proxy

    run nginx_proxy_up
    assert_success
    assert_output --partial "ja esta em execucao"
    run grep -q "^run " "${WORKDIR}/docker.log"
    assert_failure
}

@test "nginx_proxy_up: inicia o container quando ele existe mas esta parado" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="exited" _mock_docker_proxy

    run nginx_proxy_up
    assert_success
    grep -q "^start " "${WORKDIR}/docker.log"
    run grep -q "^run " "${WORKDIR}/docker.log"
    assert_failure
}

@test "nginx_proxy_up: aborta com erro se PROXY_HTTP_PORT nao for numerico" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy
    export PROXY_HTTP_PORT="oitenta"

    run nginx_proxy_up
    assert_failure
    assert_output --partial "PROXY_HTTP_PORT invalido"
    run grep -q "^run " "${WORKDIR}/docker.log"
    assert_failure
}

@test "nginx_proxy_up: aborta com erro se PROXY_HTTPS_PORT nao for numerico" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy
    export PROXY_HTTPS_PORT="443;rm -rf"

    run nginx_proxy_up
    assert_failure
    assert_output --partial "PROXY_HTTPS_PORT invalido"
    run grep -q "^run " "${WORKDIR}/docker.log"
    assert_failure
}

@test "nginx_proxy_up: retorna 1 e loga erro quando docker run falha" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" DOCKER_RUN_FAIL=1 _mock_docker_proxy

    run nginx_proxy_up
    assert_failure
    assert_output --partial "Falha ao subir o container"
}

# --- nginx_proxy_down --------------------------------------------------------

@test "nginx_proxy_down: para e remove o container quando ele existe" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="running" _mock_docker_proxy

    run nginx_proxy_down
    assert_success
    grep -q "^stop " "${WORKDIR}/docker.log"
    grep -q "^rm " "${WORKDIR}/docker.log"
}

@test "nginx_proxy_down: avisa sem falhar quando o container nao existe" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy

    run nginx_proxy_down
    assert_success
    assert_output --partial "nao existe"
    run grep -q "^stop " "${WORKDIR}/docker.log"
    assert_failure
}

@test "nginx_proxy_down: loga erro e retorna 1 quando docker rm falha" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="running" DOCKER_RM_FAIL=1 _mock_docker_proxy

    run nginx_proxy_down
    assert_failure
    assert_output --partial "Falha ao remover o container"
}

# --- nginx_proxy_reload ------------------------------------------------------

@test "nginx_proxy_reload: testa e recarrega quando a config e valida" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="running" DOCKER_NGINX_T_FAIL=0 _mock_docker_proxy

    run nginx_proxy_reload
    assert_success
    grep -q "exec nginx-proxy nginx -t" "${WORKDIR}/docker.log"
    grep -q "exec nginx-proxy nginx -s reload" "${WORKDIR}/docker.log"
}

@test "nginx_proxy_reload: falha e aborta sem recarregar quando nginx -t falha" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="running" DOCKER_NGINX_T_FAIL=1 _mock_docker_proxy

    run nginx_proxy_reload
    assert_failure
    assert_output --partial "invalida"
    run grep -q "nginx -s reload" "${WORKDIR}/docker.log"
    assert_failure
}

@test "nginx_proxy_reload: pre-condicao — avisa e retorna 1 quando container nao existe" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy

    run nginx_proxy_reload
    assert_failure
    assert_output --partial "Container nginx-proxy nao existe"
    assert_output --partial "cctl proxy up"
    run grep -q "^exec " "${WORKDIR}/docker.log"
    assert_failure
}

# --- nginx_proxy_test ---------------------------------------------------------

@test "nginx_proxy_test: sucesso quando nginx -t passa" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="running" DOCKER_NGINX_T_FAIL=0 _mock_docker_proxy

    run nginx_proxy_test
    assert_success
}

@test "nginx_proxy_test: reporta erro quando nginx -t falha" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="running" DOCKER_NGINX_T_FAIL=1 _mock_docker_proxy

    run nginx_proxy_test
    assert_failure
}

@test "nginx_proxy_test: pre-condicao — avisa e retorna 1 quando container nao existe" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy

    run nginx_proxy_test
    assert_failure
    assert_output --partial "Container nginx-proxy nao existe"
}

# --- nginx_proxy_status -------------------------------------------------------

@test "nginx_proxy_status: exibe status, saude e portas com precisao para container em execucao" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="running" _mock_docker_proxy

    run nginx_proxy_status
    assert_success
    assert_output --partial "Status:    running"
    assert_output --partial "Saude:     healthy"
    assert_output --partial "Portas:    80/tcp 443/tcp"
    assert_output --partial "Rede cctl-proxy-net: existe"
}

@test "nginx_proxy_status: avisa quando o container nao existe" {
    DOCKER_NETWORK_EXISTS=0 DOCKER_CONTAINER_STATE="" _mock_docker_proxy

    run nginx_proxy_status
    assert_success
    assert_output --partial "nao existe"
    assert_output --partial "Rede cctl-proxy-net: nao existe"
}

# --- nginx_proxy_logs ----------------------------------------------------------

@test "nginx_proxy_logs: encaminha flags extras para docker logs" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="running" _mock_docker_proxy

    run nginx_proxy_logs -f --tail 100
    assert_success
    assert_output --partial "LOGS_CALLED logs nginx-proxy -f --tail 100"
}

@test "nginx_proxy_logs: pre-condicao — avisa e retorna 1 quando container nao existe" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="" _mock_docker_proxy

    run nginx_proxy_logs -f
    assert_failure
    assert_output --partial "Container nginx-proxy nao existe"
}

# --- cmd_proxy (dispatcher / help) ---------------------------------------------

@test "cmd_proxy: sem acao exibe uso e nao falha" {
    run cmd_proxy
    assert_success
    assert_output --partial "cctl proxy <up|down|reload|test|logs|status>"
}

@test "cmd_proxy: acao desconhecida exibe uso e falha" {
    run cmd_proxy foo
    assert_failure
    assert_output --partial "Acao desconhecida"
    assert_output --partial "cctl proxy <up|down|reload|test|logs|status>"
}

@test "cmd_proxy: despacha 'up' para nginx_proxy_up" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="running" _mock_docker_proxy

    run cmd_proxy up
    assert_success
    assert_output --partial "ja esta em execucao"
}

@test "cmd_proxy: despacha 'down' para nginx_proxy_down" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="running" _mock_docker_proxy

    run cmd_proxy down
    assert_success
    grep -q "^stop " "${WORKDIR}/docker.log"
    grep -q "^rm " "${WORKDIR}/docker.log"
}

@test "cmd_proxy: despacha 'reload' para nginx_proxy_reload" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="running" DOCKER_NGINX_T_FAIL=0 _mock_docker_proxy

    run cmd_proxy reload
    assert_success
    grep -q "exec nginx-proxy nginx -s reload" "${WORKDIR}/docker.log"
}

@test "cmd_proxy: despacha 'test' para nginx_proxy_test" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="running" DOCKER_NGINX_T_FAIL=0 _mock_docker_proxy

    run cmd_proxy test
    assert_success
    grep -q "exec nginx-proxy nginx -t" "${WORKDIR}/docker.log"
}

@test "cmd_proxy: despacha 'logs' com flags extras para nginx_proxy_logs" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="running" _mock_docker_proxy

    run cmd_proxy logs -f --tail 50
    assert_success
    assert_output --partial "LOGS_CALLED logs nginx-proxy -f --tail 50"
}

@test "cmd_proxy: despacha 'status' para nginx_proxy_status" {
    DOCKER_NETWORK_EXISTS=1 DOCKER_CONTAINER_STATE="running" _mock_docker_proxy

    run cmd_proxy status
    assert_success
    assert_output --partial "Status do proxy"
}

# --- core_check_command_context: proxy liberado em qualquer contexto ----------

@test "core_check_command_context: proxy permitido em contexto template" {
    CCTL_CONTEXT="template"
    run core_check_command_context "proxy"
    assert_success
}

@test "core_check_command_context: proxy permitido em contexto project" {
    CCTL_CONTEXT="project"
    run core_check_command_context "proxy"
    assert_success
}

@test "core_check_command_context: proxy permitido em contexto instance" {
    CCTL_CONTEXT="instance"
    run core_check_command_context "proxy"
    assert_success
}

@test "core_check_command_context: proxy permitido em contexto unknown" {
    # shellcheck disable=SC2034  # lida por core_check_command_context (lib/core.sh) via nome da var
    CCTL_CONTEXT="unknown"
    run core_check_command_context "proxy"
    assert_success
}
