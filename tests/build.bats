#!/usr/bin/env bats
# tests/build.bats — testes para commands/build.sh, lib/compose.sh (build*) e
# lib/registry.sh (mock de `docker`/`docker compose`, zero Docker/registry real)

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh validate.sh compose.sh registry.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    export COMPOSE_PROJECT_NAME="testproj"
    export CCTL_LOG_DIR="${WORKDIR}/logs"
    export CCTL_LOG_FILE=""
    unset COMPOSE_FILES CCTL_REGISTRY CCTL_REGISTRY_USER CCTL_REGISTRY_TOKEN \
        GHCR_TOKEN DOCKER_TOKEN DOCKER_OWNER CUSTOM_BUILD_DIR MOCK_BUILD_FAIL \
        MOCK_DOCKERBUILD_FAIL MOCK_LOGIN_FAIL MOCK_PUSH_FAIL \
        MOCK_COMPOSE_CONFIG_FAIL 2>/dev/null || true

    # HOME isolado sem ~/.docker/config.json (sem sessao previa de login)
    export HOME="${WORKDIR}/home"
    mkdir -p "${HOME}"

    # Mock de `docker` (e `docker compose ...`) — loga toda chamada em
    # docker_calls.log (nunca o stdin de `login`, que vai para arquivo a parte).
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
                    if [[ -n "${MOCK_COMPOSE_CONFIG_FAIL:-}" ]]; then
                        echo "erro simulado: docker compose config quebrado" >&2
                        exit 1
                    elif [[ "${rest[0]:-}" == "--services" ]]; then
                        printf "web\napp\ndb\n"
                        exit 0
                    elif [[ "${rest[0]:-}" == "--images" ]]; then
                        echo "src-${rest[1]}:built"
                        exit 0
                    else
                        # docker compose config (YAML resolvido, sem args) —
                        # so "app" tem contexto de build; "web" e "db" so tem
                        # 'image:' (o caso de um servico de terceiro, ex db).
                        cat <<'YAML'
services:
  web:
    image: nginx:latest
  app:
    build:
      context: .
    image: testproj-app:latest
  db:
    image: postgres:16
YAML
                        exit 0
                    fi
                    ;;
                build)
                    [[ -n "${MOCK_BUILD_FAIL:-}" ]] && exit 1
                    exit 0
                    ;;
                *)
                    exit 0
                    ;;
            esac
        fi

        case "$1" in
            tag)
                exit 0
                ;;
            build)
                # Simula o builder legado (DOCKER_BUILDKIT=0 / Docker < 23),
                # que escreve o progresso do build em stdout — regressao do
                # B4: se _build_custom voltar a devolver a ref via stdout,
                # esse eco contamina a captura e o teste abaixo falha.
                echo "Step 1/1 : FROM alpine"
                echo "Successfully built abc123"
                [[ -n "${MOCK_DOCKERBUILD_FAIL:-}" ]] && exit 1
                exit 0
                ;;
            login)
                cat > "'"${WORKDIR}"'/login_stdin.txt"
                [[ -n "${MOCK_LOGIN_FAIL:-}" ]] && exit 1
                exit 0
                ;;
            push)
                [[ -n "${MOCK_PUSH_FAIL:-}" ]] && exit 1
                exit 0
                ;;
            logout)
                exit 0
                ;;
        esac
        exit 0
    '

    local real_cctl_root
    real_cctl_root="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
    # shellcheck source=/dev/null
    source "${real_cctl_root}/commands/build.sh"
}

