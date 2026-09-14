#!/usr/bin/env bash
# tests/helpers/common.bash — helpers compartilhados entre baterias .bats
#
# Isolamento: nenhum teste toca o host real. Comandos externos (docker, ss,
# host, certbot, sudo) sao sempre mockados via bin/ temporario no PATH.

# Raiz do projeto cctl (dois niveis acima deste arquivo: tests/helpers/..)
CCTL_ROOT="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
export CCTL_ROOT

load_bats_libs() {
    load "${BATS_TEST_DIRNAME}/vendor/bats-support/load.bash"
    load "${BATS_TEST_DIRNAME}/vendor/bats-assert/load.bash"
}

# Cria um diretorio de binarios mockados e o antepoe ao PATH.
# Chamar no setup() de cada bateria que precise isolar comandos externos.
setup_mock_bin() {
    MOCK_BIN="$(mktemp -d)"
    export MOCK_BIN
    export PATH="${MOCK_BIN}:${PATH}"
}

# Remove o diretorio de mocks. Chamar no teardown().
#
# hash -r apos remover: bash cacheia o caminho resolvido de cada comando
# (hash table). Testes que mockam um binario tambem chamado depois no
# teardown (ex.: "rm", usado pelo proprio teardown() do arquivo de teste
# para limpar WORKDIR) deixam a hash apontando pro mock ja removido —
# proxima chamada falha com "No such file or directory" mesmo com o rm real
# disponivel no PATH. Sem isso o efeito e sutil: some so quando a bateria
# mocka justo um binario usado no restante do teardown.
teardown_mock_bin() {
    [[ -n "${MOCK_BIN:-}" && -d "${MOCK_BIN}" ]] && rm -rf "${MOCK_BIN}"
    hash -r 2>/dev/null || true
}

# Cria um comando mockado executavel em MOCK_BIN.
# Uso: mock_cmd <nome> '<corpo do script bash>'
mock_cmd() {
    local name="$1"
    local body="$2"

    cat > "${MOCK_BIN}/${name}" <<MOCKEOF
#!/usr/bin/env bash
${body}
MOCKEOF
    chmod +x "${MOCK_BIN}/${name}"
}

# Sourcea libs sem depender do core_bootstrap completo (evita puxar libs que
# fazem chamadas externas nao relacionadas ao que esta sendo testado).
# Uso: source_lib validate.sh log.sh colors.sh
source_lib() {
    local f
    for f in "$@"; do
        # shellcheck source=/dev/null
        source "${CCTL_ROOT}/lib/${f}"
    done
}

# Cria um diretorio temporario de trabalho e cd nele. Ecoa o path.
make_tmp_workdir() {
    local d
    d="$(mktemp -d)"
    echo "${d}"
}

# Mocka sudo repassando de fato para o comando real (sob o mock), em vez de
# so registrar a chamada. Trata a flag "-n" (usada por core_priv_run em
# contexto nao-interativo) para que o comando real seja executado tambem
# nesse caminho — sem isso, "$@" comecaria com "-n" e o exec falharia,
# fazendo os testes validarem so a escrita em sudo.log e nao o efeito real
# da operacao no disco.
# Uso: mock_sudo_passthrough [caminho-do-log]  (default: ${WORKDIR}/sudo.log)
mock_sudo_passthrough() {
    local logfile="${1:-${WORKDIR}/sudo.log}"
    mock_cmd sudo '
        echo "sudo-called: $*" >> "'"${logfile}"'"
        [[ "$1" == "-n" ]] && shift
        exec "$@"
    '
}

# Mocka sudo sempre falhando (simula usuario sem privilegio de root nenhum e
# sem NOPASSWD configurado) — usado para exercitar o fallback de
# lib/cron.sh (crontab do usuario) sem tocar sudo/root real.
# Uso: mock_sudo_deny [caminho-do-log]  (default: ${WORKDIR}/sudo.log)
mock_sudo_deny() {
    local logfile="${1:-${WORKDIR}/sudo.log}"
    mock_cmd sudo '
        echo "sudo-called: $*" >> "'"${logfile}"'"
        exit 1
    '
}

# Mocka `crontab` com um arquivo local como "crontab do usuario" — nenhuma
# crontab real do host e lida ou escrita. Suporta os 3 subcomandos usados
# por lib/cron.sh: "-l" (le, erro se vazia — como o crontab real), "-"
# (escreve stdin) e "-r" (remove tudo).
# Uso: mock_crontab [caminho-do-arquivo-de-estado] (default: ${WORKDIR}/crontab.store)
mock_crontab() {
    local store="${1:-${WORKDIR}/crontab.store}"
    : > "${store}"
    mock_cmd crontab '
        store="'"${store}"'"
        case "${1:-}" in
            -l)
                if [[ -s "${store}" ]]; then
                    cat "${store}"
                    exit 0
                fi
                echo "no crontab for $(whoami)" >&2
                exit 1
                ;;
            -)
                cat > "${store}"
                exit 0
                ;;
            -r)
                : > "${store}"
                exit 0
                ;;
            *)
                echo "mock crontab: uso nao suportado: $*" >&2
                exit 1
                ;;
        esac
    '
}

