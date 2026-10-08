#!/usr/bin/env bats
# tests/vhost.bats — testes para lib/vhost.sh (modulo unico dono do vhost, F2.2)
#
# Cobre a garantia unica (backup -> aplicar -> nginx -t -> reverter em
# falha) diretamente nas funcoes publicas do modulo (vhost_write,
# vhost_switch_target, vhost_remove) e o "escreve so se mudou" (cmp -s).
# Os wrappers (nginx_enable_site, nginx_disable_site, _rollout_switch_vhost)
# tem cobertura propria em tests/nginx.bats e tests/rollout.bats — aqui o
# alvo e o modulo em si.

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh core.sh nginx.sh vhost.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    mock_sudo_passthrough
    export NGINX_CONTAINER_NAME="nginx-proxy"

    # docker mockado: registra toda invocacao em docker.log; "nginx -t"
    # falha so se DOCKER_NGINX_T_FAIL=1 (setado por teste especifico) —
    # senao, sempre exit 0 (inspect/exec/-t/-s reload).
    mock_cmd docker '
        echo "$@" >> "'"${WORKDIR}"'/docker.log"
        if [[ "${DOCKER_NGINX_T_FAIL:-0}" == "1" ]]; then
            for a in "$@"; do [[ "$a" == "-t" ]] && exit 1; done
        fi
        exit 0
    '
}

