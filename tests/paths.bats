#!/usr/bin/env bats
# tests/paths.bats — testes para a derivacao de caminhos em cctl.conf e para
# o comando `cctl paths` (commands/paths.sh)
#
# Isolamento: a derivacao roda em subshell bash limpo (env -i + variaveis
# explicitas), nunca no processo do teste — evita que uma variavel exportada
# por um teste vaze para os demais.

setup() {
    load 'helpers/common'
    load_bats_libs
    source_lib colors.sh log.sh core.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1
}

teardown() {
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
