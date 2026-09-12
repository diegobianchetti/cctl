#!/usr/bin/env bats
# tests/env.bats — testes para lib/env.sh

setup() {
    load 'helpers/common'
    load_bats_libs
    source_lib colors.sh log.sh env.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1
}

teardown() {
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

@test "env_load: exporta variaveis validas e ignora comentarios/linhas vazias" {
    cat > .env <<'EOF'
# comentario
FOO=bar

BAZ=qux
EOF
    run env_load
    assert_success

    # env_load exporta no processo do 'run'; valida com um subshell que herda o export
    run bash -c "
        source '${CCTL_ROOT}/lib/colors.sh' >/dev/null
        source '${CCTL_ROOT}/lib/log.sh' >/dev/null
        source '${CCTL_ROOT}/lib/env.sh' >/dev/null
        env_load
        echo \"\${FOO}:\${BAZ}\"
    "
    assert_output "bar:qux"
}

@test "env_load: nao falha quando .env nao existe" {
    run env_load
    assert_success
}

@test "env_render_template: substitui {{PLACEHOLDERS}} pelos valores do .env" {
    cat > .env <<'EOF'
CLIENT_NAME=acme
DOMAIN_NAME=acme.example.com
EOF
    cat > template.conf <<'EOF'
server_name {{DOMAIN_NAME}};
# cliente: {{CLIENT_NAME}}
EOF
    run env_render_template template.conf out.conf
    assert_success
    run cat out.conf
    assert_output "server_name acme.example.com;
# cliente: acme"
}

@test "env_render_template: avisa sobre placeholders nao substituidos" {
    cat > .env <<'EOF'
CLIENT_NAME=acme
EOF
    cat > template.conf <<'EOF'
{{CLIENT_NAME}} / {{UNDEFINED_VAR}}
EOF
    run env_render_template template.conf out.conf
    assert_success
    assert_output --partial "Placeholders nao substituidos"
    assert_output --partial "UNDEFINED_VAR"
}

@test "env_render_template: falha quando o template nao existe" {
    run env_render_template inexistente.conf out.conf
    assert_failure
}

@test "env_check_required_vars: sucesso quando todas as vars obrigatorias estao definidas" {
    REQUIRED_VARS=(DOMAIN_NAME COMPOSE_PROJECT_NAME)
    export DOMAIN_NAME="x.com" COMPOSE_PROJECT_NAME="proj"
    run env_check_required_vars
    assert_success
}

@test "env_check_required_vars: falha e lista as vars ausentes" {
    # shellcheck disable=SC2034  # lida por env_check_required_vars (lib/env.sh) via nome da var
    REQUIRED_VARS=(DOMAIN_NAME COMPOSE_PROJECT_NAME)
    unset DOMAIN_NAME COMPOSE_PROJECT_NAME
    run env_check_required_vars
    assert_failure
    assert_output --partial "DOMAIN_NAME"
    assert_output --partial "COMPOSE_PROJECT_NAME"
}

@test "env_set_var: adiciona nova variavel quando chave nao existe no .env" {
    touch .env
    run env_set_var NOVA_VAR "valor1"
    assert_success
    run grep -c "^NOVA_VAR=valor1$" .env
    assert_output "1"
}

@test "env_set_var: atualiza valor existente sem duplicar a chave" {
    printf 'CHAVE=antigo\n' > .env
    run env_set_var CHAVE "novo"
    assert_success
    run grep -c "^CHAVE=" .env
    assert_output "1"
    run grep "^CHAVE=" .env
    assert_output "CHAVE=novo"
}

@test "env_set_var: falha quando .env nao existe" {
    run env_set_var CHAVE "valor"
    assert_failure
}