teardown() {
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && chmod -R 777 "${WORKDIR}" 2>/dev/null || true
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

# --- garantia do modulo: vhost_write ---------------------------------------

@test "vhost_write: sucesso aplica o novo conteudo e recarrega" {
    mkdir -p vhosts
    echo "server { novo }" > src.conf
    local dst="${WORKDIR}/vhosts/app.conf"
    echo "server { original }" > "${dst}"

    run vhost_write src.conf "${dst}"
    assert_success

    grep -q "novo" "${dst}"
    grep -q "nginx -t" "${WORKDIR}/docker.log"
    grep -q "nginx -s reload" "${WORKDIR}/docker.log"
}

@test "vhost_write: nginx -t falho restaura o conteudo original (nao aplica, nao apaga)" {
    mkdir -p vhosts
    echo "server { novo }" > src.conf
    local dst="${WORKDIR}/vhosts/app.conf"
    echo "server { original }" > "${dst}"
    export DOCKER_NGINX_T_FAIL=1

    run vhost_write src.conf "${dst}"
    assert_failure

    [[ -f "${dst}" ]]
    grep -q "original" "${dst}"
    run grep -q "novo" "${dst}"
    assert_failure
}

@test "vhost_write (B1): restauracao falha -> backup NAO e apagado" {
    mkdir -p vhosts
    local dst="${WORKDIR}/vhosts/app.conf"
    echo "server { original }" > "${dst}"
    echo "server { novo }" > src.conf

    # Mock de `cp`: falha as 2 primeiras chamadas cujo destino e "${dst}"
    # (a de APLICACAO e a de RESTAURACAO); a do backup (destino backup_dir/)
    # nao casa e delega ao cp real. Assim a restauracao falha e o backup
    # tem de sobreviver (regressao B1 da auditoria).
    local real_cp="/bin/cp"
    [[ -x "/usr/bin/cp" ]] && real_cp="/usr/bin/cp"
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
            if (( n <= 2 )); then
                echo "cp: mock failure ${n}/2 para ${target}" >&2
                exit 1
            fi
        fi
        exec "${real_cp}" "$@"
    '
    export MOCK_CP_FAIL_TARGET="${dst}"

    run vhost_write src.conf "${dst}"
    assert_failure

    # a mensagem cita o backup preservado; extrai o caminho e prova que existe
    local backup_dir
    backup_dir="$(printf '%s\n' "$output" | grep -oE '/[^ ]*cctl_vhost_backup\.[^ ]*' | head -n1)"
    [[ -n "${backup_dir}" ]]
    [[ -d "${backup_dir}" ]]
    grep -q "original" "${backup_dir}/app.conf"
}

# --- "escreve so se mudou" ---------------------------------------------------

@test "vhost_write (D-F2.2-d): conteudo identico NAO dispara aplicar+reload" {
    mkdir -p vhosts
    local dst="${WORKDIR}/vhosts/app.conf"
    printf 'server { igual }\n' > "${dst}"
    printf 'server { igual }\n' > src.conf

    run vhost_write src.conf "${dst}"
    assert_success

    # nenhuma chamada a docker (nem inspect, nem -t, nem reload) — o modulo
    # detectou conteudo identico via cmp -s e pulou aplicar+reload
    [[ ! -f "${WORKDIR}/docker.log" ]]
}

@test "vhost_write (D-F2.2-d): conteudo diferente DISPARA aplicar+reload" {
    mkdir -p vhosts
    local dst="${WORKDIR}/vhosts/app.conf"
    printf 'server { velho }\n' > "${dst}"
    printf 'server { novo }\n' > src.conf

    run vhost_write src.conf "${dst}"
    assert_success

    grep -q "nginx -s reload" "${WORKDIR}/docker.log"
    grep -q "novo" "${dst}"
}

# --- vhost_remove ------------------------------------------------------------

@test "vhost_remove: sucesso remove o vhost e recarrega" {
    mkdir -p vhosts
    local dst="${WORKDIR}/vhosts/app.conf"
    echo "server { original }" > "${dst}"

    run vhost_remove "${dst}"
    assert_success
    [[ ! -f "${dst}" ]]
    grep -q "nginx -s reload" "${WORKDIR}/docker.log"
}

@test "vhost_remove: nginx -t falho apos remover RESTAURA o vhost original" {
    mkdir -p vhosts
    local dst="${WORKDIR}/vhosts/app.conf"
    echo "server { original }" > "${dst}"
    export DOCKER_NGINX_T_FAIL=1

    run vhost_remove "${dst}"
    assert_failure
    [[ -f "${dst}" ]]
    grep -q "original" "${dst}"
}

# --- vhost_switch_target -----------------------------------------------------

@test "vhost_switch_target: sucesso troca so a linha set \$target e recarrega" {
    mkdir -p vhosts
    local dst="${WORKDIR}/vhosts/app.conf"
    cat > "${dst}" <<'EOF'
server {
	listen 443 ssl;
	location / {
		set $target moodle-app:443;
		proxy_pass https://$target;
	}
}
EOF

    run vhost_switch_target "${dst}" moodle-app moodle-app-green
    assert_success

    grep -qE '^[[:space:]]+set \$target moodle-app-green:443;$' "${dst}"
    grep -q "nginx -s reload" "${WORKDIR}/docker.log"
}

@test "vhost_switch_target: nginx -t falho restaura o vhost anterior (byte-identico)" {
    mkdir -p vhosts
    local dst="${WORKDIR}/vhosts/app.conf"
    cat > "${dst}" <<'EOF'
server {
	listen 443 ssl;
	location / {
		set $target moodle-app:443;
		proxy_pass https://$target;
	}
}
EOF
    cp "${dst}" "${WORKDIR}/vhost.orig"
    export DOCKER_NGINX_T_FAIL=1

    run vhost_switch_target "${dst}" moodle-app moodle-app-green
    assert_failure

    cmp -s "${dst}" "${WORKDIR}/vhost.orig"
}

# --- escape de regex e alvos qualificados (<container>.<rede>) -----------------

@test "vhost_regex_escape: ponto e metacaracteres viram literais; hifen fica" {
    run vhost_regex_escape 'proj-app.proj_net'
    assert_output 'proj-app\.proj_net'
    run vhost_regex_escape 'a[b]c*d+e?f(g)h{i}j|k^l$m/n'
    assert_output 'a\[b\]c\*d\+e\?f\(g\)h\{i\}j\|k\^l\$m\/n'
}

@test "vhost_regex_escape: o resultado casa o texto literal e NAO casa o 'ponto coringa'" {
    local re
    re="$(vhost_regex_escape 'proj-app.net')"
    run grep -cE "^${re}:" <<< 'proj-app.net:443'
    assert_output "1"
    run grep -cE "^${re}:" <<< 'proj-appXnet:443'
    assert_output "0"
}

@test "vhost_target_hosts: lista o host (sem a porta) de cada set \$target, ignorando comentarios" {
    run vhost_target_hosts $'\t\t# set $target velho.net:80;\n\t\tset $target p-app.net:443;\n\t\tset $target p-ang.net:4000;'
    assert_success
    assert_line --index 0 "p-app.net"
    assert_line --index 1 "p-ang.net"
    [[ "${#lines[@]}" -eq 2 ]]
}

@test "vhost_switch_target: alias com '.' e '-' troca so a linha certa (sem casar parecidos nem prefixos)" {
    mkdir -p vhosts
    local dst="${WORKDIR}/vhosts/app.conf"
    cat > "${dst}" <<'EOF'
server {
	location /a {
		set $target proj-app.proj_net:443;
		proxy_pass https://$target;
	}
	location /b {
		set $target projXapp.proj_net:443;
		proxy_pass https://$target;
	}
	location /c {
		set $target proj-app-angular.proj_net:4000;
		proxy_pass http://$target;
	}
	location /d {
		set $target proj-app.outra_net:443;
		proxy_pass https://$target;
	}
}
EOF
    run vhost_switch_target "${dst}" "proj-app.proj_net" "proj-app-green.proj_net"
    assert_success

    grep -q 'set \$target proj-app-green.proj_net:443;' "${dst}"
    grep -q 'set \$target projXapp.proj_net:443;' "${dst}"
    grep -q 'set \$target proj-app-angular.proj_net:4000;' "${dst}"
    grep -q 'set \$target proj-app.outra_net:443;' "${dst}"
    [[ "$(grep -c 'proj-app-green' "${dst}")" -eq 1 ]]
}

@test "vhost_validate_targets: alvo que nao comeca com COMPOSE_PROJECT_NAME- (placeholder sem render) -> rc 1" {
    export COMPOSE_PROJECT_NAME="p"
    printf '\t\tset $target {{COMPOSE_PROJECT_NAME}}-app.p_net:443;\n' > unr.conf
    run vhost_validate_targets unr.conf "p_net"
    assert_failure
    assert_output --partial "nao comeca com 'p-'"

    printf '\t\tset $target outro-app.p_net:443;\n' > outro.conf
    run vhost_validate_targets outro.conf "p_net"
    assert_failure
}

@test "vhost_validate_targets: aceita TAB/varios espacos depois de 'set'" {
    export COMPOSE_PROJECT_NAME="p"
    printf 'x {\n\t\tset\t$target   p-app.p_net:443;\n}\n' > tab.conf
    run vhost_validate_targets tab.conf "p_net"
    assert_success
}

@test "vhost_switch_target: aceita TAB depois de 'set'" {
    mkdir -p vhosts
    local dst="${WORKDIR}/vhosts/app.conf"
    printf 'x {\n\t\tset\t$target p-app.p_net:443;\n}\n' > "${dst}"
    run vhost_switch_target "${dst}" "p-app.p_net" "p-app-green.p_net"
    assert_success
    grep -q 'p-app-green.p_net:443;' "${dst}"
}

@test "vhost_validate_targets: alvo no formato <container>.<rede> passa; vhost sem alvo passa" {
    export COMPOSE_PROJECT_NAME="p"
    printf '\t\tset $target p-app.p_net:443;\n' > ok.conf
    run vhost_validate_targets ok.conf "p_net"
    assert_success
    printf 'server { listen 80; }\n' > acme.conf
    run vhost_validate_targets acme.conf "p_net"
    assert_success
}

@test "vhost_validate_targets: rede vazia -> rc 1, diz que NAO publicou" {
    export COMPOSE_PROJECT_NAME="p"
    printf '\t\tset $target p-app.:443;\n' > bad.conf
    run vhost_validate_targets bad.conf ""
    assert_failure
    assert_output --partial "CCTL_PROJECT_NETWORK esta vazio"
    assert_output --partial "NAO foi publicado"
}

@test "vhost_validate_targets: nome curto ou placeholder sem render -> rc 1" {
    export COMPOSE_PROJECT_NAME="p"
    printf '\t\tset $target moodle-app:443;\n' > short.conf
    run vhost_validate_targets short.conf "p_net"
    assert_failure
    assert_output --partial "nao esta no formato <container>.p_net"

    printf '\t\tset $target p-app.{{CCTL_PROJECT_NETWORK}}:443;\n' > ph.conf
    run vhost_validate_targets ph.conf "p_net"
    assert_failure
}

@test "vhost_validate_targets: basta UM alvo ruim entre varios" {
    export COMPOSE_PROJECT_NAME="p"
    printf '\t\tset $target p-app.p_net:443;\n\t\tset $target curto:80;\n' > mix.conf
    run vhost_validate_targets mix.conf "p_net"
    assert_failure
}
