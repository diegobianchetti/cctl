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
# sem NOPASSWD configurado) sem tocar sudo/root real.
# Uso: mock_sudo_deny [caminho-do-log]  (default: ${WORKDIR}/sudo.log)
mock_sudo_deny() {
    local logfile="${1:-${WORKDIR}/sudo.log}"
    mock_cmd sudo '
        echo "sudo-called: $*" >> "'"${logfile}"'"
        exit 1
    '
}

# Mocka `crontab` como comando PROIBIDO: qualquer chamada e registrada no
# arquivo informado e falha. O cctl exige sudo e nunca usa a crontab do
# usuario — o teste confere que o arquivo continua vazio.
# Uso: mock_crontab_forbidden [caminho-do-log] (default: ${WORKDIR}/crontab.calls)
mock_crontab_forbidden() {
    local logfile="${1:-${WORKDIR}/crontab.calls}"
    : > "${logfile}"
    mock_cmd crontab '
        echo "crontab-called: $*" >> "'"${logfile}"'"
        exit 1
    '
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
            [[ "${MOCK_VOLUME_RM_FAIL:-0}" == "1" ]] && exit 1
            exit 0
        fi

        exit 0
    '
}

# ---------------------------------------------------------------------------
# Rede das instalacoes (F2.6): ambiente determinista + docker "simulado"
# ---------------------------------------------------------------------------

# Deixa o range de rede, o daemon.json e as rotas do host controlados pelo
# teste (nenhum teste le o /etc/docker/daemon.json nem as rotas reais do host).
# Sem rotas por padrao; use mock_ip_routes para simular rotas.
# Uso: setup_network_env   (precisa de setup_mock_bin antes)
setup_network_env() {
    export CCTL_NETWORK_RANGE="10.240.0.0/16"
    export CCTL_NETWORK_PREFIX="24"
    export DOCKER_DAEMON_JSON=""
    mock_ip_routes
}

# Mocka `ip -4 route` com as linhas passadas (uma por argumento).
# Uso: mock_ip_routes "10.0.0.0/8 dev tun0 scope link" "172.17.0.0/16 dev docker0 ..."
mock_ip_routes() {
    local routes_file="${MOCK_BIN}/.ip_routes"
    : > "${routes_file}"
    local line
    for line in "$@"; do
        printf '%s\n' "${line}" >> "${routes_file}"
    done
    mock_cmd ip '
        if [[ "$1" == "-4" && "$2" == "route" ]]; then
            cat "'"${routes_file}"'"
            exit 0
        fi
        exit 0
    '
}

