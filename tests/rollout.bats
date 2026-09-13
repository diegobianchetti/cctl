#!/usr/bin/env bats
# tests/rollout.bats — testes para lib/rollout.sh e commands/rollout.sh
#
# Isolamento total: nenhum container real, nenhuma porta bindada, nenhuma rede
# real. `docker` e `sudo` sao sempre mockados via bin/ temporario no PATH
# (setup_mock_bin). `sleep` tambem e mockado (so registra a chamada) para os
# testes de timeout serem rapidos e deterministicos.

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh validate.sh core.sh network.sh compose.sh nginx.sh rollout.sh

    local real_cctl_root
    real_cctl_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${real_cctl_root}/commands/rollout.sh"

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    export COMPOSE_PROJECT_NAME="testproj"
    COMPOSE_FILES=("docker-compose.yaml")
    export NGINX_CONTAINER_NAME="nginx-proxy"
    export NGINX_VHOSTS_DIR="${WORKDIR}/vhosts.d"
    export ROLLOUT_STATE_FILE="${WORKDIR}/.cctl-rollout"
    export ROLLOUT_HEALTH_INTERVAL=1
    unset ROLLOUT_SERVICE ROLLOUT_HEALTH_MODE ROLLOUT_HEALTH_TIMEOUT \
        ROLLOUT_HEALTH_PATH ROLLOUT_HEALTH_PORT ROLLOUT_DRAIN_SECONDS \
        ROLLOUT_PROBE_CONTAINER CCTL_CONTEXT 2>/dev/null || true

    mkdir -p "${NGINX_VHOSTS_DIR}"
    VHOST_FILE="${NGINX_VHOSTS_DIR}/testproj.conf"
    export VHOST_FILE

    _write_vhost "moodle-app" "443" "https"

    export CONTAINERS_EXIST="nginx-proxy testproj-moodle-app testproj-moodle-app-green"
    export COMPOSE_SERVICES="moodle-app"
    export HAS_CURL=1 HAS_WGET=0
    export PROBE_HTTP_CODE=200 PROBE_CURL_EXIT=0 PROBE_WGET_EXIT=0 PROBE_FAIL_FIRST_N=0
    export HEALTHY_AFTER=1 HAS_DOCKER_HEALTHCHECK=0
    export PREV_IMAGE="app:old"
    export CONTAINER_STATUS="running"
    export NGINX_T_FAIL=0
    export DOCKER_STOP_FAIL=0 DOCKER_RM_FAIL=0

    mock_sudo_passthrough
    _mock_docker_rollout
    mock_cmd sleep 'echo "sleep $*" >> "'"${WORKDIR}"'/sleep.log"; exit 0'
}

teardown() {
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && chmod -R 777 "${WORKDIR}" 2>/dev/null || true
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

# --- Fixtures ----------------------------------------------------------------

_write_vhost() {
    local alias="$1" port="$2" scheme="$3"
    cat > "${VHOST_FILE}" <<EOF
server {
	listen 80;
	server_name acme.example.br;
	location / {
		return 301 https://\$server_name\$request_uri;
	}
}

server {
	listen 443 ssl;
	server_name acme.example.br;

	ssl_certificate     /etc/certs/acme.pem;
	ssl_certificate_key /etc/certs/acme.key;

	location / {
		resolver 127.0.0.11;
		set \$target ${alias}:${port};
		proxy_pass ${scheme}://\$target;
		proxy_set_header Host \$http_host;
	}

	access_log /var/log/nginx/testproj-access.log;
	error_log  /var/log/nginx/testproj-error.log;
}
EOF
}

_write_state() {
    local service="$1" live_slot="$2"
    cat > "${ROLLOUT_STATE_FILE}" <<EOF
SERVICE="${service}"
LIVE_SLOT="${live_slot}"
LIVE_TARGET="dummy:443"
PREVIOUS_TARGET=""
IMAGE=""
UPDATED_AT="2026-09-01T00:00:00-03:00"
EOF
}

# Mock generico de `docker`/`docker compose`, parametrizavel por variaveis de
# ambiente exportadas no setup() (ou sobrescritas por teste).
_mock_docker_rollout() {
    mock_cmd docker '
        log="'"${WORKDIR}"'/docker.log"
        echo "$*" >> "${log}"

        case "$1" in
            network)
                case "$2" in
                    ls) echo "${PROJECT_NETWORK:-testproj_net}"; exit 0 ;;
                    connect) exit 0 ;;
                    inspect) exit 0 ;;
                    *) exit 0 ;;
                esac
                ;;
            compose)
                shift
                args=("$@")
                i=0
                sub=""
                while (( i < ${#args[@]} )); do
                    case "${args[$i]}" in
                        -f)
                            ovpath="${args[$((i+1))]}"
                            case "${ovpath}" in
                                *.rollout.yaml)
                                    {
                                        echo "=== override snapshot ==="
                                        cat "${ovpath}" 2>/dev/null
                                    } >> "'"${WORKDIR}"'/override_snapshot.log"
                                    ;;
                            esac
                            i=$((i+2))
                            ;;
                        -p) i=$((i+2)) ;;
                        *) sub="${args[$i]}"; i=$((i+1)); break ;;
                    esac
                done
                rest=("${args[@]:$i}")
                case "${sub}" in
                    config)
                        if [[ -n "${MOCK_COMPOSE_CONFIG_FAIL:-}" ]]; then
                            echo "erro simulado" >&2
                            exit 1
                        elif [[ "${rest[0]:-}" == "--services" ]]; then
                            printf "%s\n" ${COMPOSE_SERVICES:-moodle-app}
                            exit 0
                        fi
                        exit 0
                        ;;
                    up)
                        n=0
                        [[ -f "'"${WORKDIR}"'/up_calls.count" ]] && n=$(cat "'"${WORKDIR}"'/up_calls.count")
                        n=$((n+1))
                        echo "${n}" > "'"${WORKDIR}"'/up_calls.count"
                        [[ -n "${MOCK_COMPOSE_UP_FAIL:-}" ]] && exit 1
                        exit 0
                        ;;
                    stop)
                        [[ -n "${MOCK_COMPOSE_STOP_FAIL:-}" ]] && exit 1
                        exit 0
                        ;;
                    *) exit 0 ;;
                esac
                ;;
            inspect)
                shift
                fmt=""
                container=""
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        -f) fmt="$2"; shift 2 ;;
                        *) container="$1"; shift ;;
                    esac
                done
                exists=" ${CONTAINERS_EXIST:-} "
                if [[ "${exists}" != *" ${container} "* ]]; then
                    exit 1
                fi
                [[ -z "${fmt}" ]] && exit 0
                case "${fmt}" in
                    *"yes{{end}}"*)
                        [[ "${HAS_DOCKER_HEALTHCHECK:-0}" == "1" ]] && echo "yes"
                        exit 0
                        ;;
                    *".State.Health.Status"*)
                        cnt_file="'"${WORKDIR}"'/health_calls_${container}.count"
                        n=0
                        [[ -f "${cnt_file}" ]] && n=$(cat "${cnt_file}")
                        n=$((n+1))
                        echo "${n}" > "${cnt_file}"
                        healthy_after="${HEALTHY_AFTER:-1}"
                        if (( n >= healthy_after )); then
                            echo "healthy"
                        else
                            echo "starting"
                        fi
                        exit 0
                        ;;
                    *".State.Status"*)
                        echo "${CONTAINER_STATUS:-running}"
                        exit 0
                        ;;
                    *".Config.Image"*)
                        echo "${PREV_IMAGE:-app:old}"
                        exit 0
                        ;;
                esac
                exit 0
                ;;
            exec)
                shift
                target="$1"; shift
                case "$1" in
                    sh)
                        cmdline="$*"
                        if [[ "${cmdline}" == *"command -v curl"* ]]; then
                            [[ "${HAS_CURL:-1}" == "1" ]] && exit 0 || exit 1
                        elif [[ "${cmdline}" == *"command -v wget"* ]]; then
                            [[ "${HAS_WGET:-0}" == "1" ]] && exit 0 || exit 1
                        fi
                        exit 1
                        ;;
                    curl)
                        n=0
                        [[ -f "'"${WORKDIR}"'/up_calls.count" ]] && n=$(cat "'"${WORKDIR}"'/up_calls.count")
                        if [[ "${PROBE_FAIL_FIRST_N:-0}" -gt 0 && "${n}" -le "${PROBE_FAIL_FIRST_N}" ]]; then
                            code="500"
                        else
                            code="${PROBE_HTTP_CODE:-200}"
                        fi
                        printf "%s" "${code}"
                        exit "${PROBE_CURL_EXIT:-0}"
                        ;;
                    wget)
                        exit "${PROBE_WGET_EXIT:-0}"
                        ;;
                    nginx)
                        case "$2" in
                            -t) [[ "${NGINX_T_FAIL:-0}" == "1" ]] && exit 1 || exit 0 ;;
                            -s) exit 0 ;;
                        esac
                        exit 0
                        ;;
                esac
                exit 0
                ;;
            stop)
                [[ "${DOCKER_STOP_FAIL:-0}" == "1" ]] && exit 1
                exit 0
                ;;
            rm)
                [[ "${DOCKER_RM_FAIL:-0}" == "1" ]] && exit 1
                exit 0
                ;;
        esac
        exit 0
    '
}

