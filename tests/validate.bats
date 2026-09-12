#!/usr/bin/env bats
# tests/validate.bats — testes para lib/validate.sh

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh validate.sh
}

teardown() {
    teardown_mock_bin
    true
}

# --- validate_docker ---------------------------------------------------

@test "validate_docker: sucesso quando docker, docker info e compose respondem" {
    mock_cmd docker '
        case "$1 $2" in
            "info "*|"info") exit 0 ;;
            "compose version") exit 0 ;;
            *) if [[ "$1" == "--version" ]]; then echo "Docker version 27.0.0"; exit 0; fi
               exit 0 ;;
        esac
    '
    run validate_docker
    assert_success
}

@test "validate_docker: falha quando docker nao esta no PATH" {
    # isola o PATH so no diretorio de mocks (vazio) para garantir ausencia real
    PATH="${MOCK_BIN}" run validate_docker
    assert_failure
}

@test "validate_docker: falha quando docker info retorna erro (daemon parado)" {
    mock_cmd docker '
        if [[ "$1" == "info" ]]; then exit 1; fi
        if [[ "$1" == "--version" ]]; then echo "Docker version 27.0.0"; exit 0; fi
        exit 0
    '
    run validate_docker
    assert_failure
}

@test "validate_docker: falha quando compose plugin ausente" {
    mock_cmd docker '
        if [[ "$1" == "info" ]]; then exit 0; fi
        if [[ "$1" == "compose" && "$2" == "version" ]]; then exit 1; fi
        if [[ "$1" == "--version" ]]; then echo "Docker version 27.0.0"; exit 0; fi
        exit 0
    '
    run validate_docker
    assert_failure
}

# --- validate_disk_space ------------------------------------------------

@test "validate_disk_space: passa com minimo baixo (1MB) no diretorio atual" {
    run validate_disk_space 1 "."
    assert_success
}

@test "validate_disk_space: falha exigindo espaco absurdamente alto" {
    run validate_disk_space 999999999999 "."
    assert_failure
}

# --- validate_port_available --------------------------------------------

@test "validate_port_available: porta livre quando ss nao lista nada" {
    mock_cmd ss 'exit 1'
    run validate_port_available 54321
    assert_success
}

@test "validate_port_available: porta ocupada quando ss lista a porta" {
    mock_cmd ss 'echo "LISTEN 0 128 0.0.0.0:54321 0.0.0.0:*"'
    run validate_port_available 54321
    assert_failure
}

# --- validate_dns --------------------------------------------------------

@test "validate_dns: dominios locais (.local/.test/localhost) pulam resolucao" {
    run validate_dns "meuapp.local"
    assert_success
    run validate_dns "localhost"
    assert_success
}

@test "validate_dns: sucesso quando host resolve o dominio" {
    mock_cmd host 'exit 0'
    run validate_dns "exemplo.com.br"
    assert_success
}

@test "validate_dns: falha (warn) quando host nao resolve o dominio" {
    mock_cmd host 'exit 1'
    run validate_dns "exemplo-inexistente.com.br"
    assert_failure
}

# --- validate_git ---------------------------------------------------------

@test "validate_git: sucesso quando git esta disponivel" {
    mock_cmd git 'exit 0'
    run validate_git
    assert_success
}

@test "validate_git: falha quando git nao esta no PATH" {
    # isola o PATH so no diretorio de mocks (vazio, sem git real)
    PATH="${MOCK_BIN}" run validate_git
    assert_failure
}

# --- validate_project_name ------------------------------------------------

@test "validate_project_name: aceita nomes validos" {
    run validate_project_name "moodle-acme"
    assert_success
    run validate_project_name "app_1"
    assert_success
    run validate_project_name "a1"
    assert_success
    run validate_project_name "dspace9"
    assert_success
}

@test "validate_project_name: rejeita vazio" {
    run validate_project_name ""
    assert_failure
}

@test "validate_project_name: rejeita path traversal" {
    run validate_project_name "../etc"
    assert_failure
}

@test "validate_project_name: rejeita caracteres perigosos para sed/shell (pipe e &)" {
    run validate_project_name "foo|bar"
    assert_failure
    run validate_project_name "foo&bar"
    assert_failure
}

@test "validate_project_name: rejeita espacos" {
    run validate_project_name "foo bar"
    assert_failure
}

@test "validate_project_name: rejeita maiusculas" {
    run validate_project_name "Moodle-Acme"
    assert_failure
}

@test "validate_project_name: rejeita comecar com hifen ou underscore" {
    run validate_project_name "-app"
    assert_failure
    run validate_project_name "_app"
    assert_failure
}

@test "validate_project_name: rejeita nome de 1 caractere (minimo 2)" {
    run validate_project_name "a"
    assert_failure
}

@test "validate_project_name: rejeita nome acima de 63 caracteres" {
    run validate_project_name "$(printf 'a%.0s' {1..64})"
    assert_failure
}