# Docker "simulado" para redes: guarda estado em arquivos (redes existentes,
# redes a que o proxy esta ligado) e responde so ao que o cctl usa
# (network ls/inspect/create/connect/disconnect/rm e `docker inspect` do
# proxy). Toda chamada vai para o log. Diferente de um mock estatico, o
# resultado de um `network create` aparece no `network inspect` seguinte.
#
# Uso: mock_docker_netsim [logfile]   (default: ${BATS_TEST_TMPDIR}/netsim/docker.log)
#      netsim_add_network <nome> <projeto> <subnet> [dominio]   (projeto "" = rede de terceiros)
#      netsim_connect <rede> [alias]      (liga o proxy a rede)
#      netsim_fail_subnet <subnet>        (o `network create` dessa faixa falha por sobreposicao)
#      projeto "@none" = rede com io.cctl.managed mas SEM o label io.cctl.project
#      netsim_fail_rm                     (o `network rm` falha: endpoints ativos)
#      netsim_fail_connect <rede>         (o proxy existe, mas `network connect` e recusado)
#      netsim_fail_inspect <objeto>       (inspect falha por transporte; nao e ausencia)
#      netsim_remove_proxy                (o container nginx-proxy nao existe)
#      netsim_add_container <nome> <rede> <ip>   (container e o DNS do proxy para <nome>.<rede>)
#      netsim_resolve_override <host> <ip|none>  (forca o que o proxy resolve)
mock_docker_netsim() {
    export NETSIM_DIR="${BATS_TEST_TMPDIR}/netsim"
    mkdir -p "${NETSIM_DIR}"
    : > "${NETSIM_DIR}/nets"
    : > "${NETSIM_DIR}/connected"
    : > "${NETSIM_DIR}/fail"
    : > "${NETSIM_DIR}/connect_fail"
    : > "${NETSIM_DIR}/inspect_fail"
    : > "${NETSIM_DIR}/proxy_exists"
    : > "${NETSIM_DIR}/containers"
    : > "${NETSIM_DIR}/resolve_override"
    export NETSIM_LOG="${1:-${NETSIM_DIR}/docker.log}"
    : > "${NETSIM_LOG}"

    cat > "${MOCK_BIN}/docker" <<'MOCKEOF'
#!/usr/bin/env bash
dir="${NETSIM_DIR}"
echo "docker $*" >> "${NETSIM_LOG}"
nets="${dir}/nets"
conn="${dir}/connected"

# nets: nome|projeto|subnet|dominio
field() { awk -F'|' -v n="$1" -v c="$2" '$1==n {print $c; exit}' "${nets}"; }
exists() { awk -F'|' -v n="$1" '$1==n {f=1} END {exit !f}' "${nets}"; }

if [[ "$1" == "inspect" ]]; then
    shift
    fmt=""; target=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -f) fmt="$2"; shift 2 ;;
            *) target="$1"; shift ;;
        esac
    done
    if [[ "${fmt}" == *'index .NetworkSettings.Networks'* ]]; then
        # IP de um container numa rede: containers = nome|rede|ip
        netname=$(sed -E 's/.*Networks \\?"([^"\\]*)\\?".*/\1/' <<< "${fmt}")
        awk -F'|' -v c="${target}" '$1==c {f=1} END {exit !f}' "${dir}/containers" || exit 1
        awk -F'|' -v c="${target}" -v n="${netname}" '$1==c && $2==n {print $3; exit}' "${dir}/containers"
        exit 0
    fi
    # docker inspect -f <fmt> nginx-proxy : redes a que o proxy esta ligado.
    # A existencia e separada da lista de conexoes para testar connect recusado.
    if [[ "${target}" == "nginx-proxy" ]]; then
        if grep -qxF "nginx-proxy" "${dir}/inspect_fail"; then
            echo "Error response from daemon: transport is closing" >&2
            exit 1
        fi
        [[ -e "${dir}/proxy_exists" ]] || { echo "Error: No such object: nginx-proxy" >&2; exit 1; }
        cut -d'|' -f1 "${conn}"
        exit 0
    fi
    exit 1
fi