# Mock de `cp` que falha as primeiras N chamadas cujo TARGET (ultimo
# argumento) bate com MOCK_CP_FAIL_TARGET, e delega ao `cp` real em todo o
# resto (inclusive nas chamadas subsequentes ao mesmo target, apos as N
# falhas) — permite testar precisamente "a Nesima cp para este arquivo falha,
# a seguinte tem que funcionar" (caso de _rollout_switch_vhost restaurando o
# backup apos falhar ao aplicar a nova config). Uso: exportar
# MOCK_CP_FAIL_TARGET=<path> e opcionalmente MOCK_CP_FAIL_TIMES (default 1).
_mock_cp_fail_target() {
    local real_cp="/bin/cp"
    [[ -x "/usr/bin/cp" ]] && real_cp="/usr/bin/cp"
    # rehash: se este processo ja invocou `cp` antes (nome resolvido e
    # cacheado pelo bash), o mock recem-criado em MOCK_BIN seria ignorado —
    # o bash so re-varre o PATH se a variavel mudar, nao quando um arquivo
    # novo aparece num diretorio ja listado.
    hash -r
    mock_cmd cp '
        real_cp="'"${real_cp}"'"
        target="${@: -1}"
        if [[ -n "${MOCK_CP_FAIL_TARGET:-}" && "${target}" == "${MOCK_CP_FAIL_TARGET}" ]]; then
            cnt_file="'"${WORKDIR}"'/cp_fail.count"
            n=0
            [[ -f "${cnt_file}" ]] && n=$(cat "${cnt_file}")
            n=$((n+1))
            echo "${n}" > "${cnt_file}"
            max="${MOCK_CP_FAIL_TIMES:-1}"
            if (( n <= max )); then
                echo "cp: mock failure (chamada ${n}/${max}) para ${target}" >&2
                exit 1
            fi
        fi
        exec "${real_cp}" "$@"
    '
}

# Roda uma funcao de lib/rollout.sh (ou commands/rollout.sh) num script
# separado, com `set -euo pipefail` DE VERDADE (B5) — a suite inteira
# sourceia as libs sem esses flags no setup() acima, entao a semantica dos
# caminhos de erro que os testes normais "validam" e diferente da producao
# (cctl roda com `set -euo pipefail` desde a linha 14 do entry point). Uso:
# _run_strict <nome-da-funcao> [args...]
_run_strict() {
    local script="${WORKDIR}/_strict_runner.sh"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        printf 'CCTL_ROOT=%q\n' "${CCTL_ROOT}"
        echo 'source "${CCTL_ROOT}/lib/colors.sh"'
        echo 'source "${CCTL_ROOT}/lib/log.sh"'
        echo 'source "${CCTL_ROOT}/lib/validate.sh"'
        echo 'source "${CCTL_ROOT}/lib/core.sh"'
        echo 'source "${CCTL_ROOT}/lib/network.sh"'
        echo 'source "${CCTL_ROOT}/lib/compose.sh"'
        echo 'source "${CCTL_ROOT}/lib/nginx.sh"'
        echo 'source "${CCTL_ROOT}/lib/rollout.sh"'
        echo 'source "${CCTL_ROOT}/commands/rollout.sh"'
        printf 'COMPOSE_FILES=(%q)\n' "${COMPOSE_FILES[0]}"
        echo '"$@"'
    } > "${script}"
    chmod +x "${script}"
    run "${script}" "$@"
}

# =============================================================================
# 0. _rollout_project_network (classe B1: colisao de prefixo de nome de
#    projeto, ex. "moodle" vs "moodle-lab") — a linha usada por
#    rollout_bluegreen para decidir a que rede conectar o nginx-proxy antes
#    do switch. O mock generico _mock_docker_rollout (ver acima) ignora o
#    filtro recebido por "docker network ls" e por isso nao serve para
#    provar este caso — aqui trocamos por mock_docker_with_networks, que
#    interpreta o filtro de verdade (label exato / name ancorado / name
#    solto), o mesmo padrao ja usado em tests/down.bats.
# =============================================================================

@test "_rollout_project_network (regressao B1): projeto 'moodle' resolve a rede certa, nao a de 'moodle-lab'" {
    export COMPOSE_PROJECT_NAME="moodle"
    declare -A CCTL_TEST_NETS=(
        [moodle_network]=""
        [moodle-lab_moodle-network]=""
    )
    mock_docker_with_networks CCTL_TEST_NETS "${WORKDIR}/docker_calls.log"

    run _rollout_project_network
    assert_success
    assert_output "moodle_network"
}

@test "_rollout_project_network: com label exato do compose, resolve pelo label" {
    export COMPOSE_PROJECT_NAME="moodle"
    declare -A CCTL_TEST_NETS=( [moodle_network]="moodle" [moodle-lab_moodle-network]="moodle-lab" )
    mock_docker_with_networks CCTL_TEST_NETS "${WORKDIR}/docker_calls.log"

    run _rollout_project_network
    assert_success
    assert_output "moodle_network"
}

# =============================================================================
# 1. bluegreen feliz (live=blue)
# =============================================================================

@test "bluegreen: candidato verde sobe, fica saudavel e trafego e trocado" {
    run rollout_bluegreen --service moodle-app
    assert_success
    grep -q -- "up -d --no-deps --force-recreate moodle-app-green" "${WORKDIR}/docker.log"
}

@test "bluegreen: vhost reescreve SO o set \$target apos sucesso" {
    run rollout_bluegreen --service moodle-app
    assert_success
    grep -q 'set \$target moodle-app-green:443;' "${VHOST_FILE}"
    grep -q 'proxy_pass https://\$target;' "${VHOST_FILE}"
    grep -q 'ssl_certificate     /etc/certs/acme.pem;' "${VHOST_FILE}"
}

@test "bluegreen: chama nginx -t e reload apos o switch" {
    run rollout_bluegreen --service moodle-app
    assert_success
    grep -q "exec nginx-proxy nginx -t" "${WORKDIR}/docker.log"
    grep -q "exec nginx-proxy nginx -s reload" "${WORKDIR}/docker.log"
}

@test "bluegreen: drena o slot anterior (blue, compose stop) apos o drain" {
    run rollout_bluegreen --service moodle-app --drain 3
    assert_success
    grep -q "sleep 3" "${WORKDIR}/sleep.log"
    grep -q "compose.*stop.*moodle-app" "${WORKDIR}/docker.log"
}

@test "bluegreen: grava o arquivo de estado com o slot novo" {
    run rollout_bluegreen --service moodle-app
    assert_success
    [[ -f "${ROLLOUT_STATE_FILE}" ]]
    grep -q 'LIVE_SLOT="green"' "${ROLLOUT_STATE_FILE}"
    grep -q 'LIVE_TARGET="moodle-app-green:443"' "${ROLLOUT_STATE_FILE}"
}

# =============================================================================
# 2. Healthcheck falha => vhost intocado, candidato removido
# =============================================================================

@test "bluegreen: healthcheck falha -> vhost fica byte-identico ao original" {
    cp "${VHOST_FILE}" "${WORKDIR}/vhost.orig"
    export PROBE_HTTP_CODE=500
    run rollout_bluegreen --service moodle-app --timeout 0
    assert_failure
    cmp -s "${VHOST_FILE}" "${WORKDIR}/vhost.orig"
}

