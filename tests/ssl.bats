#!/usr/bin/env bats
# tests/ssl.bats — testes para lib/ssl.sh (matriz de SSL) e commands/ssl.sh
#
# Isolamento: nenhum comando externo real e chamado exceto openssl (usado de
# proposito para gerar/validar pares de chave reais). docker, sudo e host sao
# sempre mockados via bin/ temporario no PATH — certbot roda dentro do
# container (docker exec), entao o mock de docker e quem registra a chamada.

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh core.sh validate.sh nginx.sh vhost.sh ssl.sh
    # shellcheck source=/dev/null
    source "${CCTL_ROOT}/commands/ssl.sh"

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    export LETSENCRYPT_DIR="${WORKDIR}/letsencrypt"
    export LETSENCRYPT_LIVE_DIR="${WORKDIR}/letsencrypt/live"
    export NGINX_CONTAINER_NAME="nginx-proxy"
    export DOMAIN_NAME="app.example.com"

    # sudo mockado: registra que foi chamado e executa o comando de verdade
    mock_sudo_passthrough
    # docker sempre valido (nginx -t / -s reload / inspect do container)
    mock_cmd docker 'exit 0'
    # host sempre resolve (validate_dns) a menos que o teste sobrescreva
    mock_cmd host 'exit 0'
}