if [[ "$1" == "exec" ]]; then
    # docker exec <proxy> getent ahostsv4 <container>.<rede>  (linhas "IP STREAM nome")
    if [[ "$3" == "getent" && "$4" == "ahostsv4" ]]; then
        host="$5"
        ov=$(awk -F'|' -v h="${host}" '$1==h {print $2; exit}' "${dir}/resolve_override")
        if [[ -n "${ov}" ]]; then
            [[ "${ov}" == "none" ]] && exit 2
            # varios IPs separados por virgula = varias linhas
            for oip in ${ov//,/ }; do echo "${oip} STREAM ${host}"; done
            exit 0
        fi
        cname="${host%%.*}"
        # container pode ter ponto no nome? nao: o alvo e <container>.<rede>
        netn="${host#*.}"
        # DNS do proxy so enxerga a rede quando ele esta conectado a ela.
        grep -q "^${netn}|" "${conn}" || exit 2
        ip=$(awk -F'|' -v c="${cname}" -v n="${netn}" '$1==c && $2==n {print $3; exit}' "${dir}/containers")
        [[ -n "${ip}" ]] || exit 2
        echo "${ip} STREAM ${host}"
        exit 0
    fi
    exit 0
fi

if [[ "$1" == "network" ]]; then
    sub="$2"
    shift 2
    case "${sub}" in
        ls)
            filter="" ; quiet=0
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --filter) filter="$2"; shift 2 ;;
                    --format) shift 2 ;;
                    -q) quiet=1; shift ;;
                    *) shift ;;
                esac
            done
            if [[ "${filter}" == "label=io.cctl.managed=true" ]]; then
                awk -F'|' '$2 != "" {print $1}' "${nets}"
            else
                cut -d'|' -f1 "${nets}"
            fi
            exit 0
            ;;
        inspect)
            fmt=""; names=()
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --format) fmt="$2"; shift 2 ;;
                    *) names+=("$1"); shift ;;
                esac
            done
            rc=0
            for n in "${names[@]}"; do
                if grep -qxF "${n}" "${dir}/inspect_fail"; then
                    echo "Error response from daemon: transport is closing" >&2
                    rc=1
                    continue
                fi
                if ! exists "${n}"; then
                    echo "Error: No such network: ${n}" >&2
                    rc=1
                    continue
                fi
                case "${fmt}" in
                    "") ;;
                    *'{{.Name}} {{range'*) echo "${n} $(field "${n}" 3) " ;;
                    *'{{.Name}}|{{index'*) pj=$(field "${n}" 2); [[ "${pj}" == "@none" ]] && pj=""; echo "${n}|${pj}|$(field "${n}" 3) " ;;
                    *io.cctl.project*) pj=$(field "${n}" 2); [[ "${pj}" == "@none" ]] && pj=""; echo "${pj}" ;;
                    *io.cctl.domain*) field "${n}" 4 ;;
                    *'{{.Subnet}}'*) field "${n}" 3 ;;
                esac
            done
            exit "${rc}"
            ;;
        create)
            subnet=""; name=""; project=""; domain=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --subnet) subnet="$2"; shift 2 ;;
                    --label)
                        case "$2" in
                            io.cctl.project=*) project="${2#io.cctl.project=}" ;;
                            io.cctl.domain=*) domain="${2#io.cctl.domain=}" ;;
                        esac
                        shift 2 ;;
                    --driver) shift 2 ;;
                    *) name="$1"; shift ;;
                esac
            done
            if grep -qxF "${subnet}" "${dir}/fail"; then
                echo "Error response from daemon: invalid pool request: Pool overlaps with other one on this address space" >&2
                exit 1
            fi
            if exists "${name}"; then
                echo "Error response from daemon: network with name ${name} already exists" >&2
                exit 1
            fi
            echo "${name}|${project}|${subnet}|${domain}" >> "${nets}"
            echo "netid-${name}"
            exit 0
            ;;
        connect)
            alias=""
            while [[ "$1" == --* ]]; do
                [[ "$1" == "--alias" ]] && alias="$2"
                shift 2
            done
            [[ -e "${dir}/proxy_exists" ]] || exit 1
            if grep -qxF "$1" "${dir}/connect_fail"; then
                echo "Error response from daemon: simulated connection refusal" >&2
                exit 1
            fi
            grep -q "^$1|" "${conn}" || echo "$1|${alias}" >> "${conn}"
            exit 0
            ;;
        disconnect)
            grep -v "^$1|" "${conn}" > "${conn}.new"; mv "${conn}.new" "${conn}"
            exit 0
            ;;
        rm)
            [[ -e "${dir}/rm_fail" ]] && { echo "Error response from daemon: network has active endpoints" >&2; exit 1; }
            grep -v "^$1|" "${nets}" > "${nets}.new"; mv "${nets}.new" "${nets}"
            exit 0
            ;;
    esac
    exit 0
fi
exit 0
MOCKEOF
    chmod +x "${MOCK_BIN}/docker"
}

# Container de projeto numa rede, com IP (o DNS do proxy resolve
# <container>.<rede> para ele, como o Docker faz).
netsim_add_container() {
    printf '%s|%s|%s\n' "$1" "$2" "$3" >> "${NETSIM_DIR}/containers"
}

# Forca o que o proxy resolve para <host>: um IP (ou varios, separados por
# virgula), ou "none" (nao resolve).
netsim_resolve_override() {
    printf '%s|%s\n' "$1" "$2" >> "${NETSIM_DIR}/resolve_override"
}

netsim_add_network() {
    printf '%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}" >> "${NETSIM_DIR}/nets"
}

netsim_connect() {
    printf '%s|%s\n' "$1" "${2:-}" >> "${NETSIM_DIR}/connected"
}

netsim_fail_subnet() {
    echo "$1" >> "${NETSIM_DIR}/fail"
}

# O `network rm` passa a falhar (rede com endpoints ativos).
netsim_fail_rm() {
    : > "${NETSIM_DIR}/rm_fail"
}

netsim_fail_connect() {
    printf '%s\n' "$1" >> "${NETSIM_DIR}/connect_fail"
}

# Faz `docker inspect` do objeto falhar por transporte, distinto da mensagem
# canonica de objeto ausente que o simulador devolve por padrao.
netsim_fail_inspect() {
    printf '%s\n' "$1" >> "${NETSIM_DIR}/inspect_fail"
}

netsim_remove_proxy() {
    rm -f "${NETSIM_DIR}/proxy_exists"
}

netsim_has_network() {
    awk -F'|' -v n="$1" '$1==n {f=1} END {exit !f}' "${NETSIM_DIR}/nets"
}

netsim_is_connected() {
    grep -q "^$1|" "${NETSIM_DIR}/connected"
}

# Subnet de uma rede do simulador (vazio se nao existe).
netsim_subnet() {
    awk -F'|' -v n="$1" '$1==n {print $3; exit}' "${NETSIM_DIR}/nets"
}
