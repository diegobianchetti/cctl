#!/usr/bin/env bats
# tests/compose.bats — testes para lib/compose.sh (compose_pull)
#
# Isolamento: docker/docker compose sempre mockados via bin/ temporario no
# PATH. Nenhum container, imagem ou registry real e tocado.

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh compose.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    export COMPOSE_PROJECT_NAME="testproj"
    export CCTL_LOG_DIR="${WORKDIR}/logs"
    export CCTL_LOG_FILE=""
    unset COMPOSE_FILES MOCK_PULL_FAIL_SERVICE MOCK_PULL_FAIL_SERVICES MOCK_IMAGE_LOCAL MOCK_SERVICES MOCK_IMAGE_EMPTY_SERVICE MOCK_NO_DEPS 2>/dev/null || true

    # Mock de `docker` / `docker compose ...`:
    # - `compose config --services` -> lista de servicos (MOCK_SERVICES ou "app db")
    # - `compose config --images <svc>` -> reproduz o BUG REAL medido em E2E
    #   (moodle-app depends_on moodle-db): quando o servico pedido tem
    #   depends_on, o subcomando ignora o filtro e devolve TAMBEM a imagem da
    #   dependencia primeiro (ordem do arquivo: db antes de app) — e por isso
    #   que a implementacao antiga (`| head -n1`) pegava a imagem errada.
    #   So existe aqui para a prova de regressao (compose_service_image NAO
    #   usa mais este caminho). Vazio se MOCK_IMAGE_EMPTY_SERVICE == <svc>
    #   (simula plugin compose que nao suporta "config --images", ver O1).
    # - `compose config` (sem filtro) -> YAML resolvido com "app" tendo
    #   depends_on: db — e o que compose_service_image (implementacao atual)
    #   de fato parseia.
    # - `compose pull <svc>` -> falha se <svc> estiver em
    #   MOCK_PULL_FAIL_SERVICE (legado, um so) ou MOCK_PULL_FAIL_SERVICES
    #   (lista espaco-separada, para exercitar 2+ falhas simultaneas)
    # - `image inspect <ref>` -> sucesso so se MOCK_IMAGE_LOCAL == <ref>
    mock_cmd docker '
        log="'"${WORKDIR}"'/docker_calls.log"
        echo "docker $*" >> "${log}"

        if [[ "$1" == "compose" ]]; then
            shift
            args=("$@")
            i=0
            sub=""
            while (( i < ${#args[@]} )); do
                case "${args[$i]}" in
                    -f) i=$((i + 2)) ;;
                    -p) i=$((i + 2)) ;;
                    *) sub="${args[$i]}"; i=$((i + 1)); break ;;
                esac
            done
            rest=("${args[@]:$i}")

            case "${sub}" in
                config)
                    if [[ "${rest[0]:-}" != "--services" && "${rest[0]:-}" != "--images" \
                        && -n "${MOCK_CONFIG_FAIL:-}" ]]; then
                        # simula "docker compose config" quebrado (compose
                        # invalido / servico com erro) para o caminho de
                        # compose_service_image (B3)
                        echo "error parsing docker-compose config" >&2
                        exit 1
                    fi
                    if [[ "${rest[0]:-}" == "--services" ]]; then
                        if [[ -n "${MOCK_SERVICES:-}" ]]; then
                            printf "%s\n" ${MOCK_SERVICES}
                        else
                            printf "app\ndb\n"
                        fi
                        exit 0
                    elif [[ "${rest[0]:-}" == "--images" ]]; then
                        svc="${rest[1]:-}"
                        if [[ "${MOCK_IMAGE_EMPTY_SERVICE:-}" == "${svc}" ]]; then
                            : # imagem nao resolvida — simula O1
                        elif [[ "${svc}" == "app" && -z "${MOCK_NO_DEPS:-}" ]]; then
                            # bug real: depends_on faz o filtro ser ignorado
                            echo "postgres:16"
                            echo "myregistry.local/testproj-app:latest"
                        else
                            case "${svc}" in
                                app) echo "myregistry.local/testproj-app:latest" ;;
                                db)  echo "postgres:16" ;;
                            esac
                        fi
                        exit 0
                    else
                        # docker compose config (YAML resolvido, sem args)
                        for s in ${MOCK_SERVICES:-app db}; do
                            echo "  ${s}:"
                            case "${s}" in
                                app)
                                    echo "    build:"
                                    echo "      context: ."
                                    if [[ "${MOCK_IMAGE_EMPTY_SERVICE:-}" != "app" ]]; then
                                        echo "    image: myregistry.local/testproj-app:latest"
                                    fi
                                    echo "    depends_on:"
                                    echo "      db:"
                                    echo "        condition: service_started"
                                    ;;
                                db)
                                    if [[ "${MOCK_IMAGE_EMPTY_SERVICE:-}" != "db" ]]; then
                                        echo "    image: postgres:16"
                                    fi
                                    ;;
                                *)
                                    echo "    build:"
                                    echo "      context: ."
                                    ;;
                            esac
                        done | { echo "services:"; cat; }
                        if [[ -n "${MOCK_CONFIG_EXTRA_BLOCK:-}" ]]; then
                            # bloco top-level preservado apos "services:" (ex:
                            # uma extensao "x-*" do compose resolvido) com uma
                            # chave "image:" na MESMA indentacao (4 espacos)
                            # usada dentro de um servico — prova que o parser
                            # de compose_service_image nao pode devolver essa
                            # imagem so porque "in_target" ainda esta setado
                            # de um bloco anterior (B4).
                            echo "x-extra:"
                            echo "  bogus:"
                            echo "    image: nao-e-a-imagem-certa:latest"
                        fi
                        exit 0
                    fi
                    ;;
                pull)
                    svc="${rest[-1]:-}"
                    if [[ "${MOCK_PULL_FAIL_SERVICE:-}" == "${svc}" ]] \
                        || [[ " ${MOCK_PULL_FAIL_SERVICES:-} " == *" ${svc} "* ]]; then
                        echo "Error response from daemon: pull access denied for ${svc}" >&2
                        exit 1
                    fi
                    exit 0
                    ;;
                *)
                    exit 0
                    ;;
            esac
        fi

        case "$1" in
            image)
                if [[ "$2" == "inspect" ]]; then
                    if [[ -n "${MOCK_IMAGE_LOCAL:-}" && "${MOCK_IMAGE_LOCAL}" == "$3" ]]; then
                        exit 0
                    else
                        exit 1
                    fi
                fi
                exit 1
                ;;
        esac
        exit 1
    '
}