# Mocka `crontab` sempre falhando na escrita ("crontab -"), mas respondendo
# normalmente a "-l" (crontab vazia) — usado para exercitar o caminho de
# erro de lib/cron.sh:_cron_install_user_crontab (B3a) sem depender de
# nenhum crontab real.
# Uso: mock_crontab_write_fails
mock_crontab_write_fails() {
    mock_cmd crontab '
        case "${1:-}" in
            -l)
                echo "no crontab for $(whoami)" >&2
                exit 1
                ;;
            -)
                cat > /dev/null
                exit 1
                ;;
            *)
                exit 1
                ;;
        esac
    '
}

# Monta, dentro do diretorio informado, symlinks para um subconjunto minimo
# de binarios do host e ecoa o caminho — usado para simular ausencia de um
# comando especifico (ex. "crontab") sem remover o resto do PATH real, que
# quebraria builtins externos usados pelas libs (awk, sed, basename...). O
# diretorio informado deve estar sob o WORKDIR do teste para ser limpo no
# teardown padrao.
# Uso: PATH="$(make_minimal_path_without "${WORKDIR}/minimal-bin" crontab)" run <comando>
make_minimal_path_without() {
    local scratch="$1"
    local exclude="$2"
    mkdir -p "${scratch}"

    local c p
    for c in awk basename dirname cat grep sed whoami printf mkdir date; do
        [[ "${c}" == "${exclude}" ]] && continue
        p="$(command -v "${c}" 2>/dev/null)" || continue
        ln -sf "${p}" "${scratch}/${c}"
    done

    echo "${scratch}"
}

# Gera um par chave/certificado autoassinado REAL (RSA 2048, valido por 1
# dia) para testes que precisam de modulus batendo de verdade — ex.
# validacao estrita de SSL_MODE=manual. Nao usa mock: openssl real do host.
# Uso: make_test_keypair <cert_path> <key_path> [cn] [SAN]
make_test_keypair() {
    local cert_path="$1"
    local key_path="$2"
    local cn="${3:-test.example.com}"
    local san="${4:-DNS:${cn}}"

    openssl req -x509 -nodes -days 1 -newkey rsa:2048 \
        -keyout "${key_path}" \
        -out "${cert_path}" \
        -subj "/CN=${cn}" \
        -addext "subjectAltName=${san}" \
        &>/dev/null
}

# Gera um par chave/certificado autoassinado REAL com curva ECDSA
# (prime256v1), para testes de comparacao de par agnostica de algoritmo
# (_ssl_keypair_matches nao pode depender de "openssl rsa"/modulus).
# Uso: make_test_ecdsa_keypair <cert_path> <key_path> [cn] [SAN]
make_test_ecdsa_keypair() {
    local cert_path="$1"
    local key_path="$2"
    local cn="${3:-test.example.com}"
    local san="${4:-DNS:${cn}}"

    openssl req -x509 -nodes -days 1 \
        -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "${key_path}" \
        -out "${cert_path}" \
        -subj "/CN=${cn}" \
        -addext "subjectAltName=${san}" \
        &>/dev/null
}