teardown() {
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

@test "cmd_build sem args chama docker compose build com -f corretos" {
    run cmd_build
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "docker compose -f docker-compose.yml -p testproj build"
}

@test "cmd_build <servico> valida existencia e builda so o servico indicado" {
    run cmd_build app
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "build app"
    refute_output --partial "build web app db"
}

@test "cmd_build <servico-inexistente> falha listando servicos disponiveis" {
    run cmd_build servico-fantasma
    assert_failure
    assert_output --partial "servico-fantasma"
    assert_output --partial "web"
    assert_output --partial "app"
    assert_output --partial "db"
}

@test "--no-cache e --pull sao repassados ao docker compose build" {
    run cmd_build --no-cache --pull app
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "--no-cache"
    assert_output --partial "--pull"
    assert_output --partial "app"
}

@test "--tag sanitiza o repositorio em minusculas mas preserva o case da tag (OCI e case-sensitive)" {
    export COMPOSE_PROJECT_NAME="MyProj"

    run cmd_build app --tag V1.0
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "docker tag src-app:built ghcr.io/myproj-app:V1.0"
    refute_output --partial "ghcr.io/myproj-app:v1.0"
}

@test "--custom usa o Dockerfile de docker/custom/<servico> quando existe" {
    mkdir -p "${WORKDIR}/docker/custom/app"
    echo "FROM alpine" > "${WORKDIR}/docker/custom/app/Dockerfile"

    run cmd_build --custom app --tag v2
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "docker build -t ghcr.io/testproj-app:v2 -f docker/custom/app/Dockerfile docker/custom/app"
}

@test "--custom falha com erro claro quando o Dockerfile nao existe" {
    run cmd_build --custom servico-sem-dockerfile
    assert_failure
    assert_output --partial "Dockerfile customizado nao encontrado"
    assert_output --partial "docker/custom/servico-sem-dockerfile/Dockerfile"
}

@test "--custom respeita override de CUSTOM_BUILD_DIR" {
    export CUSTOM_BUILD_DIR="build-custom"
    mkdir -p "${WORKDIR}/build-custom/app"
    echo "FROM alpine" > "${WORKDIR}/build-custom/app/Dockerfile"

    run cmd_build --custom app
    assert_success
    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "-f build-custom/app/Dockerfile build-custom/app"
}

@test "--push chama login e depois push, na ordem correta, com credenciais" {
    export CCTL_REGISTRY_USER="diego"
    export CCTL_REGISTRY_TOKEN="tok-123"

    run cmd_build app --push
    assert_success

    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "docker login"
    assert_output --partial "docker push"

    local login_line push_line
    login_line=$(grep -n "docker login" "${WORKDIR}/docker_calls.log" | head -1 | cut -d: -f1)
    push_line=$(grep -n "docker push" "${WORKDIR}/docker_calls.log" | head -1 | cut -d: -f1)
    [[ "${login_line}" -lt "${push_line}" ]]
}

@test "--push falha sem credenciais e sem sessao existente" {
    run cmd_build app --push
    assert_failure
    assert_output --partial "requer autenticacao"

    run cat "${WORKDIR}/docker_calls.log"
    refute_output --partial "docker login"
    refute_output --partial "docker push"
}

@test "--push reaproveita sessao existente em ~/.docker/config.json sem token" {
    mkdir -p "${HOME}/.docker"
    echo '{"auths":{"ghcr.io":{}}}' > "${HOME}/.docker/config.json"

    run cmd_build app --push
    assert_success

    run cat "${WORKDIR}/docker_calls.log"
    refute_output --partial "docker login"
    assert_output --partial "docker push"
}

@test "B1: --push sem --tag empurra referencia qualificada pelo registry, nao a imagem crua" {
    export CCTL_REGISTRY_USER="diego"
    export CCTL_REGISTRY_TOKEN="tok-123"
    export CCTL_REGISTRY="meuregistry.example.com/acme"

    run cmd_build app --push
    assert_success

    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "docker tag src-app:built meuregistry.example.com/acme/testproj-app:latest"
    assert_output --partial "docker push meuregistry.example.com/acme/testproj-app:latest"
    refute_output --partial "docker push src-app:built"
    refute_output --partial "docker push testproj-app:latest"
}

@test "--registry tem efeito mesmo sem --tag (regressao do B1)" {
    export CCTL_REGISTRY_USER="diego"
    export CCTL_REGISTRY_TOKEN="tok-123"

    run cmd_build app --push --registry outroregistry.io/time
    assert_success

    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "docker push outroregistry.io/time/testproj-app:latest"
}

@test "B2: sem servicos explicitos, --push so alcanca servicos com build: no compose (nao retagueia 'db')" {
    export CCTL_REGISTRY_USER="diego"
    export CCTL_REGISTRY_TOKEN="tok-123"

    run cmd_build --push
    assert_success

    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "docker tag src-app:built ghcr.io/testproj-app:latest"
    assert_output --partial "docker push ghcr.io/testproj-app:latest"
    refute_output --partial "src-db"
    refute_output --partial "testproj-db"
    refute_output --partial "src-web"
    refute_output --partial "testproj-web"
}

@test "B2: sem servicos explicitos, --tag so retagueia servicos com build: no compose" {
    run cmd_build --tag v3
    assert_success

    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "docker tag src-app:built ghcr.io/testproj-app:v3"
    refute_output --partial "testproj-db"
    refute_output --partial "testproj-web"
}

@test "B3: com DOCKER_OWNER definido, sessao existente (host correto em auths) e reaproveitada sem login" {
    export DOCKER_OWNER="acme"
    mkdir -p "${HOME}/.docker"
    echo '{"auths":{"ghcr.io":{}}}' > "${HOME}/.docker/config.json"

    run cmd_build app --push
    assert_success

    run cat "${WORKDIR}/docker_calls.log"
    refute_output --partial "docker login"
    assert_output --partial "docker push"
}

@test "B3: config.json com credsStore (sem 'auths' casando o host) degrada permitindo a tentativa de push" {
    mkdir -p "${HOME}/.docker"
    echo '{"credsStore":"desktop"}' > "${HOME}/.docker/config.json"

    run cmd_build app --push
    assert_success

    run cat "${WORKDIR}/docker_calls.log"
    refute_output --partial "docker login"
    assert_output --partial "docker push"
}

@test "--push falha quando o login do docker falha (MOCK_LOGIN_FAIL)" {
    export CCTL_REGISTRY_USER="diego"
    export CCTL_REGISTRY_TOKEN="tok-123"
    export MOCK_LOGIN_FAIL=1

    run cmd_build app --push
    assert_failure
    assert_output --partial "Falha ao autenticar"

    run cat "${WORKDIR}/docker_calls.log"
    refute_output --partial "docker push"
}

@test "--push falha quando o push do docker falha (MOCK_PUSH_FAIL)" {
    export CCTL_REGISTRY_USER="diego"
    export CCTL_REGISTRY_TOKEN="tok-123"
    export MOCK_PUSH_FAIL=1

    run cmd_build app --push
    assert_failure
    assert_output --partial "Falha ao enviar"
}

@test "--custom --push builda customizado e publica a referencia correta" {
    mkdir -p "${WORKDIR}/docker/custom/app"
    echo "FROM alpine" > "${WORKDIR}/docker/custom/app/Dockerfile"
    export CCTL_REGISTRY_USER="diego"
    export CCTL_REGISTRY_TOKEN="tok-123"

    run cmd_build --custom app --tag v9 --push
    assert_success

    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "docker build -t ghcr.io/testproj-app:v9 -f docker/custom/app/Dockerfile docker/custom/app"
    assert_output --partial "docker push ghcr.io/testproj-app:v9"
}

@test "--custom com servico posicional extra falha com erro explicito (nao descarta em silencio)" {
    run cmd_build extra-service --custom app
    assert_failure
    assert_output --partial "Nao e possivel combinar '--custom' com servicos posicionais"
}

@test "-t sem valor falha com uso sintetico" {
    run cmd_build app -t
    assert_failure
    assert_output --partial "requer um valor"
    assert_output --partial "Uso: cctl build"
}

@test "--push sem nenhum outro argumento (sem servicos, sem tag) publica os servicos buildaveis" {
    export CCTL_REGISTRY_USER="diego"
    export CCTL_REGISTRY_TOKEN="tok-123"

    run cmd_build --push
    assert_success

    run cat "${WORKDIR}/docker_calls.log"
    assert_output --partial "docker push ghcr.io/testproj-app:latest"
}

@test "tag com charset invalido (espaco) falha na validacao antes de chamar o Docker" {
    run cmd_build app --tag "v1 invalido"
    assert_failure

    [[ -f "${WORKDIR}/docker_calls.log" ]] && run cat "${WORKDIR}/docker_calls.log" || run true
    refute_output --partial "docker tag"
    refute_output --partial "docker push"
}

@test "nome de servico posicional com charset invalido falha antes do compose" {
    run cmd_build "servico invalido"
    assert_failure

    [[ -f "${WORKDIR}/docker_calls.log" ]] && run cat "${WORKDIR}/docker_calls.log" || run true
    refute_output --partial "docker compose"
}

@test "erro real do 'docker compose config' e reportado, nao mascarado como servico inexistente" {
    export MOCK_COMPOSE_CONFIG_FAIL=1

    run cmd_build app
    assert_failure
    assert_output --partial "Falha ao consultar servicos do compose"
    refute_output --partial "Disponiveis:"
}

@test "seguranca: o token nunca aparece nos argumentos nem no log do docker login" {
    export CCTL_REGISTRY_USER="diego"
    export CCTL_REGISTRY_TOKEN="supersecrettoken123"

    run cmd_build app --push
    assert_success
    refute_output --partial "supersecrettoken123"

    run cat "${WORKDIR}/docker_calls.log"
    refute_output --partial "supersecrettoken123"

    # O token so deve chegar via stdin do login (--password-stdin), nunca em argv
    run cat "${WORKDIR}/login_stdin.txt"
    assert_output "supersecrettoken123"
}

@test "registry_image_ref sanitiza o repositorio para minusculas mas preserva o case da tag" {
    export COMPOSE_PROJECT_NAME="MyProj"
    export DOCKER_OWNER="Diego"
    unset CCTL_REGISTRY

    run registry_image_ref "App" "V1"
    assert_success
    assert_output "ghcr.io/diego/myproj-app:V1"
}

@test "registry_image_ref rejeita tag com charset invalido" {
    run registry_image_ref "app" "tag com espaco"
    assert_failure
}

@test "registry_image_ref rejeita nome de servico com charset invalido" {
    run registry_image_ref "app/../etc" "v1"
    assert_failure
}

@test "registry_host extrai apenas o host de um registry com namespace" {
    run registry_host "ghcr.io/acme"
    assert_success
    assert_output "ghcr.io"

    run registry_host "ghcr.io"
    assert_success
    assert_output "ghcr.io"
}

@test "falha de docker compose build propaga return 1" {
    export MOCK_BUILD_FAIL=1

    run cmd_build
    assert_failure
}

@test "falha de docker compose build de servico especifico propaga return 1" {
    export MOCK_BUILD_FAIL=1

    run cmd_build app
    assert_failure
}

@test "cmd_build --help exibe uso sintetico e nao chama o Docker" {
    run cmd_build --help
    assert_success
    assert_output --partial "Uso: cctl build"

    [[ -f "${WORKDIR}/docker_calls.log" ]] && run cat "${WORKDIR}/docker_calls.log" || run true
    refute_output --partial "docker compose"
}

@test "flag invalida retorna erro com uso sintetico" {
    run cmd_build --flag-invalida
    assert_failure
    assert_output --partial "Uso: cctl build"
}