teardown() {
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

@test "compose_pull: caminho feliz, nenhuma falha, rc 0" {
    run compose_pull
    assert_success
    assert_output --partial "Imagens baixadas"
}

@test "compose_pull: imagem presente localmente + pull falha -> aviso e rc 0 (P1a)" {
    export MOCK_PULL_FAIL_SERVICE="app"
    export MOCK_IMAGE_LOCAL="myregistry.local/testproj-app:latest"

    run compose_pull
    assert_success
    assert_output --partial "myregistry.local/testproj-app:latest"
    assert_output --partial "copia local"
}

@test "compose_pull: imagem ausente localmente + pull falha -> rc != 0 nomeando a imagem (P1b)" {
    export MOCK_PULL_FAIL_SERVICE="app"
    unset MOCK_IMAGE_LOCAL

    run compose_pull
    assert_failure
    assert_output --partial "myregistry.local/testproj-app:latest"
}

@test "compose_pull: falha de um servico nao impede o pull dos demais" {
    export MOCK_PULL_FAIL_SERVICE="app"
    export MOCK_IMAGE_LOCAL="myregistry.local/testproj-app:latest"

    run compose_pull
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "pull app"
    assert_output --partial "pull db"
}

@test "compose_pull: dois servicos falham ao mesmo tempo sem copia local -> agrega ambos em hard_failures" {
    export MOCK_PULL_FAIL_SERVICES="app db"
    unset MOCK_IMAGE_LOCAL

    run compose_pull
    assert_failure
    # a mensagem final agrega as duas imagens, nao so a primeira que falhou
    assert_output --partial "myregistry.local/testproj-app:latest"
    assert_output --partial "postgres:16"

    # ambos os servicos tentaram o pull, apesar do primeiro falhar
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "pull app"
    assert_output --partial "pull db"
}

@test "compose_pull (O1): resolucao de imagem vazia nao vira erro duro — avisa e segue" {
    export MOCK_PULL_FAIL_SERVICE="app"
    export MOCK_IMAGE_EMPTY_SERVICE="app"
    unset MOCK_IMAGE_LOCAL

    run compose_pull
    assert_success
    assert_output --partial "app"
    run cat "${WORKDIR}/docker_calls.log"
    # nao deve ter tentado "docker image inspect app" (nome do servico usado
    # como imagem) — o servico foi pulado com aviso, nao tratado como imagem
    # ausente
    refute_output --partial "image inspect app"
}

@test "compose_pull sob 'set -euo pipefail' real: falha de pull sem copia local nao mata o shell (rc!=0 limpo)" {
    export MOCK_PULL_FAIL_SERVICE="app"
    unset MOCK_IMAGE_LOCAL

    local script="${WORKDIR}/_strict_compose_pull.sh"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        printf 'CCTL_ROOT=%q\n' "${CCTL_ROOT}"
        echo 'source "${CCTL_ROOT}/lib/colors.sh"'
        echo 'source "${CCTL_ROOT}/lib/log.sh"'
        echo 'source "${CCTL_ROOT}/lib/compose.sh"'
        echo 'compose_pull'
    } > "${script}"
    chmod +x "${script}"

    run "${script}"
    assert_failure
    assert_output --partial "myregistry.local/testproj-app:latest"
}