@test "bluegreen: healthcheck falha -> candidato e removido e retorna 1" {
    export PROBE_HTTP_CODE=500
    run rollout_bluegreen --service moodle-app --timeout 0
    assert_failure
    assert_output --partial "healthcheck falhou"
    grep -q "^stop testproj-moodle-app-green" "${WORKDIR}/docker.log"
    grep -q "^rm testproj-moodle-app-green" "${WORKDIR}/docker.log"
}

@test "bluegreen: healthcheck falha -> nginx -t/reload NUNCA sao chamados" {
    export PROBE_HTTP_CODE=500
    run rollout_bluegreen --service moodle-app --timeout 0
    assert_failure
    run grep -q "nginx -t" "${WORKDIR}/docker.log"
    assert_failure
}

# =============================================================================
# 3. nginx -t falha apos o switch => vhost restaurado
# =============================================================================

@test "bluegreen: nginx -t falha apos switch -> vhost e restaurado do backup" {
    cp "${VHOST_FILE}" "${WORKDIR}/vhost.orig"
    export NGINX_T_FAIL=1
    run rollout_bluegreen --service moodle-app
    assert_failure
    cmp -s "${VHOST_FILE}" "${WORKDIR}/vhost.orig"
}

@test "bluegreen: nginx -t falha apos switch -> candidato e derrubado" {
    export NGINX_T_FAIL=1
    run rollout_bluegreen --service moodle-app
    assert_failure
    grep -q "^stop testproj-moodle-app-green" "${WORKDIR}/docker.log"
    grep -q "^rm testproj-moodle-app-green" "${WORKDIR}/docker.log"
}

@test "bluegreen: nginx -t falha apos switch -> nginx -t chamado pelo menos duas vezes (teste + restauracao)" {
    export NGINX_T_FAIL=1
    run rollout_bluegreen --service moodle-app
    assert_failure
    local count
    count=$(grep -c "exec nginx-proxy nginx -t" "${WORKDIR}/docker.log")
    [[ "${count}" -ge 2 ]]
}

# =============================================================================
# 4. Modos de healthcheck
# =============================================================================

@test "bluegreen: healthcheck modo docker fica saudavel so apos N tentativas" {
    export HAS_DOCKER_HEALTHCHECK=1
    export HEALTHY_AFTER=3
    run rollout_bluegreen --service moodle-app --health-mode docker --timeout 30 --health-port 443
    assert_success
    local sleeps
    sleeps=$(grep -c "^sleep " "${WORKDIR}/sleep.log" || true)
    [[ "${sleeps}" -ge 2 ]]
}

@test "bluegreen: healthcheck modo http com 200 na sonda" {
    run rollout_bluegreen --service moodle-app --health-mode http
    assert_success
    # A sonda HTTP roda via `docker exec` no container de sonda (default: o
    # proxy nginx, "nginx-proxy" no setup) — NAO no candidato
    # ("testproj-moodle-app-green"); a asserção anterior conferia o
    # container errado (com "|| true" mascarando que nunca batia). A URL
    # sondada e que aponta pro alias do candidato.
    grep -q "^exec nginx-proxy curl" "${WORKDIR}/docker.log"
    grep -q "https://moodle-app-green:443/" "${WORKDIR}/docker.log"
}

@test "bluegreen: healthcheck http com auto-deteccao curl->wget quando curl ausente" {
    export HAS_CURL=0 HAS_WGET=1
    run rollout_bluegreen --service moodle-app --health-mode http
    assert_success
    grep -q "wget" "${WORKDIR}/docker.log"
    run grep -q " curl " "${WORKDIR}/docker.log"
    assert_failure
}

@test "bluegreen: sonda http sem curl nem wget falha com erro claro" {
    export HAS_CURL=0 HAS_WGET=0
    run rollout_bluegreen --service moodle-app --health-mode http --timeout 0
    assert_failure
    assert_output --partial "Nem curl nem wget"
}

@test "bluegreen: sonda indisponivel (sem curl/wget) aborta a espera de imediato, sem retentativas" {
    export HAS_CURL=0 HAS_WGET=0
    run rollout_bluegreen --service moodle-app --health-mode http --timeout 30
    assert_failure
    assert_output --partial "Nem curl nem wget"
    # rc=2 (sonda indisponivel) deve abortar no primeiro ciclo: nenhum sleep
    # de retentativa e a checagem de curl/wget so acontece uma vez.
    [[ ! -f "${WORKDIR}/sleep.log" ]]
    local checks
    checks="$(grep -c "command -v curl" "${WORKDIR}/docker.log")"
    [[ "${checks}" -eq 1 ]]
}

@test "bluegreen: sonda http limita --max-time ao tempo restante ate o timeout, nao ao intervalo" {
    export ROLLOUT_HEALTH_INTERVAL=10
    export PROBE_HTTP_CODE=500
    run rollout_bluegreen --service moodle-app --health-mode http --timeout 3
    assert_failure
    grep -q -- "--max-time 3 " "${WORKDIR}/docker.log"
    run grep -q -- "--max-time 10 " "${WORKDIR}/docker.log"
    assert_failure
}

# =============================================================================
# 5. Sonda com resposta nao-2xx => timeout => rollback
# =============================================================================

@test "bluegreen: sonda retorna 500 -> timeout -> rollback (trafego no slot antigo)" {
    export PROBE_HTTP_CODE=500
    run rollout_bluegreen --service moodle-app --timeout 0
    assert_failure
    grep -q 'set \$target moodle-app:443;' "${VHOST_FILE}"
    run grep -q 'set \$target moodle-app-green:443;' "${VHOST_FILE}"
    assert_failure
}

# =============================================================================
# 6. --image propaga para o servico green e para o blue (quando aplicavel)
# =============================================================================

@test "bluegreen: --image vai DENTRO do bloco moodle-app-green (nao herda do extends)" {
    # Regressao do bug real medido com 'docker compose ... config': extends
    # resolve o servico a partir do arquivo de extends.file de forma
    # independente do merge dos outros -f, entao um "image:" fora do bloco
    # "moodle-app-green:" (ex. so sob "moodle-app:") NUNCA chega ao
    # candidato green — o rollout sobe a versao ANTIGA com o healthcheck
    # passando (porque e a versao que ja estava no ar) e o state file mente
    # sobre a imagem em trafego.
    run rollout_bluegreen --service moodle-app --image ghcr.io/acme/app:v2
    assert_success
    grep -q "moodle-app-green:" "${WORKDIR}/override_snapshot.log"
    grep -q "extends:" "${WORKDIR}/override_snapshot.log"

    # awk isola o bloco "  moodle-app-green:" ate o proximo bloco top-level
    # (2 espacos de indentacao) ou EOF — só aí procura a linha "image:".
    awk '/^  moodle-app-green:$/{f=1; next} /^  [A-Za-z0-9._-]+:$/{f=0} f' \
        "${WORKDIR}/override_snapshot.log" | grep -q "    image: ghcr.io/acme/app:v2"
}

@test "bluegreen: --image NAO aparece fora do bloco moodle-app-green (bloco base do servico nao e reescrito)" {
    run rollout_bluegreen --service moodle-app --image ghcr.io/acme/app:v2
    assert_success

    run bash -c "awk '/^  moodle-app:\$/{f=1; next} /^  [A-Za-z0-9._-]+:\$/{f=0} f' '${WORKDIR}/override_snapshot.log' | grep -q image:"
    assert_failure
}

@test "rolling: --image propaga para o servico base (candidato e sempre blue)" {
    run rollout_rolling --service moodle-app --image ghcr.io/acme/app:v3
    assert_success
    grep -A1 "^  moodle-app:" "${WORKDIR}/override_snapshot.log" | grep -q "image: ghcr.io/acme/app:v3"
    run grep -q "moodle-app-green:" "${WORKDIR}/override_snapshot.log"
    assert_failure
}

# =============================================================================
# 6b. extends.file do override e SEMPRE o basename do arquivo que define o
#     servico (Docker Compose resolve extends.file relativo ao diretorio do
#     PROPRIO override, nao ao CWD) — bug real encontrado na VM de lab.
# =============================================================================