teardown() {
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && chmod -R 777 "${WORKDIR}" 2>/dev/null || true
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

# ============================================================
# core_priv_run (mkdir/cp/install) — ja cobertos, mantidos
# ============================================================

@test "core_priv_run: mkdir -p recursivo nao usa sudo quando o primeiro ancestral existente e gravavel" {
    run core_priv_run mkdir -p "${WORKDIR}/a/b/c"
    assert_success
    [[ -d "${WORKDIR}/a/b/c" ]]
    [[ ! -f sudo.log ]]
}

@test "core_priv_run: mkdir -p recursivo usa sudo quando o primeiro ancestral existente nao e gravavel" {
    [[ "${EUID}" -eq 0 ]] && skip "root ignora permissoes de diretorio"

    mkdir -p base_ro
    chmod 555 base_ro

    run core_priv_run mkdir -p "${WORKDIR}/base_ro/x/y"
    chmod 755 base_ro

    [[ -f sudo.log ]]
}

@test "core_priv_run: mkdir -p sobe varios niveis ate achar ancestral existente" {
    mkdir -p existente
    run core_priv_run mkdir -p "${WORKDIR}/existente/nivel1/nivel2/nivel3"
    assert_success
    [[ -d "${WORKDIR}/existente/nivel1/nivel2/nivel3" ]]
    [[ ! -f sudo.log ]]
}

@test "core_priv_run: cp nao usa sudo quando origem legivel e destino gravavel" {
    echo "cert" > cert.pem
    mkdir -p dest

    run core_priv_run cp cert.pem dest/fullchain.pem
    assert_success
    [[ -f dest/fullchain.pem ]]
    [[ ! -f sudo.log ]]
}

@test "core_priv_run: cp usa sudo quando a ORIGEM nao e legivel, mesmo com destino gravavel" {
    [[ "${EUID}" -eq 0 ]] && skip "root ignora permissoes de arquivo"

    echo "cert" > cert.pem
    chmod 000 cert.pem
    mkdir -p dest

    run core_priv_run cp cert.pem dest/fullchain.pem

    chmod 644 cert.pem
    [[ -f sudo.log ]]
}

@test "core_priv_run: cp usa sudo quando o destino ja existe e nao e gravavel" {
    [[ "${EUID}" -eq 0 ]] && skip "root ignora permissoes de arquivo"

    echo "novo" > cert.pem
    mkdir -p dest
    echo "velho" > dest/fullchain.pem
    chmod 444 dest/fullchain.pem

    run core_priv_run cp cert.pem dest/fullchain.pem || true

    chmod 644 dest/fullchain.pem
    [[ -f sudo.log ]]
}

@test "core_priv_run: install -m 600 nao usa sudo quando origem legivel e destino gravavel" {
    echo "chave" > key.pem
    mkdir -p dest

    run core_priv_run install -m 600 key.pem dest/privkey.pem
    assert_success
    [[ -f dest/privkey.pem ]]
    [[ ! -f sudo.log ]]

    local perms
    perms="$(stat -c '%a' dest/privkey.pem)"
    assert_equal "${perms}" "600"
}

@test "core_priv_run: install usa sudo quando a origem (chave privada) nao e legivel" {
    [[ "${EUID}" -eq 0 ]] && skip "root ignora permissoes de arquivo"

    echo "chave" > key.pem
    chmod 000 key.pem
    mkdir -p dest

    run core_priv_run install -m 600 key.pem dest/privkey.pem

    chmod 644 key.pem
    [[ -f sudo.log ]]
}

# ============================================================
# ssl_get_cert_path / ssl_get_key_path
# ============================================================

@test "ssl_get_cert_path: modo self-signed resolve para /etc/letsencrypt (sem 'live')" {
    export SSL_MODE="self-signed"
    run ssl_get_cert_path "app.example.com"
    assert_success
    assert_output "/etc/letsencrypt/app.example.com/fullchain.pem"
}

@test "ssl_get_key_path: modo self-signed resolve para /etc/letsencrypt (sem 'live')" {
    export SSL_MODE="self-signed"
    run ssl_get_key_path "app.example.com"
    assert_success
    assert_output "/etc/letsencrypt/app.example.com/privkey.pem"
}

@test "ssl_get_cert_path: modo manual resolve para /etc/letsencrypt (sem 'live')" {
    export SSL_MODE="manual"
    run ssl_get_cert_path "app.example.com"
    assert_success
    assert_output "/etc/letsencrypt/app.example.com/fullchain.pem"
}

@test "ssl_get_key_path: modo manual resolve para /etc/letsencrypt (sem 'live')" {
    export SSL_MODE="manual"
    run ssl_get_key_path "app.example.com"
    assert_success
    assert_output "/etc/letsencrypt/app.example.com/privkey.pem"
}

@test "ssl_get_cert_path: modo letsencrypt resolve para /etc/letsencrypt/live" {
    export SSL_MODE="letsencrypt"
    run ssl_get_cert_path "app.example.com"
    assert_success
    assert_output "/etc/letsencrypt/live/app.example.com/fullchain.pem"
}

@test "ssl_get_key_path: modo letsencrypt resolve para /etc/letsencrypt/live" {
    export SSL_MODE="letsencrypt"
    run ssl_get_key_path "app.example.com"
    assert_success
    assert_output "/etc/letsencrypt/live/app.example.com/privkey.pem"
}

@test "ssl_get_cert_path: modo invalido falha" {
    export SSL_MODE="bogus"
    run ssl_get_cert_path "app.example.com"
    assert_failure
}

@test "ssl_get_cert_path: modo none retorna vazio com sucesso" {
    export SSL_MODE="none"
    run ssl_get_cert_path "app.example.com"
    assert_success
    assert_output ""
}

@test "ssl_get_key_path: modo none retorna vazio com sucesso" {
    export SSL_MODE="none"
    run ssl_get_key_path "app.example.com"
    assert_success
    assert_output ""
}

# ============================================================
# ssl_issue: self-signed
# ============================================================

@test "ssl_issue: self-signed gera par de chaves com SAN e recarrega o nginx" {
    export SSL_MODE="self-signed"

    run ssl_issue "app.example.com"
    assert_success

    local dest="${LETSENCRYPT_DIR}/app.example.com"
    [[ -f "${dest}/fullchain.pem" ]]
    [[ -f "${dest}/privkey.pem" ]]

    local perms
    perms="$(stat -c '%a' "${dest}/privkey.pem")"
    assert_equal "${perms}" "600"

    # SAN cobre dominio e wildcard
    run openssl x509 -noout -text -in "${dest}/fullchain.pem"
    assert_output --partial "DNS:app.example.com"
    assert_output --partial "DNS:*.app.example.com"

    # par gerado e valido (modulus bate)
    run _ssl_keypair_matches "${dest}/fullchain.pem" "${dest}/privkey.pem"
    assert_success
}

@test "ssl_issue: self-signed pula dominios locais" {
    export SSL_MODE="self-signed"

    run ssl_issue "localhost"
    assert_success
    [[ ! -d "${LETSENCRYPT_DIR}" ]]
}

@test "ssl_renew: self-signed regenera o par de chaves" {
    export SSL_MODE="self-signed"
    ssl_issue "app.example.com"
    local dest="${LETSENCRYPT_DIR}/app.example.com"

    run ssl_renew "app.example.com"
    assert_success

    # regenerado: arquivos continuam presentes e formam par valido
    [[ -f "${dest}/fullchain.pem" ]]
    [[ -f "${dest}/privkey.pem" ]]
    run _ssl_keypair_matches "${dest}/fullchain.pem" "${dest}/privkey.pem"
    assert_success
}

@test "ssl_renew: self-signed gera de fato um novo par (fingerprint muda)" {
    export SSL_MODE="self-signed"
    ssl_issue "app.example.com"
    local dest="${LETSENCRYPT_DIR}/app.example.com"

    local fingerprint_antes fingerprint_depois
    fingerprint_antes=$(openssl x509 -noout -fingerprint -sha256 -in "${dest}/fullchain.pem")

    run ssl_renew "app.example.com"
    assert_success

    fingerprint_depois=$(openssl x509 -noout -fingerprint -sha256 -in "${dest}/fullchain.pem")

    [[ "${fingerprint_antes}" != "${fingerprint_depois}" ]]

    # o novo par continua consistente (cert e chave da mesma geracao batem)
    run _ssl_keypair_matches "${dest}/fullchain.pem" "${dest}/privkey.pem"
    assert_success
}

# ============================================================
# ssl_issue: manual
# ============================================================

@test "ssl_issue: manual instala com sucesso quando o par de chaves e valido" {
    export SSL_MODE="manual"
    make_test_keypair "${WORKDIR}/cert.pem" "${WORKDIR}/key.pem" "app.example.com"
    export SSL_CERT_FILE="${WORKDIR}/cert.pem"
    export SSL_KEY_FILE="${WORKDIR}/key.pem"

    run ssl_issue "app.example.com"
    assert_success

    local dest="${LETSENCRYPT_DIR}/app.example.com"
    [[ -f "${dest}/fullchain.pem" ]]
    [[ -f "${dest}/privkey.pem" ]]
}

@test "ssl_issue: manual aborta quando o par de chaves nao bate (mismatch)" {
    export SSL_MODE="manual"
    make_test_keypair "${WORKDIR}/cert.pem" "${WORKDIR}/key_descartada.pem" "app.example.com"
    make_test_keypair "${WORKDIR}/cert_descartado.pem" "${WORKDIR}/key.pem" "app.example.com"
    export SSL_CERT_FILE="${WORKDIR}/cert.pem"
    export SSL_KEY_FILE="${WORKDIR}/key.pem"

    run ssl_issue "app.example.com"
    assert_failure
    assert_output --partial "chave publica do certificado nao corresponde a chave privada"

    # nada foi instalado — abortou ANTES de tocar o destino
    [[ ! -d "${LETSENCRYPT_DIR}/app.example.com" ]]
}

@test "ssl_issue: manual nao corrompe certificado existente quando o novo par e invalido" {
    export SSL_MODE="manual"
    local dest="${LETSENCRYPT_DIR}/app.example.com"
    mkdir -p "${dest}"
    echo "certificado-antigo-valido" > "${dest}/fullchain.pem"
    echo "chave-antiga-valida" > "${dest}/privkey.pem"

    make_test_keypair "${WORKDIR}/cert.pem" "${WORKDIR}/key_descartada.pem" "app.example.com"
    make_test_keypair "${WORKDIR}/cert_descartado.pem" "${WORKDIR}/key.pem" "app.example.com"
    export SSL_CERT_FILE="${WORKDIR}/cert.pem"
    export SSL_KEY_FILE="${WORKDIR}/key.pem"

    run ssl_issue "app.example.com"
    assert_failure

    # arquivos antigos permanecem intocados
    assert_equal "$(cat "${dest}/fullchain.pem")" "certificado-antigo-valido"
    assert_equal "$(cat "${dest}/privkey.pem")" "chave-antiga-valida"
}

@test "_ssl_issue_manual: instala certificado e chave sem sudo em diretorio gravavel" {
    make_test_keypair "${WORKDIR}/cert.pem" "${WORKDIR}/key.pem" "app.example.com"
    export SSL_CERT_FILE="${WORKDIR}/cert.pem"
    export SSL_KEY_FILE="${WORKDIR}/key.pem"

    run _ssl_issue_manual "app.example.com"
    assert_success
    [[ -f "${LETSENCRYPT_DIR}/app.example.com/fullchain.pem" ]]
    [[ -f "${LETSENCRYPT_DIR}/app.example.com/privkey.pem" ]]
    [[ ! -f sudo.log ]]
}

@test "_ssl_keypair_matches: aceita par ECDSA valido (agnostico de algoritmo)" {
    make_test_ecdsa_keypair "${WORKDIR}/ec_cert.pem" "${WORKDIR}/ec_key.pem" "app.example.com"

    run _ssl_keypair_matches "${WORKDIR}/ec_cert.pem" "${WORKDIR}/ec_key.pem"
    assert_success
}

@test "_ssl_keypair_matches: rejeita par ECDSA cruzado (cert e chave de geracoes diferentes)" {
    make_test_ecdsa_keypair "${WORKDIR}/ec_cert.pem" "${WORKDIR}/ec_key_descartada.pem" "app.example.com"
    make_test_ecdsa_keypair "${WORKDIR}/ec_cert_descartado.pem" "${WORKDIR}/ec_key.pem" "app.example.com"

    run _ssl_keypair_matches "${WORKDIR}/ec_cert.pem" "${WORKDIR}/ec_key.pem"
    assert_failure
}

@test "ssl_issue: manual aceita par ECDSA valido de ponta a ponta" {
    export SSL_MODE="manual"
    make_test_ecdsa_keypair "${WORKDIR}/cert.pem" "${WORKDIR}/key.pem" "app.example.com"
    export SSL_CERT_FILE="${WORKDIR}/cert.pem"
    export SSL_KEY_FILE="${WORKDIR}/key.pem"

    run ssl_issue "app.example.com"
    assert_success

    local dest="${LETSENCRYPT_DIR}/app.example.com"
    [[ -f "${dest}/fullchain.pem" ]]
    [[ -f "${dest}/privkey.pem" ]]
}

@test "_ssl_keypair_matches: le chave privada 0600 nao legivel pelo usuario via core_priv_run (mock de root)" {
    [[ "${EUID}" -eq 0 ]] && skip "root ignora permissoes de arquivo — nada a simular"

    make_test_keypair "${WORKDIR}/cert.pem" "${WORKDIR}/key.pem" "app.example.com"
    chmod 600 "${WORKDIR}/key.pem"
    # Torna a chave ilegivel pelo usuario atual (simula 0600 de outro dono,
    # ex. root) — forca _ssl_read_file a cair para core_priv_run/sudo.
    chmod 000 "${WORKDIR}/key.pem"

    # Mock de sudo que simula o privilegio real de root: concede leitura
    # temporaria so para o "cat" interno, depois restaura a permissao
    # original — exercita o caminho _ssl_read_file -> core_priv_run cat sem
    # exigir root de verdade no ambiente de teste.
    mock_cmd sudo '
        echo "sudo-called" >> "'"${WORKDIR}"'/sudo.log"
        [[ "$1" == "-n" ]] && shift
        if [[ "$1" == "cat" ]]; then
            target="$2"
            chmod u+r "${target}"
            cat "${target}"
            status=$?
            chmod 000 "${target}"
            exit "${status}"
        fi
        exec "$@"
    '

    run _ssl_keypair_matches "${WORKDIR}/cert.pem" "${WORKDIR}/key.pem"

    chmod 644 "${WORKDIR}/key.pem"

    assert_success
    grep -q "sudo-called" "${WORKDIR}/sudo.log"
}

@test "_ssl_issue_manual: aborta quando o certificado de origem nao e legivel" {
    [[ "${EUID}" -eq 0 ]] && skip "root ignora permissoes de arquivo"

    make_test_keypair "${WORKDIR}/cert.pem" "${WORKDIR}/key.pem" "app.example.com"
    chmod 000 "${WORKDIR}/cert.pem"
    export SSL_CERT_FILE="${WORKDIR}/cert.pem"
    export SSL_KEY_FILE="${WORKDIR}/key.pem"
    mock_cmd sudo 'exit 1'

    run _ssl_issue_manual "app.example.com"
    assert_failure

    chmod 644 "${WORKDIR}/cert.pem"
}

# ============================================================
# ssl_issue: letsencrypt
# ============================================================

# Mock de docker parametrizavel: registra toda chamada em docker.log e,
# quando for "docker inspect <container>" (usado por
# _nginx_proxy_require_container), sucede ou falha conforme
# DOCKER_CONTAINER_EXISTS ("1" = existe, default "1").
_mock_docker_ssl() {
    mock_cmd docker '
        echo "$*" >> "'"${WORKDIR}"'/docker.log"
        if [[ "$1" == "inspect" ]]; then
            [[ "'"${DOCKER_CONTAINER_EXISTS:-1}"'" == "1" ]] && exit 0
            exit 1
        fi
        exit 0
    '
}

@test "ssl_issue: letsencrypt chama certbot via docker exec (nao mais no host) e recarrega o nginx" {
    export SSL_MODE="letsencrypt"
    _mock_docker_ssl

    run ssl_issue "app.example.com"
    assert_success
    assert_output --partial "Certificado SSL emitido"
    grep -q -- "exec nginx-proxy certbot certonly --webroot -w /var/www/certbot -d app.example.com --non-interactive --agree-tos --email admin@app.example.com" "${WORKDIR}/docker.log"
    # prova de aceite: nenhuma flag --config-dir/--work-dir/--logs-dir (defaults do container ja bastam)
    run grep -q -- "config-dir" "${WORKDIR}/docker.log"
    assert_failure
}

@test "ssl_issue: letsencrypt aborta quando o DNS nao resolve (sem chamar certbot)" {
    export SSL_MODE="letsencrypt"
    mock_cmd host 'exit 1'
    _mock_docker_ssl

    run ssl_issue "app.example.com"
    assert_failure
    run grep -q "certbot" "${WORKDIR}/docker.log"
    assert_failure
}

@test "ssl_issue: letsencrypt falha quando o container do proxy nao existe" {
    export SSL_MODE="letsencrypt"
    DOCKER_CONTAINER_EXISTS=0 _mock_docker_ssl

    run ssl_issue "app.example.com"
    assert_failure
    assert_output --partial "nao existe"
    assert_output --partial "cctl proxy up"
    run grep -q "certbot" "${WORKDIR}/docker.log"
    assert_failure
}

@test "ssl_renew: letsencrypt chama certbot renew via docker exec" {
    export SSL_MODE="letsencrypt"
    _mock_docker_ssl

    run ssl_renew "app.example.com"
    assert_success
    grep -q -- "exec nginx-proxy certbot renew --quiet" "${WORKDIR}/docker.log"
}

@test "ssl_renew: letsencrypt falha quando o container do proxy nao existe" {
    export SSL_MODE="letsencrypt"
    DOCKER_CONTAINER_EXISTS=0 _mock_docker_ssl

    run ssl_renew "app.example.com"
    assert_failure
    assert_output --partial "nao existe"
}

# ============================================================
# ssl_issue: none
# ============================================================

@test "ssl_issue: none e noop bem-sucedido e nao emite nenhum certificado" {
    export SSL_MODE="none"

    run ssl_issue "app.example.com"
    assert_success
    assert_output --partial "SSL_MODE=none"
    [[ ! -d "${LETSENCRYPT_DIR}" ]]
}

@test "ssl_renew: none e noop informativo" {
    export SSL_MODE="none"
    run ssl_renew "app.example.com"
    assert_success
}

@test "ssl_issue: modo invalido falha com mensagem explicita" {
    export SSL_MODE="bogus"
    run ssl_issue "app.example.com"
    assert_failure
    assert_output --partial "SSL_MODE invalido"
}

# ============================================================
# ssl_status
# ============================================================

@test "ssl_status: none informa ausencia de certificado sem erro" {
    export SSL_MODE="none"
    run ssl_status "app.example.com"
    assert_success
    assert_output --partial "SSL_MODE=none"
}

@test "ssl_status: self-signed reporta expiracao quando o certificado existe" {
    export SSL_MODE="self-signed"
    ssl_issue "app.example.com"

    run ssl_status "app.example.com"
    assert_success
    assert_output --partial "Expira em"
}

@test "ssl_status: manual reporta ausencia quando nenhum certificado foi instalado" {
    export SSL_MODE="manual"
    run ssl_status "app.example.com"
    assert_failure
    assert_output --partial "Nenhum certificado encontrado"
}

@test "ssl_status: letsencrypt reporta expiracao quando o certificado existe" {
    export SSL_MODE="letsencrypt"
    mkdir -p "${LETSENCRYPT_LIVE_DIR}/app.example.com"
    make_test_keypair "${LETSENCRYPT_LIVE_DIR}/app.example.com/fullchain.pem" \
        "${LETSENCRYPT_LIVE_DIR}/app.example.com/privkey.pem" "app.example.com"

    run ssl_status "app.example.com"
    assert_success
    assert_output --partial "Expira em"
}

# ============================================================
# cmd_ssl (commands/ssl.sh)
# ============================================================

@test "cmd_ssl: despacha 'status' para ssl_status" {
    export SSL_MODE="none"
    run cmd_ssl status "app.example.com"
    assert_success
    assert_output --partial "Modo SSL"
}

@test "cmd_ssl: despacha 'issue' para ssl_issue" {
    export SSL_MODE="none"
    run cmd_ssl issue "app.example.com"
    assert_success
    assert_output --partial "SSL_MODE=none"
}

@test "cmd_ssl: despacha 'renew' para ssl_renew" {
    export SSL_MODE="none"
    run cmd_ssl renew "app.example.com"
    assert_success
}

@test "cmd_ssl: usa DOMAIN_NAME do manifest quando o dominio e omitido" {
    export SSL_MODE="none"
    export DOMAIN_NAME="manifest.example.com"

    run cmd_ssl status
    assert_success
    assert_output --partial "manifest.example.com"
}

@test "cmd_ssl: sem acao exibe ajuda" {
    run cmd_ssl
    assert_success
    assert_output --partial "Uso: cctl ssl"
}

@test "cmd_ssl: acao desconhecida exibe uso e falha" {
    run cmd_ssl foo
    assert_failure
    assert_output --partial "Acao desconhecida"
    assert_output --partial "Uso: cctl ssl"
}

# ============================================================
# core_check_command_context: ssl
# ============================================================

@test "core_check_command_context: ssl permitido em contexto instance" {
    CCTL_CONTEXT="instance"
    run core_check_command_context "ssl"
    assert_success
}

@test "core_check_command_context: ssl permitido em contexto project" {
    CCTL_CONTEXT="project"
    run core_check_command_context "ssl"
    assert_success
}

@test "core_check_command_context: ssl bloqueado em contexto template" {
    # shellcheck disable=SC2034  # lida por core_check_command_context (lib/core.sh) via nome da var
    CCTL_CONTEXT="template"
    run core_check_command_context "ssl"
    assert_failure
}
