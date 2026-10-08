#!/usr/bin/env bats
# tests/paths.bats — testes para a derivacao de caminhos em cctl.conf e para
# o comando `cctl paths` (commands/paths.sh)
#
# Isolamento: a derivacao roda em subshell bash limpo (env -i + variaveis
# explicitas), nunca no processo do teste — evita que uma variavel exportada
# por um teste vaze para os demais.

bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/common'
    load_bats_libs
    source_lib colors.sh log.sh core.sh inventory.sh network.sh
    setup_mock_bin

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    # "cctl paths" tambem consulta o docker (redes) e le o inventario: ambos
    # isolados no WORKDIR/mocks.
    export CCTL_INVENTORY_DIR="${WORKDIR}/inventory"
    mock_sudo_passthrough
    setup_network_env
    mock_docker_netsim "${WORKDIR}/docker_calls.log"
}

teardown() {
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

# Sourcea cctl.conf num subshell bash limpo, com somente as variaveis
# indicadas em "env_assigns" no ambiente, e imprime "NOME=valor" para cada
# nome em "$@" (apos "--"). Uso:
#   _source_cctl_conf "CCTL_BASE_DIR=/x" -- CCTL_BASE_DIR NGINX_VHOSTS_DIR
_source_cctl_conf() {
    local -a env_assigns=()
    while [[ "$1" != "--" ]]; do
        env_assigns+=("$1")
        shift
    done
    shift

    env -i PATH="${PATH}" "${env_assigns[@]}" bash -c '
        source "$1/cctl.conf"
        shift
        for v in "$@"; do
            printf "%s=%s\n" "$v" "${!v}"
        done
    ' _ "${CCTL_ROOT}" "$@"
}

# ============================================================
# Derivacao — default (nada setado)
# ============================================================

@test "cctl.conf: default sem CCTL_BASE_DIR setado resolve para /opt/cctl e derivadas" {
    run _source_cctl_conf -- CCTL_BASE_DIR CCTL_INSTANCE_BASE_DIR NGINX_VHOSTS_DIR LETSENCRYPT_DIR LETSENCRYPT_LIVE_DIR
    assert_success
    assert_output --partial "CCTL_BASE_DIR=/opt/cctl"
    assert_output --partial "CCTL_INSTANCE_BASE_DIR=/opt/cctl/instances"
    assert_output --partial "NGINX_VHOSTS_DIR=/opt/cctl/nginx-proxy/vhosts.d"
    assert_output --partial "LETSENCRYPT_DIR=/opt/cctl/nginx-proxy/certs"
    assert_output --partial "LETSENCRYPT_LIVE_DIR=/opt/cctl/nginx-proxy/certs/live"
}

@test "cctl.conf: CRON_DIR e LOGROTATE_DIR sao fixos, nao derivam de CCTL_BASE_DIR" {
    run _source_cctl_conf "CCTL_BASE_DIR=/custom" -- CRON_DIR LOGROTATE_DIR
    assert_success
    assert_output --partial "CRON_DIR=/etc/cron.d"
    assert_output --partial "LOGROTATE_DIR=/etc/logrotate.d"
}

# ============================================================
# Derivacao — CCTL_BASE_DIR customizado propaga para todas as folhas
# ============================================================

@test "cctl.conf: CCTL_BASE_DIR customizado propaga para todas as derivadas" {
    run _source_cctl_conf "CCTL_BASE_DIR=/custom/cctl" -- CCTL_INSTANCE_BASE_DIR NGINX_VHOSTS_DIR LETSENCRYPT_DIR LETSENCRYPT_LIVE_DIR
    assert_success
    assert_output --partial "CCTL_INSTANCE_BASE_DIR=/custom/cctl/instances"
    assert_output --partial "NGINX_VHOSTS_DIR=/custom/cctl/nginx-proxy/vhosts.d"
    assert_output --partial "LETSENCRYPT_DIR=/custom/cctl/nginx-proxy/certs"
    assert_output --partial "LETSENCRYPT_LIVE_DIR=/custom/cctl/nginx-proxy/certs/live"
}

# ============================================================
# Derivacao — folha individual sobrescrita vence a derivacao
# ============================================================

@test "cctl.conf: folha individual sobrescrita vence a derivacao de CCTL_BASE_DIR" {
    run _source_cctl_conf "CCTL_BASE_DIR=/custom/cctl" "NGINX_VHOSTS_DIR=/outro/vhosts" -- NGINX_VHOSTS_DIR LETSENCRYPT_DIR
    assert_success
    assert_output --partial "NGINX_VHOSTS_DIR=/outro/vhosts"
    # a folha nao sobrescrita continua derivando normalmente da base custom
    assert_output --partial "LETSENCRYPT_DIR=/custom/cctl/nginx-proxy/certs"
}

# ============================================================
# Derivacao — bug de ordem corrigido: LETSENCRYPT_DIR sozinho propaga pro live
# ============================================================

@test "cctl.conf: customizar so LETSENCRYPT_DIR propaga para LETSENCRYPT_LIVE_DIR" {
    run _source_cctl_conf "LETSENCRYPT_DIR=/custom/le" -- LETSENCRYPT_DIR LETSENCRYPT_LIVE_DIR
    assert_success
    assert_output --partial "LETSENCRYPT_DIR=/custom/le"
    assert_output --partial "LETSENCRYPT_LIVE_DIR=/custom/le/live"
}

# ============================================================
# cctl paths
# ============================================================

_load_paths_cmd() {
    # shellcheck source=/dev/null
    source "${CCTL_ROOT}/cctl.conf"
    # shellcheck source=/dev/null
    source "${CCTL_ROOT}/commands/paths.sh"
}

@test "cmd_paths: mostra o CCTL_BASE_DIR default em uso" {
    _load_paths_cmd
    run cmd_paths
    assert_success
    assert_output --partial "CCTL_BASE_DIR: /opt/cctl"
}

@test "cmd_paths: override de CCTL_BASE_DIR aparece nas derivadas listadas" {
    export CCTL_BASE_DIR="${WORKDIR}/base"
    _load_paths_cmd
    run cmd_paths
    assert_success
    assert_output --partial "CCTL_BASE_DIR: ${WORKDIR}/base"
    assert_output --partial "${WORKDIR}/base/nginx-proxy/vhosts.d"
    assert_output --partial "${WORKDIR}/base/nginx-proxy/certs"
}

@test "cmd_paths: lista CRON_DIR/LOGROTATE_DIR como fixos" {
    _load_paths_cmd
    run cmd_paths
    assert_success
    assert_output --partial "/etc/cron.d"
    assert_output --partial "/etc/logrotate.d"
    assert_output --partial "Fixas"
}

@test "cmd_paths: sinaliza diretorio existente e gravavel" {
    export CCTL_BASE_DIR="${WORKDIR}/base"
    mkdir -p "${CCTL_BASE_DIR}/instances"
    _load_paths_cmd
    run cmd_paths
    assert_success
    # restrito a linha da propria folha (CCTL_INSTANCE_BASE_DIR) — uma
    # assercao so em "existe, gravavel" tambem casaria com /etc/cron.d se a
    # suite rodasse como root (root sempre pode escrever)
    assert_line --regexp "^ *CCTL_INSTANCE_BASE_DIR +${CCTL_BASE_DIR}/instances +.*existe, gravavel"
}

@test "cmd_paths: sinaliza diretorio inexistente" {
    export CCTL_BASE_DIR="${WORKDIR}/nao-existe"
    _load_paths_cmd
    run cmd_paths
    assert_success
    assert_output --partial "nao existe"
}

# ============================================================
# cctl paths — rede das instalacoes e divergencias
# ============================================================

@test "cmd_paths: mostra o range de rede do cctl" {
    _load_paths_cmd
    run cmd_paths
    assert_success
    assert_output --partial "Rede das instalacoes"
    assert_output --partial "CCTL_NETWORK_RANGE=10.240.0.0/16"
    assert_output --partial "/24"
}

@test "cmd_paths: sem redes registradas diz que nao ha nenhuma" {
    _load_paths_cmd
    run cmd_paths
    assert_success
    assert_output --partial "Nenhuma rede de instalacao registrada"
}

@test "cmd_paths: lista rede e subnet de cada instancia e diz 'Sem divergencias'" {
    inventory_mark_installed "app1" "moodle" "c" "app1.example.com" "${WORKDIR}/i/app1" "app1_net" "10.240.0.0/24"
    netsim_add_network "app1_net" "app1" "10.240.0.0/24" "app1.example.com"

    _load_paths_cmd
    run cmd_paths
    assert_success
    assert_line --regexp "^ *app1 +app1_net +10\\.240\\.0\\.0/24$"
    assert_output --partial "Sem divergencias"
}

@test "cmd_paths: divergencia de dono e subnet mostra a subnet real e a registrada" {
    inventory_mark_installed "app" "moodle" "c" "app.example.com" "${WORKDIR}/i/app" "app_net" "10.240.4.0/24"
    netsim_add_network "app_net" "outro" "10.240.9.0/24" "app.example.com"

    _load_paths_cmd
    run cmd_paths
    assert_success
    assert_output --partial "DIVERGENCIA: Docker tem dono 'outro'"
    assert_output --partial "subnet 10.240.9.0/24"
    assert_output --partial "inventario registra dono 'app' e subnet 10.240.4.0/24"
}

@test "cmd_paths: rede gerenciada sem instancia no inventario aparece como divergencia (e nada e apagado)" {
    netsim_add_network "fantasma_net" "fantasma" "10.240.9.0/24" "fantasma.example.com"

    _load_paths_cmd
    run cmd_paths
    assert_success
    assert_output --partial "fantasma_net"
    assert_output --partial "DIVERGENCIA: rede do cctl sem instancia no inventario"
    assert_output --partial "docker network rm fantasma_net"
    run ! grep -q "network rm" "${WORKDIR}/docker_calls.log"
    netsim_has_network "fantasma_net"
}

@test "cmd_paths: instancia do inventario cuja rede nao existe aparece como divergencia" {
    inventory_mark_installed "sumiu" "moodle" "c" "sumiu.example.com" "${WORKDIR}/i/sumiu" "sumiu_net" "10.240.1.0/24"

    _load_paths_cmd
    run cmd_paths
    assert_success
    assert_output --partial "sumiu_net"
    assert_output --partial "DIVERGENCIA: a rede nao existe"
    assert_output --partial "cctl up"
}

@test "cmd_paths: instancia instalada sem rede registrada (versao antiga) aparece como divergencia" {
    inventory_mark_installed "antigo" "moodle" "c" "antigo.example.com" "${WORKDIR}/i/antigo"

    _load_paths_cmd
    run cmd_paths
    assert_success
    assert_output --partial "antigo"
    assert_output --partial "instalada sem rede registrada"
}

@test "cmd_paths: Docker indisponivel nao derruba o comando" {
    mock_cmd docker 'exit 1'
    _load_paths_cmd
    run cmd_paths
    assert_success
    assert_output --partial "Docker indisponivel"
}

# ============================================================
# Rede das instalacoes (cctl.conf)
# ============================================================

@test "cctl.conf: range de rede default e 10.240.0.0/16 com prefixo 24" {
    run _source_cctl_conf -- CCTL_NETWORK_RANGE CCTL_NETWORK_PREFIX
    assert_success
    assert_output --partial "CCTL_NETWORK_RANGE=10.240.0.0/16"
    assert_output --partial "CCTL_NETWORK_PREFIX=24"
}

@test "cctl.conf: CCTL_NETWORK_RANGE/CCTL_NETWORK_PREFIX aceitam override do ambiente" {
    run _source_cctl_conf "CCTL_NETWORK_RANGE=192.168.200.0/22" "CCTL_NETWORK_PREFIX=26" -- CCTL_NETWORK_RANGE CCTL_NETWORK_PREFIX
    assert_success
    assert_output --partial "CCTL_NETWORK_RANGE=192.168.200.0/22"
    assert_output --partial "CCTL_NETWORK_PREFIX=26"
}

@test "cctl.conf: o default de rede e privado (RFC 1918) e o prefixo e coerente" {
    run _source_cctl_conf -- CCTL_NETWORK_RANGE CCTL_NETWORK_PREFIX
    assert_success
    local range prefix
    range="$(grep '^CCTL_NETWORK_RANGE=' <<< "${output}" | cut -d= -f2)"
    prefix="$(grep '^CCTL_NETWORK_PREFIX=' <<< "${output}" | cut -d= -f2)"
    source_lib network.sh
    network_cidr_in_rfc1918 "${range}"
    (( prefix >= ${range#*/} && prefix <= 30 ))
}

@test "cmd_paths: rede gerenciada sem label de projeto aparece como divergencia e nao quebra o comando" {
    netsim_add_network "semdono" "@none" "10.240.7.0/24"

    _load_paths_cmd
    run cmd_paths
    assert_success
    assert_output --partial "semdono"
    assert_output --partial "rede gerenciada sem projeto"
}
