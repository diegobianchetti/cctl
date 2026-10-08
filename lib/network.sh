#!/bin/bash
# lib/network.sh — Rede das instalacoes (uma rede Docker por projeto)
#
# Modelo, em poucas palavras:
#   - O cctl cria a rede de cada projeto ANTES de subir o projeto. O compose
#     do template so a usa (como rede "external").
#   - Cada projeto tem a sua rede (<projeto>_net). Ninguem compartilha rede;
#     so o nginx-proxy entra na rede de todos.
#   - A faixa (subnet) de cada rede sai de um range global, definido em
#     cctl.conf (CCTL_NETWORK_RANGE + CCTL_NETWORK_PREFIX), sempre privado.
#   - Como o "docker compose down" nao apaga rede "external", a rede (e a
#     faixa) continua reservada enquanto o projeto esta parado. So
#     clear-all/destroy apagam a rede.
#
# Este arquivo tem tres blocos:
#   1. Aritmetica de faixas IPv4 em Bash puro (sem ipcalc/python)
#   2. Descobrir o que ja esta em uso (redes Docker, rotas do host, inventario)
#      e escolher a proxima faixa livre
#   3. Operacoes de rede: criar, reaproveitar, religar, remover, auditar

# ---------------------------------------------------------------------------
# 1. Aritmetica de faixas IPv4
# ---------------------------------------------------------------------------