# Mock de `docker` que resolve `network ls --filter ...` respeitando de fato
# o filtro recebido (label=com.docker.compose.project=X ou name=^X_
# ancorado, alem de name=X solto para retrocompatibilidade de outros
# testes) — necessario para que testes consigam discriminar entre projetos
# cujo nome colide por prefixo (ex: "moodle" vs "moodle-lab"), a mesma
# colisao do bug B1. Sem isso, um mock estatico que sempre devolve a mesma
# rede faz a suite passar mesmo com o filtro do codigo de producao quebrado.
#
# Demais subcomandos docker (network connect/disconnect/rm, compose ...) sao
# apenas logados em <logfile> e retornam sucesso (exit 0) — se um teste
# precisar de outro comportamento para eles, deve compor seu proprio
# mock_cmd docker.
#
# Uso:
#   declare -A nets=( [moodle_network]="moodle" [moodle-lab_moodle-network]="moodle-lab" )
#   mock_docker_with_networks nets "${WORKDIR}/docker_calls.log"
mock_docker_with_networks() {
    local -n _nets_ref="$1"
    local logfile="${2:-${WORKDIR}/docker_calls.log}"
    local fixture="${MOCK_BIN}/.networks.tsv"
    local name

    : > "${fixture}"
    for name in "${!_nets_ref[@]}"; do
        printf '%s\t%s\n' "${name}" "${_nets_ref[${name}]}" >> "${fixture}"
    done

    mock_cmd docker '
        log="'"${logfile}"'"
        fixture="'"${fixture}"'"
        echo "docker $*" >> "${log}"

        if [[ "$1" == "network" && "$2" == "ls" ]]; then
            filter=""
            shift 2
            while [[ $# -gt 0 ]]; do
                if [[ "$1" == "--filter" ]]; then
                    filter="$2"
                    shift 2
                else
                    shift
                fi
            done

            if [[ "${filter}" == label=com.docker.compose.project=* ]]; then
                label="${filter#label=com.docker.compose.project=}"
                awk -F"\t" -v l="${label}" "\$2==l {print \$1}" "${fixture}"
            elif [[ "${filter}" == name=^*_ ]]; then
                prefix="${filter#name=^}"
                prefix="${prefix%_}"
                awk -F"\t" -v p="${prefix}_" "index(\$1,p)==1 {print \$1}" "${fixture}"
            elif [[ "${filter}" == name=* ]]; then
                pat="${filter#name=}"
                awk -F"\t" -v p="${pat}" "index(\$1,p)>0 {print \$1}" "${fixture}"
            fi
            exit 0
        fi
        exit 0
    '
}

# Mock de `docker` que resolve `volume ls --filter ...` respeitando de fato o
# filtro recebido (label=com.docker.compose.project=X exato, ou name=X
# tratado como substring solta — igual ao comportamento real do
# `docker volume ls`, que NAO aceita "^" de ancora no filtro "name="). O
# pos-filtro por ancora (grep -E "^X_") e responsabilidade do codigo de
# producao (volumes_list_for_project), nao do mock — por isso aqui a
# substring solta e deliberada: e o que permite um teste provar que, SEM o
# pos-filtro em producao, o volume do outro projeto vaza.
#
# Demais subcomandos docker (volume rm, compose ...) sao apenas logados em
# <logfile> e retornam sucesso — se um teste precisar de outro
# comportamento, deve compor seu proprio mock_cmd docker.
#
# Uso:
#   declare -A vols=( [moodle_dbdata]="moodle" [moodle-lab_dbdata]="" )
#   mock_docker_with_volumes vols "${WORKDIR}/docker_calls.log"
#
# Tamanho opcional por volume (3o argumento, nome de array associativo
# nome->tamanho-com-unidade, ex: [moodle_dbdata]="2GB") para testes que
# precisam discriminar a normalizacao de unidade de "docker system df -v"
# (B1: SIZE vem com unidade — GB/MB/kB/B — nao um numero cru). Volume sem
# entrada no array de tamanhos cai no default "10MB" (comportamento anterior,
# preservado para os testes que nao se importam com o valor exato).
mock_docker_with_volumes() {
    local -n _vols_ref="$1"
    local logfile="${2:-${WORKDIR}/docker_calls.log}"
    local sizes_ref_name="${3:-}"
    local fixture="${MOCK_BIN}/.volumes.tsv"
    local sizes_fixture="${MOCK_BIN}/.volume_sizes.tsv"
    local name

    : > "${fixture}"
    for name in "${!_vols_ref[@]}"; do
        printf '%s\t%s\n' "${name}" "${_vols_ref[${name}]}" >> "${fixture}"
    done

    : > "${sizes_fixture}"
    if [[ -n "${sizes_ref_name}" ]]; then
        local -n _sizes_ref="${sizes_ref_name}"
        for name in "${!_sizes_ref[@]}"; do
            printf '%s\t%s\n' "${name}" "${_sizes_ref[${name}]}" >> "${sizes_fixture}"
        done
    fi

    mock_cmd docker '
        log="'"${logfile}"'"
        fixture="'"${fixture}"'"
        sizes_fixture="'"${sizes_fixture}"'"
        echo "docker $*" >> "${log}"

        if [[ "$1" == "volume" && "$2" == "ls" ]]; then
            filter=""
            shift 2
            while [[ $# -gt 0 ]]; do
                if [[ "$1" == "--filter" ]]; then
                    filter="$2"
                    shift 2
                else
                    shift
                fi
            done

            if [[ "${filter}" == label=com.docker.compose.project=* ]]; then
                label="${filter#label=com.docker.compose.project=}"
                awk -F"\t" -v l="${label}" "\$2==l {print \$1}" "${fixture}"
            elif [[ "${filter}" == name=* ]]; then
                pat="${filter#name=}"
                awk -F"\t" -v p="${pat}" "index(\$1,p)>0 {print \$1}" "${fixture}"
            fi
            exit 0
        fi

        if [[ "$1" == "system" && "$2" == "df" ]]; then
            echo "Local Volumes:"
            echo -e "VOLUME NAME\tLINKS\tSIZE"
            awk -F"\t" -v sizes="${sizes_fixture}" "
                BEGIN {
                    while ((getline line < sizes) > 0) {
                        split(line, f, \"\t\")
                        sz[f[1]] = f[2]
                    }
                }
                { printf \"%s\t1\t%s\n\", \$1, (\$1 in sz ? sz[\$1] : \"10MB\") }
            " "${fixture}"
            exit 0
        fi

        if [[ "$1" == "volume" && "$2" == "rm" ]]; then
            exit 0
        fi

        exit 0
    '
}