@test "bluegreen: extends.file do override e o basename, nunca um caminho com barra" {
    mkdir -p "${WORKDIR}/docker"
    cat > "${WORKDIR}/docker/docker-compose.yaml" <<'EOF'
services:
  moodle-app:
    image: base
EOF
    COMPOSE_FILES=("docker/docker-compose.yaml")

    run rollout_bluegreen --service moodle-app
    assert_success
    grep -q "file: docker-compose.yaml" "${WORKDIR}/override_snapshot.log"
    # nenhuma linha "file: ..." deve conter uma barra (caminho relativo)
    run grep -E "file: .*/" "${WORKDIR}/override_snapshot.log"
    assert_failure
}

@test "bluegreen: extends.file aponta para o SEGUNDO arquivo de COMPOSE_FILES quando e ele que define o servico (caso dspace)" {
    mkdir -p "${WORKDIR}/docker"
    cat > "${WORKDIR}/docker/docker-compose.yaml" <<'EOF'
services:
  db:
    image: postgres
EOF
    cat > "${WORKDIR}/docker/docker-compose.frontend.yaml" <<'EOF'
services:
  moodle-app:
    image: base
EOF
    COMPOSE_FILES=("docker/docker-compose.yaml" "docker/docker-compose.frontend.yaml")

    run rollout_bluegreen --service moodle-app
    assert_success
    grep -q "file: docker-compose.frontend.yaml" "${WORKDIR}/override_snapshot.log"
    run grep -q "file: docker-compose.yaml$" "${WORKDIR}/override_snapshot.log"
    assert_failure
}

# =============================================================================
# 7. Alternancia: LIVE_SLOT=green -> candidato e o slot blue
# =============================================================================

@test "bluegreen: com estado LIVE_SLOT=green, candidato e o slot blue e vhost volta ao alias base" {
    _write_vhost "moodle-app-green" "443" "https"
    _write_state "moodle-app" "green"

    run rollout_bluegreen --service moodle-app
    assert_success
    grep -q -- "up -d --no-deps --force-recreate moodle-app" "${WORKDIR}/docker.log"
    grep -q 'set \$target moodle-app:443;' "${VHOST_FILE}"
    grep -q 'LIVE_SLOT="blue"' "${ROLLOUT_STATE_FILE}"
}

# =============================================================================
# 8. --timeout/--drain/--health-path/--health-port aplicados; invalidos rejeitados
# =============================================================================

@test "bluegreen: --health-path e --health-port customizados chegam na URL da sonda" {
    run rollout_bluegreen --service moodle-app --health-path /healthz --health-port 8443
    assert_success
    grep -q "https://moodle-app-green:8443/healthz" "${WORKDIR}/docker.log"
}

@test "bluegreen: state grava a porta do vhost (nao a porta da sonda) quando --health-port diverge" {
    run rollout_bluegreen --service moodle-app --health-port 8443
    assert_success
    grep -q 'LIVE_TARGET="moodle-app-green:443"' "${ROLLOUT_STATE_FILE}"
    run grep -q "8443" "${ROLLOUT_STATE_FILE}"
    assert_failure
}

@test "bluegreen: --timeout invalido (nao-inteiro) e rejeitado" {
    run rollout_bluegreen --service moodle-app --timeout abc
    assert_failure
    assert_output --partial "timeout invalido"
}

@test "bluegreen: --timeout invalido (negativo) e rejeitado" {
    run rollout_bluegreen --service moodle-app --timeout -5
    assert_failure
    assert_output --partial "timeout invalido"
}

@test "bluegreen: --drain invalido (negativo) e rejeitado" {
    run rollout_bluegreen --service moodle-app --drain -1
    assert_failure
    assert_output --partial "drain invalido"
}

@test "bluegreen: --health-port invalido (nao-inteiro) e rejeitado" {
    run rollout_bluegreen --service moodle-app --health-port abc
    assert_failure
    assert_output --partial "health-port invalido"
}

@test "bluegreen: --drain aplicado literalmente no sleep do dreno" {
    run rollout_bluegreen --service moodle-app --drain 7
    assert_success
    grep -q "^sleep 7$" "${WORKDIR}/sleep.log"
}

# =============================================================================
# 9. Servico inexistente
# =============================================================================

@test "bluegreen: servico inexistente falha com erro claro sem subir candidato" {
    export COMPOSE_SERVICES="outro-servico"
    run rollout_bluegreen --service moodle-app
    assert_failure
    assert_output --partial "nao existe no compose"
    assert_output --partial "outro-servico"
    run grep -q -- "up -d --no-deps" "${WORKDIR}/docker.log"
    assert_failure
}

# =============================================================================
# 10. Proxy ausente
# =============================================================================

@test "bluegreen: proxy ausente orienta 'cctl proxy up' e nao chama compose" {
    export CONTAINERS_EXIST="testproj-moodle-app testproj-moodle-app-green"
    run rollout_bluegreen --service moodle-app
    assert_failure
    assert_output --partial "cctl proxy up"
    # Assercao real (a anterior era vacua: "[[ ... ]] || run ..." nunca
    # reprova o teste porque `run` so registra status/output, nao falha o
    # teste sozinho) — se docker.log existir, nenhuma linha de "up -d
    # --no-deps" pode estar nele.
    if [[ -f "${WORKDIR}/docker.log" ]]; then
        run grep -q -- "up -d --no-deps" "${WORKDIR}/docker.log"
        assert_failure
    fi
}

# =============================================================================
# 11. --keep-old nao drena
# =============================================================================

@test "bluegreen: --keep-old mantem o slot anterior no ar (sem stop)" {
    run rollout_bluegreen --service moodle-app --keep-old
    assert_success
    assert_output --partial "mantido"
    run grep -q -- "compose.*stop.*moodle-app" "${WORKDIR}/docker.log"
    assert_failure
}

# =============================================================================
# 12. rolling sucesso / rollback
# =============================================================================

@test "rolling: sucesso recria o mesmo alias sem trocar trafego" {
    run rollout_rolling --service moodle-app --image ghcr.io/acme/app:v4
    assert_success
    grep -q -- "up -d --no-deps --force-recreate moodle-app" "${WORKDIR}/docker.log"
}

@test "N5 (revisao Sprint 5, rodada 3): rolling sem --image nao apaga a imagem ja registrada no state file" {
    _write_state "moodle-app" "blue"
    sed -i 's/^IMAGE=.*/IMAGE="ghcr.io\/acme\/app:v3"/' "${ROLLOUT_STATE_FILE}"

    run rollout_rolling --service moodle-app
    assert_success

    grep -q 'IMAGE="ghcr.io/acme/app:v3"' "${ROLLOUT_STATE_FILE}"
}

@test "rolling: healthcheck falha -> recria com imagem anterior e reporta ROLLBACK EXECUTADO" {
    export PROBE_FAIL_FIRST_N=1
    run rollout_rolling --service moodle-app --image ghcr.io/acme/app:bad --timeout 0
    assert_failure
    assert_output --partial "ROLLBACK EXECUTADO"
    assert_output --partial "app:old"

    local first_up second_up
    first_up=$(grep -n -- "up -d --no-deps --force-recreate moodle-app" "${WORKDIR}/docker.log" | sed -n '1p' | cut -d: -f1)
    second_up=$(grep -n -- "up -d --no-deps --force-recreate moodle-app" "${WORKDIR}/docker.log" | sed -n '2p' | cut -d: -f1)
    [[ -n "${first_up}" && -n "${second_up}" && "${first_up}" -lt "${second_up}" ]]
}

@test "rolling: sem imagem anterior determinavel, rollback e abortado com erro claro" {
    export CONTAINERS_EXIST="nginx-proxy"
    export PROBE_HTTP_CODE=500
    run rollout_rolling --service moodle-app --timeout 0
    assert_failure
    assert_output --partial "rollback abortado"
}

# =============================================================================
# 12b. O1 (revisao Sprint 5): 'rolling' recusa quando o slot live e green
# =============================================================================
#
# Bug real encontrado pelo revisor: 'rolling' gravava LIVE_SLOT="blue" as
# cegas, ignorando o slot live de verdade. Sequencia que quebrava:
# `bluegreen` (trafego -> green) -> `rolling` (recria o slot BASE, que nao
# esta em trafego — no-op silencioso — e ainda por cima mente no state file)
# -> `bluegreen` seguinte morre em "Nao foi possivel determinar o alvo atual
# do vhost" porque o vhost so tem "set $target <svc>-green:". Semantica
# escolhida: 'rolling' recusa com erro claro quando o slot live e green, sem
# recriar nada e sem tocar no state file — o operador deve rodar 'bluegreen'
# (que alterna os slots) antes de usar 'rolling' de novo.