# Converte "a.b.c.d" em inteiro (0..4294967295). Retorna 1 se nao for IPv4.
network_ip_to_int() {
    local ip="$1"
    local re='^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$'
    [[ "${ip}" =~ ${re} ]] || return 1

    local a=$((10#${BASH_REMATCH[1]})) b=$((10#${BASH_REMATCH[2]}))
    local c=$((10#${BASH_REMATCH[3]})) d=$((10#${BASH_REMATCH[4]}))
    (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1

    echo $(( (a << 24) | (b << 16) | (c << 8) | d ))
}

# Converte inteiro em "a.b.c.d".
network_int_to_ip() {
    local n="$1"
    printf '%d.%d.%d.%d\n' $(( (n >> 24) & 255 )) $(( (n >> 16) & 255 )) \
        $(( (n >> 8) & 255 )) $(( n & 255 ))
}

# Retorna 0 se o argumento for um CIDR IPv4 valido ("10.240.0.0/16").
network_cidr_valid() {
    local cidr="$1"
    local re='^([0-9.]+)/([0-9]{1,2})$'
    [[ "${cidr}" =~ ${re} ]] || return 1
    # copia antes: network_ip_to_int tambem usa regex e sobrescreve BASH_REMATCH
    local ip="${BASH_REMATCH[1]}" prefix="${BASH_REMATCH[2]}"
    network_ip_to_int "${ip}" >/dev/null || return 1
    (( 10#${prefix} <= 32 ))
}

# Calcula o primeiro e o ultimo endereco da faixa e deixa em _NET_FIRST e
# _NET_LAST (variaveis globais). Existe para os laços do alocador evitarem um
# subshell por comparacao. Retorna 1 se o CIDR for invalido.
_network_bounds() {
    local cidr="$1"
    network_cidr_valid "${cidr}" || return 1

    local n prefix size
    n=$(network_ip_to_int "${cidr%/*}")
    prefix=$((10#${cidr#*/}))
    size=$(( 1 << (32 - prefix) ))

    _NET_FIRST=$(( n & ~(size - 1) & 0xFFFFFFFF ))
    _NET_LAST=$(( _NET_FIRST + size - 1 ))
}

# Retorna 0 se o CIDR esta "alinhado" (o endereco e o inicio da faixa).
# "10.240.1.0/24" e alinhado; "10.240.1.5/24" nao e.
network_cidr_aligned() {
    local cidr="$1"
    _network_bounds "${cidr}" || return 1
    [[ "$(network_ip_to_int "${cidr%/*}")" -eq "${_NET_FIRST}" ]]
}

# Retorna 0 se as duas faixas tem algum endereco em comum (qualquer tamanho:
# iguais, uma dentro da outra ou parcialmente cruzadas).
network_cidr_overlap() {
    _network_bounds "$1" || return 1
    local a_first="${_NET_FIRST}" a_last="${_NET_LAST}"
    _network_bounds "$2" || return 1
    (( a_first <= _NET_LAST && _NET_FIRST <= a_last ))
}

# Retorna 0 se a faixa interna esta INTEIRA dentro da externa.
# Uso: network_cidr_contains <externa> <interna>
network_cidr_contains() {
    _network_bounds "$1" || return 1
    local o_first="${_NET_FIRST}" o_last="${_NET_LAST}"
    _network_bounds "$2" || return 1
    (( _NET_FIRST >= o_first && _NET_LAST <= o_last ))
}

# Retorna 0 se a faixa esta inteira dentro de um dos tres blocos privados
# da RFC 1918: 10.0.0.0/8, 172.16.0.0/12 ou 192.168.0.0/16. Uma faixa que
# cruza a borda (ex.: 172.32.0.0/16, que ja e publica) nao conta.
network_cidr_in_rfc1918() {
    local cidr="$1" block
    for block in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16; do
        network_cidr_contains "${block}" "${cidr}" && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# 2. O que ja esta em uso e proxima faixa livre
# ---------------------------------------------------------------------------

# Valida CCTL_NETWORK_RANGE e CCTL_NETWORK_PREFIX (formato e coerencia entre
# os dois). Nao olha o que existe no host — isso e o pre-flight
# (validate_network_range, lib/validate.sh).
network_validate_config() {
    local range="${CCTL_NETWORK_RANGE:-}"
    local prefix="${CCTL_NETWORK_PREFIX:-}"

    if ! network_cidr_valid "${range}"; then
        log_error "CCTL_NETWORK_RANGE invalido: '${range}'. Use um CIDR IPv4, ex.: 10.240.0.0/16 (veja cctl.conf)."
        return 1
    fi
    if ! network_cidr_aligned "${range}"; then
        log_error "CCTL_NETWORK_RANGE '${range}' nao comeca no inicio da faixa. Use o endereco de rede, ex.: 10.240.0.0/16."
        return 1
    fi
    if [[ ! "${prefix}" =~ ^[0-9]{1,2}$ ]]; then
        log_error "CCTL_NETWORK_PREFIX invalido: '${prefix}'. Use um numero entre o prefixo do range e 30, ex.: 24 (veja cctl.conf)."
        return 1
    fi
    if (( 10#${prefix} < 10#${range#*/} || 10#${prefix} > 30 )); then
        log_error "CCTL_NETWORK_PREFIX=${prefix} fora do permitido: tem de ser >= ${range#*/} (prefixo do range ${range}) e <= 30."
        return 1
    fi
    return 0
}

# Faixas das redes Docker que ja existem (de qualquer tamanho).
# Saida: uma linha por faixa, "CIDR<TAB>origem". So IPv4.
network_docker_ranges() {
    local line name subnet
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        # cada linha: "<nome-da-rede> <subnet> <subnet> ..."
        read -r name line <<< "${line}"
        for subnet in ${line}; do
            network_cidr_valid "${subnet}" || continue
            printf '%s\trede Docker %s\n' "${subnet}" "${name}"
        done
    done < <(docker network ls -q 2>/dev/null \
        | xargs -r docker network inspect \
            --format '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null)
}

# Rotas IPv4 do host que NAO sao de bridge Docker (LAN, VPN, libvirt...).
# Le TODAS as tabelas de roteamento ("table all"), para enxergar tambem VPN
# com policy routing (rotas fora da tabela main). Ignora:
#   - a rota "default";
#   - rotas com tipo na frente (local, broadcast, unreachable, multicast...):
#     nao sao faixas de rede alcancaveis; so entram linhas que comecam pelo
#     destino (um endereco);
#   - as bridges do Docker de verdade: docker0 e br-<12 hex> (essas ja entram
#     em network_docker_ranges, com o nome da rede). Uma bridge com outro nome
#     (ex.: br-lan) e rede do operador e CONTA como rota do host.
# Saida: "CIDR<TAB>origem".
network_host_routes() {
    local dest dev
    while read -r dest dev; do
        [[ "${dest}" =~ ^[0-9] ]] || continue
        [[ "${dest}" == */* ]] || dest="${dest}/32"
        network_cidr_valid "${dest}" || continue
        printf '%s\trota do host (dev %s)\n' "${dest}" "${dev:-?}"
    done < <(ip -4 route show table all 2>/dev/null | awk '
        $1 == "default" { next }
        {
            dev = ""
            for (i = 1; i < NF; i++) if ($i == "dev") dev = $(i + 1)
            if (dev == "docker0") next
            if (length(dev) == 15 && dev ~ /^br-[0-9a-f]+$/) next
            print $1, dev
        }')
}

# Faixas que o proprio Docker usa para criar redes sozinho (as "automaticas").
# Se o range do cctl cair em cima delas, uma rede criada sem --subnet por
# qualquer outro projeto pode ficar com a mesma faixa de um projeto do cctl.
#   - Com "default-address-pools" no daemon.json (DOCKER_DAEMON_JSON, em
#     cctl.conf), vale o que esta la (lido so com sed/grep, sem jq).
#   - Sem isso, vale o default embutido do Docker (documentado em
#     "Docker daemon configuration", chave default-address-pools):
#     172.16.0.0/12 (redes automaticas /16) e 192.168.0.0/16 (redes /20).
#     Aqui o bloco 172.x e escrito como 172.17.0.0/16 ate 172.31.0.0/16
#     (a 172.16.0.0/16 nao entra nas automaticas, que comecam em 172.17).
#   - Se o daemon.json existe mas nao da para le-lo, ou tem a chave
#     default-address-pools e o parse nao extraiu nada, cai no default COM AVISO.
# Saida: um CIDR por linha.
network_docker_pools() {
    local file="${DOCKER_DAEMON_JSON:-}"
    local pools=""

    if [[ -n "${file}" && -e "${file}" && ! -r "${file}" ]]; then
        log_warn "Nao consegui ler ${file}: usando o pool padrao do Docker para conferir o range de rede."
    elif [[ -n "${file}" && -r "${file}" ]]; then
        pools=$(tr -d '\n' < "${file}" \
            | sed -n 's/.*"default-address-pools"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/p' \
            | grep -o '"base"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | sed 's/.*:[[:space:]]*"\(.*\)"/\1/') || pools=""
        if [[ -z "${pools}" ]] && grep -q '"default-address-pools"' "${file}"; then
            log_warn "${file} tem default-address-pools mas nao consegui extrair as faixas: usando o pool padrao do Docker para conferir o range de rede."
        fi
    fi

    if [[ -n "${pools}" ]]; then
        printf '%s\n' "${pools}"
        return 0
    fi

    local i
    for i in {17..31}; do
        echo "172.${i}.0.0/16"
    done
    echo "192.168.0.0/16"
}

# Faixas reservadas no inventario por OUTROS projetos (inclusive os parados,
# cuja rede pode nao existir agora). Saida: "CIDR<TAB>origem".
# Uso: network_inventory_ranges [projeto-a-ignorar]
network_inventory_ranges() {
    local skip="${1:-}"
    local name status net subnet
    while IFS=$'\t' read -r name status net subnet; do
        [[ -n "${name}" && -n "${subnet}" ]] || continue
        [[ "${name}" == "${skip}" ]] && continue
        network_cidr_valid "${subnet}" || continue
        printf '%s\treservada pelo projeto %s no inventario\n' "${subnet}" "${name}"
    done < <(inventory_network_list)
}

# Tudo que uma nova subnet tem de evitar. Uso: network_used_ranges [projeto]
network_used_ranges() {
    local project="${1:-}"
    network_docker_ranges
    network_host_routes
    network_inventory_ranges "${project}"
}

# Faixas que conflitam com <subnet>. Imprime "origem" (uma por linha); sem
# saida = livre. Uso: network_find_conflicts <subnet> [projeto-a-ignorar]
network_find_conflicts() {
    local subnet="$1" project="${2:-}"
    local cidr origin
    while IFS=$'\t' read -r cidr origin; do
        [[ -n "${cidr}" ]] || continue
        if network_cidr_overlap "${subnet}" "${cidr}"; then
            printf '%s (%s)\n' "${origin}" "${cidr}"
        fi
    done < <(network_used_ranges "${project}")
}

# Proxima subnet livre do range, andando em passos do tamanho de
# CCTL_NETWORK_PREFIX. Evita redes Docker de qualquer tamanho, rotas do host
# e faixas reservadas por outros projetos no inventario. Imprime a faixa;
# retorna 1 (com erro) quando o range acabou.
# Uso: network_allocate_subnet [projeto] [faixa-ja-tentada...]
network_allocate_subnet() {
    local project="${1:-}"
    [[ $# -gt 0 ]] && shift
    network_validate_config || return 1

    local range="${CCTL_NETWORK_RANGE}" prefix=$((10#${CCTL_NETWORK_PREFIX}))
    _network_bounds "${range}"
    local r_first="${_NET_FIRST}" r_last="${_NET_LAST}"
    local step=$(( 1 << (32 - prefix) ))

    # Converte tudo que ja esta em uso para pares [inicio, fim] uma unica vez,
    # para o laco de candidatos so comparar inteiros.
    local -a u_first=() u_last=()
    local cidr origin
    while IFS=$'\t' read -r cidr origin; do
        [[ -n "${cidr}" ]] || continue
        _network_bounds "${cidr}" || continue
        u_first+=("${_NET_FIRST}")
        u_last+=("${_NET_LAST}")
    done < <(network_used_ranges "${project}")
    for cidr in "$@"; do
        _network_bounds "${cidr}" || continue
        u_first+=("${_NET_FIRST}")
        u_last+=("${_NET_LAST}")
    done

    local cur end i free
    for (( cur = r_first; cur + step - 1 <= r_last; cur += step )); do
        end=$(( cur + step - 1 ))
        free=true
        for i in "${!u_first[@]}"; do
            if (( cur <= u_last[i] && u_first[i] <= end )); then
                free=false
                break
            fi
        done
        if [[ "${free}" == "true" ]]; then
            echo "$(network_int_to_ip "${cur}")/${prefix}"
            log_debug "Subnet sugerida: $(network_int_to_ip "${cur}")/${prefix}"
            return 0
        fi
    done

    log_error "Nenhuma subnet /${prefix} livre no range ${range}: o range esta esgotado. Aumente CCTL_NETWORK_RANGE em cctl.conf (ou apague projetos que nao usa mais)."
    return 1
}

# Confere uma faixa digitada pelo usuario. Retorna 0 se serve; senao retorna
# 1 e deixa o motivo (em portugues, pronto para mostrar) em NETWORK_REJECT_REASON.
# Uso: network_check_candidate <subnet> [projeto]
network_check_candidate() {
    local subnet="$1" project="${2:-}"
    NETWORK_REJECT_REASON=""

    if ! network_cidr_valid "${subnet}"; then
        NETWORK_REJECT_REASON="'${subnet}' nao e um CIDR IPv4 valido (exemplo: 10.240.3.0/24)."
        return 1
    fi
    if (( 10#${subnet#*/} != 10#${CCTL_NETWORK_PREFIX} )); then
        NETWORK_REJECT_REASON="a faixa tem de ser /${CCTL_NETWORK_PREFIX} (CCTL_NETWORK_PREFIX), nao /${subnet#*/}."
        return 1
    fi
    if ! network_cidr_aligned "${subnet}"; then
        NETWORK_REJECT_REASON="'${subnet}' nao comeca no inicio da faixa (use o endereco de rede)."
        return 1
    fi
    if ! network_cidr_contains "${CCTL_NETWORK_RANGE}" "${subnet}"; then
        NETWORK_REJECT_REASON="'${subnet}' esta fora do range do cctl (${CCTL_NETWORK_RANGE})."
        return 1
    fi

    local conflicts
    conflicts=$(network_find_conflicts "${subnet}" "${project}")
    if [[ -n "${conflicts}" ]]; then
        NETWORK_REJECT_REASON="'${subnet}' ja esta em uso: $(head -n1 <<< "${conflicts}")."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 3. Operacoes de rede
# ---------------------------------------------------------------------------

# Nome da rede de um projeto.
network_name_for_project() {
    echo "${1}_net"
}

# Retorna 0 se a rede Docker existe.
network_exists() {
    docker network inspect "$1" >/dev/null 2>&1
}

# Subnet IPv4 de uma rede existente.
network_subnet_of() {
    docker network inspect "$1" \
        --format '{{range .IPAM.Config}}{{.Subnet}}{{"\n"}}{{end}}' 2>/dev/null \
        | grep -v ':' | head -n1
}

# Valor de um label da rede (vazio se nao tiver).
# Uso: network_label_of <rede> <label>
network_label_of() {
    docker network inspect "$1" --format "{{index .Labels \"$2\"}}" 2>/dev/null
}

# Cria a rede do projeto com a faixa e os labels do cctl. Erros do Docker
# saem no stderr (quem chama decide se e "faixa tomada" ou outra falha).
# Uso: network_create <rede> <subnet> <projeto> [dominio]
network_create() {
    local net="$1" subnet="$2" project="$3" domain="${4:-}"
    docker network create --driver bridge --subnet "${subnet}" \
        --label "io.cctl.managed=true" \
        --label "io.cctl.project=${project}" \
        --label "io.cctl.domain=${domain}" \
        "${net}" >/dev/null
}

# Forma canonica de um CIDR valido: zeros a esquerda saem ("10.240.03.0/24"
# vira "10.240.3.0/24"). Se o argumento nao for um CIDR valido, devolve-o igual.
network_cidr_normalize() {
    local cidr="$1"
    if ! network_cidr_valid "${cidr}"; then
        printf '%s\n' "${cidr}"
        return 0
    fi
    printf '%s/%d\n' "$(network_int_to_ip "$(network_ip_to_int "${cidr%/*}")")" "$((10#${cidr#*/}))"
}

# Mostra a faixa sugerida e pergunta (so com terminal) qual usar. Enter aceita.
# Uma faixa digitada passa pelas mesmas regras da sugestao; se nao passar,
# explica o motivo e pergunta de novo. Resultado em NETWORK_CHOSEN_SUBNET
# (variavel global — este fluxo escreve na tela, entao nao da para devolver
# por stdout). Uso: network_prompt_subnet <sugestao> <projeto>
network_prompt_subnet() {
    local suggestion="$1" project="$2" answer
    NETWORK_CHOSEN_SUBNET="${suggestion}"

    echo -e "  Subnet sugerida para ${CYAN}${project}${RESET}: ${CYAN}${suggestion}${RESET}"
    while :; do
        printf '  Enter aceita; ou digite outra faixa /%s dentro de %s: ' \
            "${CCTL_NETWORK_PREFIX}" "${CCTL_NETWORK_RANGE}" >&2
        # fim de entrada (EOF) = aceita a sugestao
        read -r answer || answer=""
        if [[ -z "${answer}" ]]; then
            NETWORK_CHOSEN_SUBNET="${suggestion}"
            return 0
        fi
        answer=$(network_cidr_normalize "${answer}")
        if network_check_candidate "${answer}" "${project}"; then
            NETWORK_CHOSEN_SUBNET="${answer}"
            return 0
        fi
        msg_warn "Faixa recusada: ${NETWORK_REJECT_REASON}"
    done
}

# Indica se ha um terminal para perguntar. Isolado em funcao para os testes
# conseguirem simular os dois casos.
_network_is_interactive() {
    [[ -t 0 ]]
}

# Garante a rede do projeto no install e grava o resultado no .env:
#   1. a rede <projeto>_net ja existe e e deste projeto -> reaproveita (a
#      subnet nao muda a cada reinstall);
#   2. senao, sugere a proxima faixa livre (com terminal, o usuario confirma
#      ou digita outra), cria a rede e grava o resultado.
# Se o Docker recusar a faixa por sobreposicao (outro install ao mesmo tempo
# pegou a mesma), tenta a proxima livre, ate 10 vezes.
# Variaveis lidas: COMPOSE_PROJECT_NAME, DOMAIN_NAME.
network_provision_for_install() {
    local project="${COMPOSE_PROJECT_NAME:-}"
    if [[ -z "${project}" ]]; then
        log_error "COMPOSE_PROJECT_NAME nao definido"
        return 1
    fi

    local net subnet
    net=$(network_name_for_project "${project}")

    if network_exists "${net}"; then
        local owner
        owner=$(network_label_of "${net}" "io.cctl.project") || owner=""
        if [[ "${owner}" != "${project}" ]]; then
            log_error "Ja existe uma rede Docker chamada '${net}' que nao pertence a este projeto (sem o label io.cctl.project=${project}). Remova essa rede ou escolha outro nome de projeto."
            return 1
        fi
        subnet=$(network_subnet_of "${net}")
        if [[ -z "${subnet}" ]]; then
            log_error "A rede ${net} existe mas nao tem subnet IPv4 — nao da para reaproveitar."
            return 1
        fi
        log_success "Rede ${net} ja existe (subnet ${subnet}) — reaproveitando"
    else
        subnet=$(network_allocate_subnet "${project}") || return 1

        if _network_is_interactive; then
            network_prompt_subnet "${subnet}" "${project}"
            subnet="${NETWORK_CHOSEN_SUBNET}"
        else
            msg_info "Sem terminal: usando a subnet sugerida ${subnet}"
        fi

        local -a tried=()
        local err attempt=0 max_attempts=10
        while :; do
            if err=$(network_create "${net}" "${subnet}" "${project}" "${DOMAIN_NAME:-}" 2>&1); then
                break
            fi
            if [[ "${err,,}" == *overlap* ]]; then
                tried+=("${subnet}")
                attempt=$((attempt + 1))
                if (( attempt >= max_attempts )); then
                    log_error "Nao consegui reservar uma faixa para ${net} em ${max_attempts} tentativas (o Docker recusou todas por sobreposicao)."
                    return 1
                fi
                log_warn "O Docker recusou ${subnet} (sobreposicao com outra rede criada ao mesmo tempo). Tentando a proxima faixa livre..."
                subnet=$(network_allocate_subnet "${project}" "${tried[@]}") || return 1
                continue
            fi
            log_error "Falha ao criar a rede ${net}: ${err}"
            return 1
        done
        log_success "Rede ${net} criada (subnet ${subnet})"
    fi

    env_set_var "CCTL_PROJECT_NETWORK" "${net}" || return 1
    env_set_var "COMPOSE_PROJECT_SUBNET" "${subnet}" || return 1

    # Reserva tambem no inventario quando o projeto ja tem registro (ex. via
    # cctl init). Sem registro, o install grava os dois campos ao final.
    # Uma falha de escrita em registro existente interrompe o fluxo: sem a
    # reserva, uma rede removida depois poderia ter a faixa reutilizada.
    network_sync_inventory_reservation "${project}" "${net}" "${subnet}" || return 1
    return 0
}

# Grava a reserva no inventario somente quando ja ha um registro do projeto.
# `cctl install` tambem aceita projetos criados sem `cctl init`; nesse caso o
# registro ainda nao existe e inventory_mark_installed o cria ao final. Esse e
# o unico no-op tolerado: se o registro existe, qualquer falha de leitura ou
# escrita e real e precisa voltar ao chamador.
network_sync_inventory_reservation() {
    local project="$1" net="$2" subnet="$3" file
    file="$(inventory_file_for "${project}")" || return 1
    [[ -e "${file}" ]] || return 0

    if ! inventory_set_network "${project}" "${net}" "${subnet}"; then
        log_error "Falha ao gravar a reserva da rede ${net} (${subnet}) no inventario. Corrija o inventario e repita a operacao."
        return 1
    fi
    return 0
}

# Garante a rede do projeto no "cctl up": se sumiu (ex.: alguem rodou
# docker network prune com o projeto parado e o proxy desligado), recria com a
# MESMA faixa e os mesmos labels. Se a faixa foi tomada por outra coisa, recusa
# — nunca escolhe outra faixa sozinho, porque os containers e o vhost
# dependem do endereco. Em seguida garante o proxy conectado.
network_ensure_for_up() {
    local net="${CCTL_PROJECT_NETWORK:-}" subnet="${COMPOSE_PROJECT_SUBNET:-}"
    local project="${COMPOSE_PROJECT_NAME:-}"

    if [[ -z "${net}" || -z "${subnet}" ]]; then
        log_error "Esta instancia nao tem rede gerenciada pelo cctl (CCTL_PROJECT_NETWORK/COMPOSE_PROJECT_SUBNET ausentes no .env). Ela foi instalada por uma versao anterior do cctl: faca 'cctl destroy' e instale de novo."
        return 1
    fi

    if ! network_exists "${net}"; then
        local conflicts
        conflicts=$(network_find_conflicts "${subnet}" "${project}")
        if [[ -n "${conflicts}" ]]; then
            log_error "A rede ${net} nao existe mais e a faixa dela (${subnet}) foi tomada por:"
            sed 's/^/    - /' <<< "${conflicts}" >&2
            log_error "O cctl nao troca a faixa de um projeto sozinho. Libere essa faixa (remova a rede ou a rota que a usa) e rode 'cctl up' de novo."
            return 1
        fi

        msg_step "REDE" "Recriando a rede ${net} com a mesma faixa (${subnet})..."
        local err
        if ! err=$(network_create "${net}" "${subnet}" "${project}" "${DOMAIN_NAME:-}" 2>&1); then
            log_error "Falha ao recriar a rede ${net} (${subnet}): ${err}"
            return 1
        fi
        log_success "Rede ${net} recriada"
        # Devolve a reserva da faixa ao inventario (o clear-all a tinha
        # limpado). Registro ausente e legado tolerado; falha em registro
        # existente interrompe o up para nao ocultar uma reserva perdida.
        network_sync_inventory_reservation "${project}" "${net}" "${subnet}" || return 1
    else
        # A rede existe: divergencia so avisa (nunca bloqueia), mas a reserva
        # e reconciliada com a subnet real (retomada apos falha de reserva).
        local live_subnet live_owner
        live_subnet=$(network_subnet_of "${net}") || live_subnet=""
        live_owner=$(network_label_of "${net}" "io.cctl.project") || live_owner=""
        if [[ -n "${live_subnet}" && "${live_subnet}" != "${subnet}" ]]; then
            log_warn "A rede ${net} existe com a subnet ${live_subnet}, mas o .env diz ${subnet}. Confira o .env (COMPOSE_PROJECT_SUBNET)."
        fi
        if [[ "${live_owner}" != "${project}" ]]; then
            log_warn "A rede ${net} existe mas o label io.cctl.project dela e '${live_owner:-vazio}', nao '${project}'. Confira se ela e mesmo deste projeto."
        fi
        network_sync_inventory_reservation "${project}" "${net}" "${live_subnet:-${subnet}}" || return 1
    fi

    network_ensure_nginx_connected "${net}" "${DOMAIN_NAME:-}" || return 1
    return 0
}

# Retorna 0 se o nginx-proxy ja esta conectado a rede.
network_proxy_connected() {
    local net="$1"
    local container="${NGINX_CONTAINER_NAME:-nginx-proxy}"
    # captura antes do grep: "grep -q" fecha o pipe cedo e, com pipefail,
    # isso derrubaria o resultado
    local attached
    attached=$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' \
        "${container}" 2>/dev/null) || return 1
    grep -qxF "${net}" <<< "${attached}"
}

# Conecta o container nginx-proxy a rede do projeto, com alias = dominio
# (o alias e o proprio dominio do projeto dentro dessa rede).
# Uso: network_connect_nginx <rede> [alias]   (alias default: DOMAIN_NAME)
network_connect_nginx() {
    local project_network="$1"
    local alias_name="${2:-${DOMAIN_NAME:-}}"
    local container="${NGINX_CONTAINER_NAME:-nginx-proxy}"
    local alias_args=()
    [[ -n "${alias_name}" ]] && alias_args=(--alias "${alias_name}")

    docker network connect "${alias_args[@]}" "${project_network}" "${container}" 2>/dev/null || true

    # A politica e deliberada: falha de conexao com proxy existente interrompe
    # o chamador; proxy ausente so avisa. A pre-condicao de quem precisa do
    # proxy (_nginx_proxy_require_container) e responsavel por recusar sua falta.
    # O rc do connect nao decide nada: "ja conectado" tambem falha, entao a
    # verdade e a lista de redes do proprio proxy.
    if network_proxy_connected "${project_network}"; then
        log_success "Nginx conectado a rede ${project_network}"
        return 0
    fi
    if docker inspect "${container}" >/dev/null 2>&1; then
        log_error "O nginx-proxy existe, mas nao foi conectado a rede ${project_network}. Confira o Docker e a rede; rode 'cctl proxy up' depois de corrigir."
        return 1
    fi
    log_warn "O nginx-proxy nao existe; a conexao com a rede ${project_network} sera tentada quando o proxy for iniciado."
    return 0
}

# Como network_connect_nginx, mas so conecta se ainda nao estiver conectado
# (evita aviso em re-execucoes). Uso: network_ensure_nginx_connected <rede> [alias]
network_ensure_nginx_connected() {
    local project_network="$1" alias_name="${2:-}"
    if network_proxy_connected "${project_network}"; then
        log_debug "nginx-proxy ja esta conectado a rede ${project_network}"
        return 0
    fi
    network_connect_nginx "${project_network}" "${alias_name}"
}

# Desconecta o container nginx-proxy de uma rede (usado so ao apagar a rede).
network_disconnect_nginx() {
    local project_network="$1"
    local container="${NGINX_CONTAINER_NAME:-nginx-proxy}"

    if docker network disconnect "${project_network}" "${container}" 2>/dev/null; then
        log_success "Nginx desconectado da rede ${project_network}"
    else
        log_warn "Nginx nao estava conectado a rede ${project_network}"
    fi
}

# Apaga a rede do projeto: tira o proxy dela e remove. Usado por clear-all
# (e, por consequencia, destroy) — e o UNICO caminho que apaga a rede.
# Uso: network_remove_project_network <rede>
network_remove_project_network() {
    local net="$1"
    if ! network_exists "${net}"; then
        log_warn "Rede ${net} ja nao existe"
        return 0
    fi

    network_disconnect_nginx "${net}"
    if docker network rm "${net}" >/dev/null 2>&1; then
        log_success "Rede ${net} removida"
    else
        log_warn "Rede ${net} nao pode ser removida agora (ainda em uso por outro container?)"
        return 1
    fi
}

# Reconecta o nginx-proxy a toda rede gerenciada pelo cctl em que ele nao
# esteja (caso o container do proxy tenha sido recriado). O alias de cada
# rede e o dominio do projeto no INVENTARIO (o install o atualiza a cada
# reinstall); o label io.cctl.domain da rede so serve de reserva, porque label
# de rede nao muda depois de criada. Chamado por "cctl proxy up".
network_reconnect_proxy() {
    local net domain rc=0
    while IFS= read -r net; do
        [[ -n "${net}" ]] || continue
        if network_proxy_connected "${net}"; then
            continue
        fi
        domain=$(inventory_domain_for_network "${net}") || domain=""
        [[ -n "${domain}" ]] || domain=$(network_label_of "${net}" "io.cctl.domain") || domain=""
        network_connect_nginx "${net}" "${domain}" || rc=1
    done < <(docker network ls --filter "label=io.cctl.managed=true" --format '{{.Name}}' 2>/dev/null)
    return "${rc}"
}

# Confere, de dentro do nginx-proxy, que o alvo "<container>.<rede>" resolve
# para o IP do container DESTE projeto nessa rede. Falha (rc 1, com mensagem
# que diz o alvo, o que resolveu e o que era esperado) se nao resolve, se
# resolve para outro IP ou se o container nao esta na rede.
# Uso: network_check_target <host> <rede>
network_check_target() {
    local host="$1" net="$2"
    local proxy="${NGINX_CONTAINER_NAME:-nginx-proxy}"
    local container="${host%".${net}"}"

    if [[ "${container}" == "${host}" ]]; then
        log_error "O alvo '${host}' nao termina em .${net}: nao esta qualificado pela rede do projeto."
        return 1
    fi

    local expected
    expected=$(docker inspect -f "{{with index .NetworkSettings.Networks \"${net}\"}}{{.IPAddress}}{{end}}" "${container}" 2>/dev/null) || expected=""
    if [[ -z "${expected}" ]]; then
        log_error "O container '${container}' (alvo '${host}') nao existe ou nao esta na rede ${net}."
        return 1
    fi

    # getent ahostsv4 devolve uma linha "IP STREAM nome" por endereco IPv4;
    # considera TODAS: so passa se o unico IP for o do container.
    local resolved
    resolved=$(docker exec "${proxy}" getent ahostsv4 "${host}" 2>/dev/null | awk '{print $1}' | sort -u) || resolved=""
    if [[ -z "${resolved}" ]]; then
        log_error "De dentro do ${proxy}, o alvo '${host}' NAO resolve (esperado: ${expected}, o container ${container}). Confira se o proxy esta conectado a rede ${net} ('cctl proxy up')."
        return 1
    fi
    if [[ "${resolved}" != "${expected}" ]]; then
        log_error "De dentro do ${proxy}, o alvo '${host}' resolve para $(tr '\n' ' ' <<< "${resolved}")(esperado so ${expected}, o container ${container} na rede ${net})."
        return 1
    fi

    log_success "Alvo ${host} confere: resolve so para o container ${container} (${expected})"
    return 0
}

# Confere todos os "set $target" de um vhost ja publicado (ver
# network_check_target). Vhost sem alvo (ex.: o HTTP temporario do ACME) passa.
# Uso: network_check_vhost_targets <arquivo-do-vhost> <rede>
network_check_vhost_targets() {
    local vhost="$1" net="$2"
    local content host rc=0
    content="$(core_priv_run cat "${vhost}")" || {
        log_error "Falha ao ler o vhost ${vhost} para conferir os alvos"
        return 1
    }

    while IFS= read -r host; do
        [[ -n "${host}" ]] || continue
        network_check_target "${host}" "${net}" || rc=1
    done < <(vhost_target_hosts "${content}")

    if [[ "${rc}" -eq 0 ]]; then
        log_debug "Alvos do vhost ${vhost} conferidos"
    fi
    return "${rc}"
}

# Compara as redes gerenciadas (labels io.cctl.*) com o inventario. Nao
# apaga nada. Saida, uma linha TSV por item:
#   OK          <projeto>  <rede>  <subnet-real>       instancia com rede coerente
#   DIVERGENT   <projeto>  <rede>  <subnet-real> <dono-real> <subnet-registrada>
#                                                   rede existe, mas dono ou subnet divergem
#   MISSING     <projeto>  <rede>  <subnet-registrada> inventario aponta para rede que nao existe
#   NONE        <projeto>  -       -                   instalada sem rede registrada (versao antiga)
#   ORPHAN      <projeto>  <rede>  <subnet-real>       rede gerenciada sem instancia no inventario
#   NOPROJECT   -         <rede>  <subnet-real>       rede gerenciada sem o label io.cctl.project
network_audit_lines() {
    local -A managed_subnet=() managed_project=()
    local name project subnets
    while IFS='|' read -r name project subnets; do
        [[ -n "${name}" ]] || continue
        managed_project["${name}"]="${project}"
        managed_subnet["${name}"]="${subnets%% *}"
    done < <(docker network ls -q --filter "label=io.cctl.managed=true" 2>/dev/null \
        | xargs -r docker network inspect \
            --format '{{.Name}}|{{index .Labels "io.cctl.project"}}|{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null)

    local -A known_net=() known_project=()
    local status net subnet
    while IFS=$'\t' read -r name status net subnet; do
        [[ -n "${name}" ]] || continue
        known_project["${name}"]=1
        if [[ -n "${net}" ]]; then
            known_net["${net}"]=1
            if [[ -n "${managed_project[${net}]+x}" ]]; then
                if [[ "${managed_project[${net}]}" != "${name}" || "${managed_subnet[${net}]}" != "${subnet}" ]]; then
                    printf 'DIVERGENT\t%s\t%s\t%s\t%s\t%s\n' \
                        "${name}" "${net}" "${managed_subnet[${net}]:--}" \
                        "${managed_project[${net}]:-vazio}" "${subnet:--}"
                else
                    printf 'OK\t%s\t%s\t%s\n' "${name}" "${net}" "${managed_subnet[${net}]:--}"
                fi
            else
                printf 'MISSING\t%s\t%s\t%s\n' "${name}" "${net}" "${subnet:--}"
            fi
        elif [[ "${status}" == "installed" ]]; then
            printf 'NONE\t%s\t-\t-\n' "${name}"
        fi
    done < <(inventory_network_list)

    for net in "${!managed_project[@]}"; do
        [[ -n "${known_net[${net}]+x}" ]] && continue
        if [[ -z "${managed_project[${net}]}" ]]; then
            printf 'NOPROJECT\t-\t%s\t%s\n' "${net}" "${managed_subnet[${net}]:--}"
            continue
        fi
        [[ -n "${known_project[${managed_project[${net}]}]+x}" ]] && continue
        printf 'ORPHAN\t%s\t%s\t%s\n' "${managed_project[${net}]:--}" "${net}" "${managed_subnet[${net}]:--}"
    done
}

# Exibe detalhes da rede Docker do projeto (a de CCTL_PROJECT_NETWORK).
network_show_details() {
    local project_name="${COMPOSE_PROJECT_NAME:-}"
    local net="${CCTL_PROJECT_NETWORK:-}"

    if [[ -z "${project_name}" ]]; then
        log_error "COMPOSE_PROJECT_NAME nao definido"
        return 1
    fi

    if [[ -z "${net}" ]]; then
        log_warn "Nenhuma rede registrada para o projeto ${project_name} (CCTL_PROJECT_NETWORK ausente no .env)"
        return 0
    fi

    if ! network_exists "${net}"; then
        log_warn "A rede ${net} do projeto ${project_name} nao existe (rode 'cctl up' para recria-la)"
        return 0
    fi

    echo -e "Rede Docker da instalacao ${YELLOW}${project_name}${RESET}\n"

    local subnet
    subnet=$(network_subnet_of "${net}")

    echo -e "Nome da Rede: ${CYAN}${net}${RESET}"
    echo -e "SUBNET:       ${CYAN}${subnet}${RESET}"
    echo ""

    # Lista containers conectados com IPs
    docker network inspect "${net}" --format '{{range $id, $c := .Containers}}{{$c.Name}} {{$c.IPv4Address}}{{"\n"}}{{end}}' 2>/dev/null \
        | while read -r name ip; do
            [[ -z "${name}" ]] && continue
            printf "  Container: %-30s  IPv4: %s\n" "${name}" "${ip}"
        done
    echo ""
}