@test "compose_pull (B3) sob 'set -euo pipefail' real: 'docker compose config' quebrado nao mata o shell mudo — mensagem clara e rc!=0 controlado" {
    # Compose quebrado (docker compose config falha) + pull do servico
    # tambem falhando: antes do fix, "image=$(compose_service_image ...)"
    # e uma atribuicao simples — sob set -e, o rc!=0 da substituicao matava
    # o shell ANTES do "if [[ -z ... ]]" rodar, entao 'install' morria com
    # rc=1 sem nenhuma mensagem. Com "|| image=\"\"", o caminho de aviso
    # roda normalmente.
    export MOCK_PULL_FAIL_SERVICE="app"
    export MOCK_CONFIG_FAIL=1
    unset MOCK_IMAGE_LOCAL

    local script="${WORKDIR}/_strict_compose_pull_config_fail.sh"
    {
        echo '#!/usr/bin/env bash'
        echo 'set -euo pipefail'
        printf 'CCTL_ROOT=%q\n' "${CCTL_ROOT}"
        echo 'source "${CCTL_ROOT}/lib/colors.sh"'
        echo 'source "${CCTL_ROOT}/lib/log.sh"'
        echo 'source "${CCTL_ROOT}/lib/compose.sh"'
        echo 'compose_pull'
    } > "${script}"
    chmod +x "${script}"

    run "${script}"
    assert_success
    assert_output --partial "Nao foi possivel resolver a imagem do servico app"
    assert_output --partial "Imagens baixadas"
}

# --- compose_service_image: resolucao correta em servico com depends_on ---
# (bug real medido em E2E: "config --images <svc>" ignora o filtro quando o
# servico tem depends_on e devolve tambem a imagem da dependencia; um
# `head -n1` posterior pegava a imagem errada)

@test "compose_service_image app: devolve a imagem do app, nao a da dependencia db (bug real do E2E)" {
    run compose_service_image app
    assert_success
    assert_output "myregistry.local/testproj-app:latest"
    refute_output "postgres:16"
}

@test "compose_service_image db: devolve a imagem do db" {
    run compose_service_image db
    assert_success
    assert_output "postgres:16"
}

@test "compose_service_image: servico so com build: (sem image:) devolve vazio" {
    export MOCK_SERVICES="app db buildonly"

    run compose_service_image buildonly
    assert_success
    assert_output ""
}

@test "compose_service_image: servico inexistente devolve vazio" {
    run compose_service_image inexistente
    assert_success
    assert_output ""
}

@test "compose_service_image (B4): servico-alvo sem 'image:' e o ultimo do bloco nao herda 'image:' de bloco top-level posterior (ex: x-*)" {
    # O compose resolvido preserva um bloco top-level DEPOIS de "services:"
    # (ex: uma extensao x-*) com uma chave "image:" na mesma indentacao (4
    # espacos) usada dentro de servico. O servico-alvo ("buildonly") e o
    # ultimo do bloco de servicos e nao tem "image:" propria (so "build:").
    # Antes do fix, "in_services=0" ao sair do bloco de servicos nao
    # resetava "in_target" (que so era guardado por "in_target" sozinho, sem
    # "in_services &&") — o parser continuava considerando o alvo "em
    # escopo" e devolvia a imagem do bloco errado.
    export MOCK_SERVICES="app db buildonly"
    export MOCK_CONFIG_EXTRA_BLOCK=1

    run compose_service_image buildonly
    assert_success
    assert_output ""
    refute_output --partial "nao-e-a-imagem-certa"
}

# --- P1 (compose_pull) com dependencia — o caso que o E2E real expos ---

@test "P1 com dependencia: imagem do app ausente + imagem do db presente -> erro duro nomeando a imagem do APP" {
    export MOCK_PULL_FAIL_SERVICE="app"
    export MOCK_IMAGE_LOCAL="postgres:16"

    run compose_pull
    assert_failure
    assert_output --partial "myregistry.local/testproj-app:latest"
    # nao deve tolerar o pull do app so porque a imagem do DB (dependencia)
    # existe localmente
    refute_output --partial "Usando a copia local ja existente"
}

@test "P1 com dependencia, caminho tolerante: imagem do proprio app presente localmente -> aviso e rc 0" {
    export MOCK_PULL_FAIL_SERVICE="app"
    export MOCK_IMAGE_LOCAL="myregistry.local/testproj-app:latest"

    run compose_pull
    assert_success
    assert_output --partial "myregistry.local/testproj-app:latest"
    assert_output --partial "copia local"
}
