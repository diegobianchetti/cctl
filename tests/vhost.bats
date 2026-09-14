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