@test "rolling: recusa quando o slot live (via state file) e green — nada e recriado" {
    _write_vhost "moodle-app-green" "443" "https"
    _write_state "moodle-app" "green"
    local before after
    before="$(cat "${ROLLOUT_STATE_FILE}")"

    run rollout_rolling --service moodle-app --image ghcr.io/acme/app:v5
    assert_failure
    assert_output --partial "bluegreen"

    run grep -q -- "up -d --no-deps --force-recreate moodle-app" "${WORKDIR}/docker.log"
    assert_failure

    after="$(cat "${ROLLOUT_STATE_FILE}")"
    [[ "${before}" == "${after}" ]]
}

@test "rolling: recusa quando o slot live (via inferencia do vhost, sem state file) e green" {
    _write_vhost "moodle-app-green" "443" "https"
    [[ ! -f "${ROLLOUT_STATE_FILE}" ]]

    run rollout_rolling --service moodle-app
    assert_failure
    assert_output --partial "bluegreen"
    [[ ! -f "${ROLLOUT_STATE_FILE}" ]]
}

@test "sequencia bluegreen -> rolling -> bluegreen a partir de LIVE_SLOT=green nao termina em erro e o state file fica coerente a cada passo" {
    _write_vhost "moodle-app-green" "443" "https"
    _write_state "moodle-app" "green"

    run rollout_bluegreen --service moodle-app
    assert_success
    grep -q 'LIVE_SLOT="blue"' "${ROLLOUT_STATE_FILE}"

    run rollout_rolling --service moodle-app --image ghcr.io/acme/app:v6
    assert_success
    grep -q 'LIVE_SLOT="blue"' "${ROLLOUT_STATE_FILE}"

    run rollout_bluegreen --service moodle-app --image ghcr.io/acme/app:v7
    assert_success
    grep -q 'LIVE_SLOT="green"' "${ROLLOUT_STATE_FILE}"
}

# =============================================================================
# 13. rollout status / usage / acao desconhecida
# =============================================================================

@test "rollout status: com arquivo de estado, mostra slot live e imagem" {
    _write_state "moodle-app" "green"
    export ROLLOUT_SERVICE="moodle-app"
    run rollout_status
    assert_success
    assert_output --partial "Slot live:"
    assert_output --partial "green"
}

@test "rollout status: sem arquivo de estado, avisa mas nao falha" {
    export ROLLOUT_SERVICE="moodle-app"
    run rollout_status
    assert_success
    assert_output --partial "nao encontrado"
}

@test "rollout status: sem ROLLOUT_SERVICE e sem estado, avisa e retorna 0" {
    run rollout_status
    assert_success
    assert_output --partial "Servico alvo desconhecido"
}

@test "N3 (revisao Sprint 5, rodada 3): status com --service B e state file gravado por A nao mistura os campos de A na saida de B" {
    # Bug: 'st_service' so preenchia 'service' quando vazio — nunca invalidava
    # os campos ja lidos do state file. Com --service B e um .cctl-rollout de
    # A, o comando imprimia "Servico: B" ao lado de Slot/Alvo/Imagem/Ultimo
    # rollout DE A, induzindo o operador a erro.
    _write_state "servico-a" "green"
    # sed direto no state para uma imagem reconhecivel de A (evita colidir
    # com qualquer imagem usada em outro teste).
    sed -i 's/^IMAGE=.*/IMAGE="ghcr.io\/acme\/a:v1"/' "${ROLLOUT_STATE_FILE}"
    export CONTAINERS_EXIST="nginx-proxy testproj-moodle-app"

    run rollout_status --service moodle-app
    assert_success
    assert_output --partial "Servico:"
    assert_output --partial "moodle-app"
    assert_output --partial "pertence ao servico"
    assert_output --partial "servico-a"
    refute_output --partial "ghcr.io/acme/a:v1"
}

@test "rollout status: state file aponta para slot cujo container nao existe -> reporta o slot gravado e avisa que o container sumiu" {
    # 'rollout status' e diagnostico: exibe o que o state file registrou
    # (nao reinfere a partir do vhost como _rollout_resolve_live_slot faz
    # para bluegreen/rolling — ver teste dedicado abaixo). Quando o container
    # do slot gravado nao existe mais, o comando nao pode travar nem mentir
    # silenciosamente — tem que mostrar o slot registrado E avisar que o
    # container sumiu.
    _write_state "moodle-app" "green"
    export CONTAINERS_EXIST="nginx-proxy testproj-moodle-app"
    export ROLLOUT_SERVICE="moodle-app"

    run rollout_status
    assert_success
    assert_output --partial "Slot live:"
    assert_output --partial "green"
    assert_output --partial "Container testproj-moodle-app-green nao encontrado"
}

@test "_rollout_resolve_live_slot: state file com container inexistente ignora o state e usa o vhost" {
    _write_state "moodle-app" "green"
    export CONTAINERS_EXIST="nginx-proxy testproj-moodle-app"

    local resolved
    resolved="$(_rollout_resolve_live_slot "moodle-app")"
    [[ "${resolved}" == "blue" ]]
}

# =============================================================================
# N1/N2 (revisao Sprint 5, rodada 3): discordancia state file x vhost — o
# vhost e a fonte da verdade sobre o TRAFEGO. Cenario: o switch do bluegreen
# ja aconteceu (vhost aponta para o slot novo) mas o state file ficou velho
# (gravacao falhou, restauracao de backup, copia manual) e ainda diz o slot
# antigo, cujo container continua existindo (--keep-old/dreno falho).
# =============================================================================

@test "_rollout_resolve_live_slot: state file diz blue mas vhost diz green -> vhost manda, devolve green" {
    _write_vhost "moodle-app-green" "443" "https"
    _write_state "moodle-app" "blue"
    # Os dois containers (blue e green) existem — se o state file vencesse
    # (bug do N1), o container do slot blue existir seria o suficiente para
    # a resolucao antiga aceitar "blue" as cegas.
    export CONTAINERS_EXIST="nginx-proxy testproj-moodle-app testproj-moodle-app-green"

    local resolved
    resolved="$(_rollout_resolve_live_slot "moodle-app")"
    [[ "${resolved}" == "green" ]]
}

@test "rolling: state file diz blue mas vhost diz green -> recusa, nada e recriado e o state file nao muda" {
    _write_vhost "moodle-app-green" "443" "https"
    _write_state "moodle-app" "blue"
    export CONTAINERS_EXIST="nginx-proxy testproj-moodle-app testproj-moodle-app-green"
    local before after
    before="$(cat "${ROLLOUT_STATE_FILE}")"

    run rollout_rolling --service moodle-app --image ghcr.io/acme/app:v9
    assert_failure
    assert_output --partial "bluegreen"

    run grep -q -- "up -d --no-deps --force-recreate moodle-app" "${WORKDIR}/docker.log"
    assert_failure

    after="$(cat "${ROLLOUT_STATE_FILE}")"
    [[ "${before}" == "${after}" ]]
}

@test "bluegreen: apos discordancia state x vhost, o bluegreen seguinte funciona (nao cai em 'alvo atual do vhost')" {
    _write_vhost "moodle-app-green" "443" "https"
    _write_state "moodle-app" "blue"
    export CONTAINERS_EXIST="nginx-proxy testproj-moodle-app testproj-moodle-app-green"

    run rollout_bluegreen --service moodle-app
    assert_success
    refute_output --partial "Nao foi possivel determinar o alvo atual do vhost"
    grep -q 'set \$target moodle-app:443;' "${VHOST_FILE}"
    grep -q 'LIVE_SLOT="blue"' "${ROLLOUT_STATE_FILE}"
}

@test "cmd_rollout: sem acao exibe uso e nao falha" {
    run cmd_rollout
    assert_success
    assert_output --partial "cctl rollout <bluegreen|rolling|status|help>"
}

