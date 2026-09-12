#!/usr/bin/env bats
# tests/core.bats — testes para lib/core.sh (deteccao de contexto, dispatch, manifest)

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

# --- core_detect_context -------------------------------------------------

@test "core_detect_context: instance quando .cctl-instance existe" {
    touch .cctl-instance
    core_detect_context
    assert_equal "${CCTL_CONTEXT}" "instance"
    assert_equal "${CCTL_INSTANCE_DIR}" "${WORKDIR}"
}

@test "core_detect_context: project quando so project.conf existe" {
    touch project.conf
    core_detect_context
    assert_equal "${CCTL_CONTEXT}" "project"
}

@test "core_detect_context: instance tem prioridade sobre project" {
    touch project.conf .cctl-instance
    core_detect_context
    assert_equal "${CCTL_CONTEXT}" "instance"
}

@test "core_detect_context: template quando CCTL_ROOT/templates existe e nada mais" {
    export CCTL_ROOT="${WORKDIR}/fakeroot"
    mkdir -p "${CCTL_ROOT}/templates"
    core_detect_context
    assert_equal "${CCTL_CONTEXT}" "template"
}

@test "core_detect_context: unknown fora de qualquer contexto valido" {
    export CCTL_ROOT="${WORKDIR}/fakeroot-sem-templates"
    mkdir -p "${CCTL_ROOT}"
    core_detect_context
    assert_equal "${CCTL_CONTEXT}" "unknown"
}

# --- core_check_command_context ------------------------------------------

@test "core_check_command_context: instance permite qualquer comando" {
    CCTL_CONTEXT="instance"
    run core_check_command_context "backup"
    assert_success
}

@test "core_check_command_context: template so permite init e help" {
    CCTL_CONTEXT="template"
    run core_check_command_context "init"
    assert_success
    run core_check_command_context "up"
    assert_failure
}

@test "core_check_command_context: project so permite install e help" {
    CCTL_CONTEXT="project"
    run core_check_command_context "install"
    assert_success
    run core_check_command_context "backup"
    assert_failure
}

@test "core_check_command_context: unknown so permite init e help" {
    CCTL_CONTEXT="unknown"
    run core_check_command_context "help"
    assert_success
    run core_check_command_context "backup"
    assert_failure
}

# --- core_load_manifest ---------------------------------------------------

@test "core_load_manifest: carrega project.conf quando contexto e instance" {
    cat > project.conf <<'EOF'
PROJECT_TYPE="moodle"
COMPOSE_PROJECT_NAME="moodle-acme"
EOF
    CCTL_CONTEXT="instance"
    core_load_manifest
    assert_equal "${PROJECT_TYPE}" "moodle"
    assert_equal "${COMPOSE_PROJECT_NAME}" "moodle-acme"
}

@test "core_load_manifest: nao carrega nada quando contexto e template" {
    cat > project.conf <<'EOF'
PROJECT_TYPE="moodle"
EOF
    CCTL_CONTEXT="template"
    unset PROJECT_TYPE
    core_load_manifest
    assert_equal "${PROJECT_TYPE:-}" ""
}

# --- core_parse_global_args ------------------------------------------------

@test "core_parse_global_args: sem argumentos usa 'help' como comando" {
    core_parse_global_args
    assert_equal "${CCTL_COMMAND}" "help"
}

@test "core_parse_global_args: primeiro argumento nao-flag vira o subcomando" {
    core_parse_global_args up --foo bar
    assert_equal "${CCTL_COMMAND}" "up"
    assert_equal "${CCTL_ARGS[0]}" "--foo"
    assert_equal "${CCTL_ARGS[1]}" "bar"
}

@test "core_parse_global_args: --help forca comando help" {
    core_parse_global_args --help
    assert_equal "${CCTL_COMMAND}" "help"
}