@test "cmd_rollout: acao desconhecida falha com uso" {
    run cmd_rollout xyz
    assert_failure
    assert_output --partial "Acao desconhecida"
    assert_output --partial "cctl rollout"
}

@test "cmd_rollout: 'help' exibe uso e sucesso" {
    run cmd_rollout help
    assert_success
    assert_output --partial "cctl rollout"
}

@test "cmd_rollout: despacha 'bluegreen' corretamente" {
    run cmd_rollout bluegreen --service moodle-app
    assert_success
}

@test "cmd_rollout: despacha 'status' corretamente" {
    export ROLLOUT_SERVICE="moodle-app"
    run cmd_rollout status
    assert_success
    assert_output --partial "Status do rollout"
}

@test "cmd_rollout: 'status --service' repassa a flag em vez de descartar em silencio (O9)" {
    # Bug do revisor: 'status)  rollout_status ;;' descartava "$@" em
    # silencio — 'cctl rollout status --service x' ignorava a flag e caia no
    # ROLLOUT_SERVICE do ambiente/manifest. Agora --service e repassado e tem
    # precedencia.
    _write_state "outro-servico" "blue"
    export ROLLOUT_SERVICE="moodle-app"
    run cmd_rollout status --service outro-servico
    assert_success
    assert_output --partial "outro-servico"
}

@test "cmd_rollout: 'status' com flag desconhecida falha (nao ignora em silencio)" {
    run cmd_rollout status --bogus
    assert_failure
    assert_output --partial "invalido"
}

@test "rollout_status --service: sem valor falha com erro claro" {
    run rollout_status --service
    assert_failure
    assert_output --partial "requer um valor"
}

# =============================================================================
# 14. Override sempre removido, mesmo em caminho de erro
# =============================================================================

@test "bluegreen: override e removido apos sucesso" {
    run rollout_bluegreen --service moodle-app --image ghcr.io/acme/app:v2
    assert_success
    [[ ! -f "${WORKDIR}/docker-compose.rollout.yaml" ]]
}

@test "bluegreen: override e removido mesmo com healthcheck falhando" {
    export PROBE_HTTP_CODE=500
    run rollout_bluegreen --service moodle-app --image ghcr.io/acme/app:v2 --timeout 0
    assert_failure
    [[ ! -f "${WORKDIR}/docker-compose.rollout.yaml" ]]
}

@test "bluegreen: override e removido mesmo com nginx -t falhando no switch" {
    export NGINX_T_FAIL=1
    run rollout_bluegreen --service moodle-app --image ghcr.io/acme/app:v2
    assert_failure
    [[ ! -f "${WORKDIR}/docker-compose.rollout.yaml" ]]
}

@test "rolling: override e removido apos o rollback" {
    export PROBE_FAIL_FIRST_N=1
    run rollout_rolling --service moodle-app --image ghcr.io/acme/app:bad --timeout 0
    assert_failure
    [[ ! -f "${WORKDIR}/docker-compose.rollout.yaml" ]]
}

# =============================================================================
# 15. Ordem: vhost so e tocado depois do healthcheck passar
# =============================================================================

@test "bluegreen: vhost so e alterado apos o healthcheck ter passado (ordem das operacoes)" {
    run rollout_bluegreen --service moodle-app
    assert_success

    local curl_line nginx_t_line
    curl_line=$(grep -n "curl" "${WORKDIR}/docker.log" | head -1 | cut -d: -f1)
    nginx_t_line=$(grep -n "exec nginx-proxy nginx -t" "${WORKDIR}/docker.log" | head -1 | cut -d: -f1)

    [[ -n "${curl_line}" && -n "${nginx_t_line}" ]]
    [[ "${curl_line}" -lt "${nginx_t_line}" ]]
}

@test "bluegreen: candidato sobe ANTES de qualquer chamada de healthcheck" {
    run rollout_bluegreen --service moodle-app
    assert_success

    local up_line curl_line
    up_line=$(grep -n -- "up -d --no-deps --force-recreate moodle-app-green" "${WORKDIR}/docker.log" | head -1 | cut -d: -f1)
    curl_line=$(grep -n "curl" "${WORKDIR}/docker.log" | head -1 | cut -d: -f1)

    [[ -n "${up_line}" && -n "${curl_line}" ]]
    [[ "${up_line}" -lt "${curl_line}" ]]
}

# =============================================================================
# 16. B2 — green orfao preexistente e sempre recriado (--force-recreate)
# =============================================================================

@test "bluegreen: candidato green preexistente (orfao) e recriado, nao apenas adotado" {
    # Simula um green deixado para tras por um rollout anterior (--keep-old,
    # ou um _rollout_discard_candidate que falhou silenciosamente): o
    # container ja existe ANTES desta chamada. Sem --force-recreate,
    # `docker compose up -d` reaproveitaria esse container como se fosse a
    # versao nova (o mock nao modela reuso real de container, mas a flag na
    # linha de comando e o unico jeito de garantir a recriacao de verdade).
    export CONTAINERS_EXIST="nginx-proxy testproj-moodle-app testproj-moodle-app-green"
    run rollout_bluegreen --service moodle-app --image ghcr.io/acme/app:v9
    assert_success
    grep -q -- "up -d --no-deps --force-recreate moodle-app-green" "${WORKDIR}/docker.log"
}

# =============================================================================
# 17. B3 — falha ao aplicar o vhost restaura o backup em vez de descarta-lo
# =============================================================================

@test "bluegreen: falha ao aplicar a nova config no vhost restaura o backup (nao descarta sem recuperar)" {
    cp "${VHOST_FILE}" "${WORKDIR}/vhost.orig"
    _mock_cp_fail_target
    export MOCK_CP_FAIL_TARGET="${VHOST_FILE}"
    export MOCK_CP_FAIL_TIMES=1

    run rollout_bluegreen --service moodle-app
    assert_failure
    assert_output --partial "restaurando backup"

    # O vhost tem que estar EXATAMENTE como antes (restaurado do backup),
    # nao truncado/vazio (o efeito do `cp` que falha no meio da escrita) nem
    # com a nova config aplicada pela metade.
    cmp -s "${VHOST_FILE}" "${WORKDIR}/vhost.orig"
}

@test "bluegreen: falha ao aplicar a nova config no vhost -> candidato e descartado e rc=1" {
    _mock_cp_fail_target
    export MOCK_CP_FAIL_TARGET="${VHOST_FILE}"
    export MOCK_CP_FAIL_TIMES=1

    run rollout_bluegreen --service moodle-app
    assert_failure
    grep -q "^stop testproj-moodle-app-green" "${WORKDIR}/docker.log"
    grep -q "^rm testproj-moodle-app-green" "${WORKDIR}/docker.log"
}

# =============================================================================
# 18. B5 — caminhos de erro sob `set -euo pipefail` real de producao
# =============================================================================
#
# A suite inteira sourceia lib/rollout.sh SEM `set -euo pipefail` (ver
# _run_strict acima) — os testes desta secao rodam com os flags de
# producao ligados de verdade, provando que os `|| true` adicionados na
# auditoria B5 realmente evitam o shell morrer silenciosamente antes de
# qualquer mensagem/limpeza.
#
# NAO "simplifique" estes testes trocando `_run_strict` por `run`: o bats
# roda o corpo do @test com suas proprias flags (`-E`/`-T` do bats-core),
# que tem semantica de trap DIFERENTE da do entry point `cctl` (`set -euo
# pipefail` de verdade, sem as extensoes do bats). `_run_strict` e o unico
# jeito de provar a semantica real de producao — com `run` estes testes
# passariam mesmo com o `|| true` de B5 removido, sem detectar a regressao.

@test "[set -e real] rolling: container inexistente nao mata o shell — erro claro e rc!=0" {
    export CONTAINERS_EXIST="nginx-proxy"
    export PROBE_HTTP_CODE=500
    _run_strict rollout_rolling --service moodle-app --timeout 0
    assert_failure
    assert_output --partial "rollback abortado"
}

@test "[set -e real] bluegreen: docker stop falha no descarte do candidato -> override removido, erro tratado" {
    export PROBE_HTTP_CODE=500
    export DOCKER_STOP_FAIL=1
    _run_strict rollout_bluegreen --service moodle-app --image ghcr.io/acme/app:v2 --timeout 0
    assert_failure
    assert_output --partial "healthcheck falhou"
    [[ ! -f "${WORKDIR}/docker-compose.rollout.yaml" ]]
}

@test "[set -e real] bluegreen: docker rm falha no descarte do candidato -> override removido, erro tratado" {
    export PROBE_HTTP_CODE=500
    export DOCKER_RM_FAIL=1
    _run_strict rollout_bluegreen --service moodle-app --image ghcr.io/acme/app:v2 --timeout 0
    assert_failure
    assert_output --partial "healthcheck falhou"
    grep -q "^rm testproj-moodle-app-green" "${WORKDIR}/docker.log"
    [[ ! -f "${WORKDIR}/docker-compose.rollout.yaml" ]]
}

@test "[set -e real] rollout status: state file sem LIVE_SLOT nao mata o shell — avisa e continua" {
    cat > "${ROLLOUT_STATE_FILE}" <<EOF
SERVICE="moodle-app"
IMAGE="ghcr.io/acme/app:v1"
UPDATED_AT="2026-09-01T00:00:00-03:00"
EOF
    export ROLLOUT_SERVICE="moodle-app"
    _run_strict rollout_status
    assert_success
    assert_output --partial "Slot live:"
}

@test "[set -e real] bluegreen: fluxo feliz completo continua funcionando com os flags de producao ligados" {
    _run_strict rollout_bluegreen --service moodle-app
    assert_success
    grep -q 'LIVE_SLOT="green"' "${ROLLOUT_STATE_FILE}"
}

# =============================================================================
# 19. B6 — estado gravado ANTES do dreno (dreno tolerante a falha)
# =============================================================================

@test "bluegreen: estado ja reflete o slot novo mesmo quando o dreno do slot anterior falha" {
    export MOCK_COMPOSE_STOP_FAIL=1
    run rollout_bluegreen --service moodle-app
    assert_success
    assert_output --partial "nao concluido"
    grep -q 'LIVE_SLOT="green"' "${ROLLOUT_STATE_FILE}"
}

@test "bluegreen: ordem das operacoes e switch -> estado -> dreno" {
    # Prova de verdade (nao so a existencia de cada evento, mas a ORDEM
    # relativa entre eles): unifica switch/gravacao-de-estado/dreno num unico
    # log sequencial. O switch ja loga em docker.log (via "nginx -s reload");
    # aqui remockamos `date` (so a chamada com -Iseconds, feita por
    # _rollout_write_state) e `sleep` (a chamada do dreno) para tambem
    # anotarem sua posicao no MESMO arquivo, preservando o comportamento real
    # (`date` continua executando o binario real; `sleep` continua sem
    # dormir de verdade). Sem isso, comparar numeros de linha de arquivos
    # DIFERENTES (docker.log vs sleep.log) nao prova ordem alguma.
    local real_date
    real_date="$(command -v date)"
    mock_cmd date '
        if [[ "$1" == "-Iseconds" ]]; then
            echo "STATE_WRITE_MARKER" >> "'"${WORKDIR}"'/docker.log"
        fi
        exec "'"${real_date}"'" "$@"
    '
    mock_cmd sleep '
        echo "sleep $*" >> "'"${WORKDIR}"'/docker.log"
        echo "sleep $*" >> "'"${WORKDIR}"'/sleep.log"
        exit 0
    '

    run rollout_bluegreen --service moodle-app --drain 3
    assert_success

    local switch_line state_write_line drain_sleep_line
    switch_line=$(grep -n "exec nginx-proxy nginx -s reload" "${WORKDIR}/docker.log" | head -1 | cut -d: -f1)
    state_write_line=$(grep -n "^STATE_WRITE_MARKER$" "${WORKDIR}/docker.log" | head -1 | cut -d: -f1)
    drain_sleep_line=$(grep -n "^sleep 3$" "${WORKDIR}/docker.log" | head -1 | cut -d: -f1)

    [[ -n "${switch_line}" && -n "${state_write_line}" && -n "${drain_sleep_line}" ]]
    grep -q 'LIVE_SLOT="green"' "${ROLLOUT_STATE_FILE}"
    # A prova real: as tres posicoes no MESMO log, na ordem esperada.
    (( switch_line < state_write_line ))
    (( state_write_line < drain_sleep_line ))
}

# =============================================================================
# 20. Observacoes nao-bloqueantes (3, 4, 5, 6)
# =============================================================================

@test "obs3: rolling em modo http sem vhost e sem --health-port falha cedo com erro claro" {
    rm -f "${VHOST_FILE}"
    run rollout_rolling --service moodle-app --health-mode http
    assert_failure
    assert_output --partial "requer uma porta"
    # Falha ANTES de recriar o servico — nao gasta um up+timeout inteiro.
    run grep -q -- "up -d --no-deps" "${WORKDIR}/docker.log"
    assert_failure
}

@test "obs4: ROLLOUT_HEALTH_INTERVAL=0 e rejeitado com erro claro" {
    export ROLLOUT_HEALTH_INTERVAL=0
    run rollout_bluegreen --service moodle-app
    assert_failure
    assert_output --partial "ROLLOUT_HEALTH_INTERVAL invalido"
}

@test "obs4: ROLLOUT_HEALTH_INTERVAL nao-numerico e rejeitado com erro claro" {
    export ROLLOUT_HEALTH_INTERVAL="abc"
    run rollout_bluegreen --service moodle-app
    assert_failure
    assert_output --partial "ROLLOUT_HEALTH_INTERVAL invalido"
}

@test "obs5: modo docker com candidato 'exited' falha rapido, sem esperar o timeout inteiro" {
    export HAS_DOCKER_HEALTHCHECK=1
    export CONTAINER_STATUS="exited"
    export HEALTHY_AFTER=999
    run rollout_bluegreen --service moodle-app --health-mode docker --timeout 30
    assert_failure
    assert_output --partial "esta em estado 'exited'"
    # Sem a checagem de estado morto, o loop teria dormido ate estourar os
    # 30s de timeout (varios sleeps); com a checagem, aborta de imediato.
    [[ ! -f "${WORKDIR}/sleep.log" ]]
}

@test "obs6: --image com quebra de linha/YAML arbitrario e rejeitado" {
    run rollout_bluegreen --service moodle-app --image $'x\n    privileged: true'
    assert_failure
    assert_output --partial "Referencia de imagem invalida"
}

@test "obs6: --image com espaco e rejeitado" {
    run rollout_bluegreen --service moodle-app --image "app image:v2"
    assert_failure
    assert_output --partial "Referencia de imagem invalida"
}

@test "obs6: --health-path sem barra inicial e rejeitado" {
    run rollout_bluegreen --service moodle-app --health-path "healthz"
    assert_failure
    assert_output --partial "health-path invalido"
}

@test "obs6: --health-path com espaco/quebra de linha e rejeitado" {
    run rollout_bluegreen --service moodle-app --health-path $'/health\nz'
    assert_failure
    assert_output --partial "health-path invalido"
}

# =============================================================================
# Extras: flags globais / uso sintetico
# =============================================================================

@test "bluegreen: flag desconhecida retorna erro com uso sintetico" {
    run rollout_bluegreen --service moodle-app --flag-invalida
    assert_failure
    assert_output --partial "Uso: cctl rollout"
}

@test "bluegreen: --health-mode invalido e rejeitado" {
    run rollout_bluegreen --service moodle-app --health-mode invalido
    assert_failure
    assert_output --partial "health-mode invalido"
}

@test "rolling: --drain nao e suportado (flag exclusiva do bluegreen)" {
    run rollout_rolling --service moodle-app --drain 5
    assert_failure
    assert_output --partial "nao suportada em 'rollout rolling'"
}

@test "rolling: --keep-old nao e suportado (flag exclusiva do bluegreen)" {
    run rollout_rolling --service moodle-app --keep-old
    assert_failure
    assert_output --partial "nao suportada em 'rollout rolling'"
}

@test "bluegreen: servico alvo ausente (sem --service e sem ROLLOUT_SERVICE) falha com erro claro" {
    run rollout_bluegreen
    assert_failure
    assert_output --partial "Servico alvo do rollout nao definido"
}

@test "bluegreen: usa ROLLOUT_SERVICE do manifest quando --service nao e passado" {
    export ROLLOUT_SERVICE="moodle-app"
    run rollout_bluegreen
    assert_success
}

@test "bluegreen: --service explicito tem precedencia sobre ROLLOUT_SERVICE" {
    export ROLLOUT_SERVICE="outro-servico"
    export COMPOSE_SERVICES="moodle-app outro-servico"
    run rollout_bluegreen --service moodle-app
    assert_success
    grep -q -- "up -d --no-deps --force-recreate moodle-app-green" "${WORKDIR}/docker.log"
}

# =============================================================================
# 21. cleanup do override via `trap ... RETURN` (achado no E2E real da VM)
# =============================================================================
#
# Fato observado na VM de lab (docker/compose reais): um rollout BEM-SUCEDIDO
# retornava rc=1. Causa confirmada: o `trap ... RETURN` dispara no retorno da
# funcao de rollout, quando os `local` do corpo JA sairam de escopo; o
# cleanup lia um `local` (`${override_file}`) nesse momento e, sob `set -u`
# (producao), isso virava "unbound variable" — o proprio retorno da funcao
# terminava com rc=1 mesmo com o trafego ja trocado com sucesso.
# Por que o override ainda aparecia removido na tela apesar do erro nao foi
# instrumentado/confirmado — tratamos como hipotese em aberto, nao fato: NAO
# afirmamos aqui uma segunda mecanica de disparo do trap (nao ha `functrace`/
# `set -T` neste codigo; sem isso um `trap ... RETURN` dispara uma unica vez,
# no retorno da funcao — uma segunda mecanica de disparo teria que ser
# comprovada, nao presumida). Achado so no E2E com docker/compose de verdade
# na VM: a suite com mocks nao reproduz esse timing de escopo do bash, e o
# teste estrito de fluxo feliz existente passava com o defeito presente.
#
# Estes testes travam o INVARIANTE que elimina a dependencia: o cleanup le
# sempre o global _ROLLOUT_OVERRIDE_TMP, de qualquer frame.

@test "cleanup do override: remove o arquivo a partir de frame sem os local do rollout" {
    local alvo="${WORKDIR}/alvo-cleanup.yaml"
    echo "services: {}" > "${alvo}"

    # Shell novo, sem nenhum `local` de rollout em escopo — exatamente a
    # situacao do `trap ... RETURN` no retorno de rollout_bluegreen.
    run bash -c "
        set -euo pipefail
        source '${CCTL_ROOT}/lib/colors.sh'
        source '${CCTL_ROOT}/lib/log.sh'
        source '${CCTL_ROOT}/lib/rollout.sh'
        _ROLLOUT_OVERRIDE_TMP='${alvo}'
        _rollout_cleanup_override
        printf 'global=%s\n' \"\${_ROLLOUT_OVERRIDE_TMP}\"
    "

    assert_success
    refute_output --partial "unbound variable"
    assert_output --partial "global="
    [[ ! -f "${alvo}" ]]
}

@test "cleanup do override: e idempotente (segunda chamada nao falha nem recria nada)" {
    local alvo="${WORKDIR}/alvo-cleanup2.yaml"
    echo "services: {}" > "${alvo}"

    run bash -c "
        set -euo pipefail
        source '${CCTL_ROOT}/lib/colors.sh'
        source '${CCTL_ROOT}/lib/log.sh'
        source '${CCTL_ROOT}/lib/rollout.sh'
        _ROLLOUT_OVERRIDE_TMP='${alvo}'
        _rollout_cleanup_override
        _rollout_cleanup_override
        [[ ! -f '${alvo}' ]]
    "

    assert_success
    refute_output --partial "unbound variable"
}

@test "[set -e real] bluegreen: fluxo feliz retorna 0 e nao deixa override residual" {
    _run_strict rollout_bluegreen --service moodle-app --image ghcr.io/acme/app:v2

    assert_success
    refute_output --partial "unbound variable"
    grep -q 'LIVE_SLOT="green"' "${ROLLOUT_STATE_FILE}"
    [[ ! -f "${WORKDIR}/docker-compose.rollout.yaml" ]]
}

@test "[set -e real] rolling: fluxo feliz retorna 0 e nao deixa override residual" {
    _run_strict rollout_rolling --service moodle-app --image ghcr.io/acme/app:v2

    assert_success
    refute_output --partial "unbound variable"
    [[ ! -f "${WORKDIR}/docker-compose.rollout.yaml" ]]
}

# =============================================================================
# 22. Rodada 4 da auditoria: guarda de SERVICE no N5 e ancoragem do vhost
# =============================================================================

@test "N5 (rodada 4): rolling sem --image NAO herda a imagem registrada de OUTRO servico" {
    # O state file e unico por diretorio de projeto e pode conter o estado de
    # outro servico (projeto multi-servico, ex. dspace). Herdar o IMAGE sem
    # conferir o SERVICE gravaria a imagem de A como se fosse de B — e, como o
    # SERVICE e reescrito, o guarda de divergencia do 'rollout status' (N3)
    # perderia a capacidade de detectar isso.
    cat > "${ROLLOUT_STATE_FILE}" <<'EOF'
SERVICE="servico-a"
LIVE_SLOT="blue"
LIVE_TARGET="servico-a:443"
PREVIOUS_TARGET=""
IMAGE="ghcr.io/acme/a:v1"
UPDATED_AT="2026-09-01T00:00:00-03:00"
EOF

    run rollout_rolling --service moodle-app
    assert_success

    grep -q 'SERVICE="moodle-app"' "${ROLLOUT_STATE_FILE}"
    run grep -q 'a:v1' "${ROLLOUT_STATE_FILE}"
    assert_failure
}

@test "N5 (rodada 4): rolling sem --image PRESERVA a imagem registrada do MESMO servico" {
    cat > "${ROLLOUT_STATE_FILE}" <<'EOF'
SERVICE="moodle-app"
LIVE_SLOT="blue"
LIVE_TARGET="moodle-app:443"
PREVIOUS_TARGET=""
IMAGE="ghcr.io/acme/app:v3"
UPDATED_AT="2026-09-01T00:00:00-03:00"
EOF

    run rollout_rolling --service moodle-app
    assert_success
    grep -q 'IMAGE="ghcr.io/acme/app:v3"' "${ROLLOUT_STATE_FILE}"
}

@test "rodada 4: linha 'set \$target' COMENTADA no vhost nao decide o slot do rollout" {
    # Sem ancoragem em ^[[:space:]]*set, um '# set $target <svc>-green:80;'
    # deixado por um operador faria a resolucao do slot live cair em green com
    # o trafego real em blue — e o bluegreen seguinte recriaria justamente o
    # container em trafego (outage), que e o que o Blue/Green existe para
    # evitar. Tambem protege o vhost_target/switch (mesmo padrao ancorado).
    cat > "${VHOST_FILE}" <<'EOF'
server {
	listen 443 ssl;
	server_name acme.example.br;

	location / {
		resolver 127.0.0.11;
		# set $target moodle-app-green:80;
		set $target moodle-app:443;
		proxy_pass https://$target;
	}
}
EOF

    run _rollout_resolve_live_slot moodle-app
    assert_success
    assert_output "blue"

    run _rollout_vhost_target "${VHOST_FILE}" moodle-app
    assert_success
    assert_output "https 443"
}

@test "rodada 4 (obs): switch do vhost nao toca linha COMENTADA ('# set \$target ...')" {
    # Quarto ponto ancorado (o unico que ESCREVE): um comentario com o alias
    # nao pode ser reescrito nem passar a decidir o slot; a linha real e
    # reescrita e a indentacao (TAB) e preservada.
    cat > "${VHOST_FILE}" <<'EOF'
server {
	listen 443 ssl;
	server_name acme.example.br;

	location / {
		resolver 127.0.0.11;
		# set $target moodle-app-green:80;
		set $target moodle-app:443;
		proxy_pass https://$target;
	}
}
EOF

    run _rollout_switch_vhost "${VHOST_FILE}" moodle-app moodle-app-green
    assert_success

    grep -q '# set \$target moodle-app-green:80;' "${VHOST_FILE}"
    grep -qE '^[[:space:]]+set \$target moodle-app-green:443;$' "${VHOST_FILE}"
    run grep -c 'moodle-app-green' "${VHOST_FILE}"
    assert_output "2"
}
