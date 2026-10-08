#!/usr/bin/env bats
# tests/network.bats — testes para lib/network.sh: aritmetica de faixas,
# alocador, ciclo da rede do projeto (install/up), reconexao do proxy e
# auditoria de redes orfas.
#
# Isolamento: `docker` e `ip` sempre mockados (mock_docker_netsim guarda o
# estado das redes em arquivos); nenhuma rede, rota ou container real e tocado.

bats_require_minimum_version 1.5.0

setup() {
    load 'helpers/common'
    load_bats_libs
    setup_mock_bin
    source_lib colors.sh log.sh core.sh env.sh inventory.sh network.sh vhost.sh

    WORKDIR="$(make_tmp_workdir)"
    cd "${WORKDIR}" || return 1

    export CCTL_INVENTORY_DIR="${WORKDIR}/inventory"
    export NGINX_CONTAINER_NAME="nginx-proxy"
    export COMPOSE_PROJECT_NAME="app"
    export DOMAIN_NAME="app.example.com"
    unset ENV_FILE CCTL_PROJECT_NETWORK COMPOSE_PROJECT_SUBNET
    : > .env

    mock_sudo_passthrough
    setup_network_env
    mock_docker_netsim "${WORKDIR}/docker_calls.log"
}

teardown() {
    teardown_mock_bin
    [[ -n "${WORKDIR:-}" && -d "${WORKDIR}" ]] && rm -rf "${WORKDIR}"
    true
}

# ============================================================
# Aritmetica de faixas
# ============================================================

@test "network_ip_to_int/network_int_to_ip: conversao ida e volta" {
    run network_ip_to_int "192.168.1.1"
    assert_output "3232235777"
    run network_ip_to_int "0.0.0.0"
    assert_output "0"
    run network_ip_to_int "255.255.255.255"
    assert_output "4294967295"

    local ip
    for ip in 10.240.1.0 172.16.0.1 192.168.255.254 8.8.4.4; do
        run network_int_to_ip "$(network_ip_to_int "${ip}")"
        assert_output "${ip}"
    done
}

@test "network_ip_to_int: recusa IPv4 invalido" {
    run network_ip_to_int "256.0.0.1"
    assert_failure
    run network_ip_to_int "1.2.3"
    assert_failure
    run network_ip_to_int "abc"
    assert_failure
    run network_ip_to_int "1.2.3.4.5"
    assert_failure
}

@test "network_cidr_valid: aceita CIDR IPv4 e recusa o resto" {
    run network_cidr_valid "10.240.0.0/16"
    assert_success
    run network_cidr_valid "10.240.0.0/33"
    assert_failure
    run network_cidr_valid "10.240.0.0"
    assert_failure
    run network_cidr_valid "fd00::/64"
    assert_failure
    run network_cidr_valid "10.240.0.256/24"
    assert_failure
}

@test "network_cidr_overlap: mesmo tamanho, contido, contendo e disjunto" {
    # iguais
    run network_cidr_overlap "10.240.1.0/24" "10.240.1.0/24"
    assert_success
    # uma dentro da outra (nas duas ordens)
    run network_cidr_overlap "10.240.0.0/16" "10.240.1.0/24"
    assert_success
    run network_cidr_overlap "10.240.1.0/24" "10.240.0.0/16"
    assert_success
    # tamanhos diferentes que cruzam: /20 cobre 10.240.0.0 a 10.240.15.255
    run network_cidr_overlap "10.240.9.0/24" "10.240.0.0/20"
    assert_success
    # disjuntas
    run network_cidr_overlap "10.240.1.0/24" "10.240.2.0/24"
    assert_failure
    run network_cidr_overlap "10.240.16.0/24" "10.240.0.0/20"
    assert_failure
    run network_cidr_overlap "10.240.0.0/16" "10.89.0.0/16"
    assert_failure
}

@test "network_cidr_contains: interna so conta se estiver INTEIRA dentro" {
    run network_cidr_contains "10.240.0.0/16" "10.240.5.0/24"
    assert_success
    run network_cidr_contains "10.240.5.0/24" "10.240.0.0/16"
    assert_failure
    run network_cidr_contains "10.240.0.0/16" "10.89.5.0/24"
    assert_failure
}

@test "network_cidr_aligned: so o endereco de rede e alinhado" {
    run network_cidr_aligned "10.240.1.0/24"
    assert_success
    run network_cidr_aligned "10.240.1.5/24"
    assert_failure
    run network_cidr_aligned "10.240.0.0/16"
    assert_success
}

@test "network_cidr_in_rfc1918: dentro, fora e cruzando a borda" {
    local c
    for c in 10.240.0.0/16 10.0.0.0/8 172.16.0.0/12 172.31.255.0/24 192.168.5.0/24 192.168.0.0/16; do
        run network_cidr_in_rfc1918 "${c}"
        assert_success
    done
    # 172.32.x ja e publico (o bloco privado termina em 172.31)
    for c in 172.32.0.0/16 172.0.0.0/8 172.16.0.0/11 192.169.0.0/16 8.8.8.0/24 11.0.0.0/8 0.0.0.0/0; do
        run network_cidr_in_rfc1918 "${c}"
        assert_failure
    done
}

# ============================================================
# network_validate_config
# ============================================================

@test "network_validate_config: default (10.240.0.0/16 + 24) passa" {
    run network_validate_config
    assert_success
}

@test "network_validate_config: recusa range malformado, desalinhado e prefixo incoerente" {
    CCTL_NETWORK_RANGE="banana" run network_validate_config
    assert_failure
    assert_output --partial "CCTL_NETWORK_RANGE invalido"

    CCTL_NETWORK_RANGE="10.240.0.5/16" run network_validate_config
    assert_failure
    assert_output --partial "nao comeca no inicio"

    CCTL_NETWORK_PREFIX="12" run network_validate_config
    assert_failure
    assert_output --partial "fora do permitido"

    CCTL_NETWORK_PREFIX="31" run network_validate_config
    assert_failure
    assert_output --partial "fora do permitido"

    CCTL_NETWORK_PREFIX="x" run network_validate_config
    assert_failure
    assert_output --partial "CCTL_NETWORK_PREFIX invalido"
}

# ============================================================
# O que ja esta em uso
# ============================================================

@test "network_host_routes: ignora default, docker0 e br-*; mantem LAN/VPN" {
    mock_ip_routes \
        "default via 192.168.1.1 dev eth0 proto dhcp" \
        "172.17.0.0/16 dev docker0 proto kernel scope link src 172.17.0.1" \
        "10.240.3.0/24 dev br-1a2b3c4d5e6f proto kernel scope link src 10.240.3.1" \
        "10.8.0.0/24 dev tun0 proto kernel scope link" \
        "192.168.1.0/24 dev eth0 proto kernel scope link"

    run network_host_routes
    assert_success
    assert_output --partial "10.8.0.0/24"
    assert_output --partial "192.168.1.0/24"
    refute_output --partial "172.17.0.0/16"
    refute_output --partial "10.240.3.0/24"
}

@test "network_host_routes: so docker0 e br-<12 hex> sao ignoradas; br-lan e rota do operador" {
    mock_ip_routes \
        "10.240.30.0/24 dev br-lan proto kernel scope link" \
        "10.240.31.0/24 dev br-0123456789ab proto kernel scope link" \
        "10.240.32.0/24 dev br-0123456789abcd proto kernel scope link" \
        "10.240.33.0/24 dev docker0 proto kernel scope link"

    run network_host_routes
    assert_success
    assert_output --partial "10.240.30.0/24"
    assert_output --partial "10.240.32.0/24"
    refute_output --partial "10.240.31.0/24"
    refute_output --partial "10.240.33.0/24"
}

@test "network_host_routes: le todas as tabelas (VPN com policy routing) e ignora local/broadcast/unreachable/multicast" {
    mock_ip_routes \
        "10.240.40.0/24 dev tun0 table 100 scope link" \
        "local 127.0.0.1 dev lo table local proto kernel scope host src 127.0.0.1" \
        "broadcast 10.240.41.255 dev eth0 table local proto kernel scope link" \
        "unreachable 10.240.42.0/24 table 100" \
        "multicast 224.0.0.0/4 dev eth0 table local" \
        "default via 192.168.1.1 dev eth0 table 100"

    run network_host_routes
    assert_success
    assert_output --partial "10.240.40.0/24"
    refute_output --partial "127.0.0.1"
    refute_output --partial "10.240.41"
    refute_output --partial "10.240.42"
    refute_output --partial "224.0.0.0"
    # o mock responde a "ip -4 route show table all"
    run ip -4 route show table all
    assert_output --partial "table 100"
}

@test "network_allocate_subnet: rota em br-lan dentro do range e pulada" {
    mock_ip_routes "10.240.0.0/24 dev br-lan proto kernel scope link"
    run network_allocate_subnet "app"
    assert_success
    assert_output "10.240.1.0/24"
}

@test "network_docker_pools: daemon.json com a chave mas sem faixas legiveis -> aviso e default" {
    echo '{"default-address-pools": "oops"}' > "${WORKDIR}/daemon.json"
    export DOCKER_DAEMON_JSON="${WORKDIR}/daemon.json"

    run network_docker_pools
    assert_success
    assert_output --partial "nao consegui extrair"
    assert_output --partial "172.17.0.0/16"
}

@test "network_docker_pools: daemon.json ilegivel -> aviso e default" {
    [[ ${EUID} -ne 0 ]] || skip "root le qualquer arquivo"
    echo '{}' > "${WORKDIR}/daemon.json"
    chmod 000 "${WORKDIR}/daemon.json"
    export DOCKER_DAEMON_JSON="${WORKDIR}/daemon.json"

    run network_docker_pools
    assert_success
    assert_output --partial "Nao consegui ler"
    assert_output --partial "192.168.0.0/16"
}

@test "network_docker_pools: sem default-address-pools e sem problema -> sem aviso" {
    echo '{"log-level": "warn"}' > "${WORKDIR}/daemon.json"
    export DOCKER_DAEMON_JSON="${WORKDIR}/daemon.json"
    run network_docker_pools
    refute_output --partial "AVISO"
}

@test "network_docker_pools: sem daemon.json devolve o default do Docker" {
    run network_docker_pools
    assert_success
    assert_output --partial "172.17.0.0/16"
    assert_output --partial "172.31.0.0/16"
    assert_output --partial "192.168.0.0/16"
    refute_output --partial "172.16.0.0/16"
}

@test "network_docker_pools: le default-address-pools do daemon.json (sem jq) e ignora outros arrays" {
    cat > "${WORKDIR}/daemon.json" <<'EOF'
{
  "dns": ["8.8.8.8"],
  "default-address-pools": [
    {"base": "10.200.0.0/16", "size": 24},
    {
      "base": "10.201.0.0/16",
      "size": 24
    }
  ],
  "log-level": "warn"
}
EOF
    export DOCKER_DAEMON_JSON="${WORKDIR}/daemon.json"

    run network_docker_pools
    assert_success
    assert_line "10.200.0.0/16"
    assert_line "10.201.0.0/16"
    refute_output --partial "172.17.0.0/16"
    refute_output --partial "8.8.8.8"
}

@test "network_docker_pools: daemon.json sem default-address-pools cai no default do Docker" {
    echo '{"log-level": "warn"}' > "${WORKDIR}/daemon.json"
    export DOCKER_DAEMON_JSON="${WORKDIR}/daemon.json"

    run network_docker_pools
    assert_success
    assert_output --partial "172.17.0.0/16"
}

# ============================================================
# Alocador
# ============================================================

@test "network_allocate_subnet: sem nada em uso devolve a primeira faixa do range" {
    run network_allocate_subnet "app"
    assert_success
    assert_output "10.240.0.0/24"
}

@test "network_allocate_subnet: pula redes Docker de OUTRO tamanho (10.240.0.0/20 ocupa 16 faixas /24)" {
    netsim_add_network "grande" "" "10.240.0.0/20"

    run network_allocate_subnet "app"
    assert_success
    assert_output "10.240.16.0/24"
}

@test "network_allocate_subnet: pula faixa usada exatamente e segue em passos do prefixo" {
    netsim_add_network "a" "" "10.240.0.0/24"
    netsim_add_network "b" "" "10.240.1.0/24"

    run network_allocate_subnet "app"
    assert_success
    assert_output "10.240.2.0/24"
}

@test "network_allocate_subnet: pula rota do host que nao e bridge Docker" {
    mock_ip_routes "10.240.0.0/23 dev eth0 proto kernel scope link"

    run network_allocate_subnet "app"
    assert_success
    assert_output "10.240.2.0/24"
}

@test "network_allocate_subnet: rota de br-* nao conta como rota do host" {
    mock_ip_routes "10.240.0.0/24 dev br-0a1b2c3d4e5f proto kernel scope link"

    run network_allocate_subnet "app"
    assert_success
    assert_output "10.240.0.0/24"
}

@test "network_allocate_subnet: pula a subnet reservada no inventario por projeto PARADO (sem rede Docker)" {
    inventory_mark_prepared "parado" "moodle" "c" "parado.example.com" "${WORKDIR}/instances/parado"
    inventory_set_network "parado" "parado_net" "10.240.0.0/24"
    run ! netsim_has_network "parado_net"

    run network_allocate_subnet "app"
    assert_success
    assert_output "10.240.1.0/24"
}

@test "network_allocate_subnet: a reserva do PROPRIO projeto no inventario nao o bloqueia" {
    inventory_mark_prepared "app" "moodle" "c" "app.example.com" "${WORKDIR}/instances/app"
    inventory_set_network "app" "app_net" "10.240.0.0/24"

    run network_allocate_subnet "app"
    assert_success
    assert_output "10.240.0.0/24"
}

@test "network_allocate_subnet: faixas ja tentadas (argumentos) tambem sao evitadas" {
    run network_allocate_subnet "app" "10.240.0.0/24" "10.240.1.0/24"
    assert_success
    assert_output "10.240.2.0/24"
}

@test "network_allocate_subnet: respeita CCTL_NETWORK_PREFIX (passo /26)" {
    export CCTL_NETWORK_PREFIX="26"
    netsim_add_network "a" "" "10.240.0.0/26"

    run network_allocate_subnet "app"
    assert_success
    assert_output "10.240.0.64/26"
}

@test "network_allocate_subnet: range esgotado -> rc 1 com mensagem" {
    export CCTL_NETWORK_RANGE="10.240.0.0/24" CCTL_NETWORK_PREFIX="25"
    netsim_add_network "a" "" "10.240.0.0/25"
    netsim_add_network "b" "" "10.240.0.128/25"

    run network_allocate_subnet "app"
    assert_failure
    assert_output --partial "esgotado"
}

@test "network_allocate_subnet: config invalida -> rc 1 sem tocar o docker" {
    export CCTL_NETWORK_PREFIX="40"
    run network_allocate_subnet "app"
    assert_failure
    [[ ! -s "${WORKDIR}/docker_calls.log" ]]
}

# ============================================================
# network_check_candidate (faixa digitada pelo usuario)
# ============================================================

@test "network_check_candidate: faixa livre dentro do range passa" {
    run network_check_candidate "10.240.9.0/24" "app"
    assert_success
}

@test "network_check_candidate: recusa com o motivo certo" {
    network_check_candidate "banana" "app" || true
    [[ "${NETWORK_REJECT_REASON}" == *"CIDR IPv4 valido"* ]]

    network_check_candidate "10.240.9.0/25" "app" || true
    [[ "${NETWORK_REJECT_REASON}" == *"/24"* ]]

    network_check_candidate "10.240.9.5/24" "app" || true
    [[ "${NETWORK_REJECT_REASON}" == *"inicio da faixa"* ]]

    network_check_candidate "10.99.9.0/24" "app" || true
    [[ "${NETWORK_REJECT_REASON}" == *"fora do range"* ]]

    netsim_add_network "outra" "" "10.240.9.0/24"
    network_check_candidate "10.240.9.0/24" "app" || true
    [[ "${NETWORK_REJECT_REASON}" == *"rede Docker outra"* ]]
}

# ============================================================
# network_provision_for_install (passo da rede do install)
# ============================================================

@test "provision: rede do projeto ja existe -> reaproveita e NAO chama 'network create'" {
    netsim_add_network "app_net" "app" "10.240.7.0/24" "app.example.com"

    run network_provision_for_install
    assert_success
    assert_output --partial "reaproveitando"

    run ! grep -q "network create" "${WORKDIR}/docker_calls.log"
    grep -q "^CCTL_PROJECT_NETWORK=app_net$" .env
    grep -q "^COMPOSE_PROJECT_SUBNET=10.240.7.0/24$" .env
}

@test "provision: sem rede -> cria <projeto>_net com a subnet sugerida e os labels do cctl" {
    run network_provision_for_install < /dev/null
    assert_success

    run grep "network create" "${WORKDIR}/docker_calls.log"
    assert_success
    assert_output --partial "--subnet 10.240.0.0/24"
    assert_output --partial "--driver bridge"
    assert_output --partial "--label io.cctl.managed=true"
    assert_output --partial "--label io.cctl.project=app"
    assert_output --partial "--label io.cctl.domain=app.example.com"
    assert_output --partial "app_net"
    # nenhum label do compose: a rede e do cctl, nao do compose
    refute_output --partial "com.docker.compose"

    netsim_has_network "app_net"
    grep -q "^CCTL_PROJECT_NETWORK=app_net$" .env
    grep -q "^COMPOSE_PROJECT_SUBNET=10.240.0.0/24$" .env
}

@test "provision: rede com o nome do projeto mas SEM o label dele -> recusa (nao e do cctl)" {
    netsim_add_network "app_net" "" "10.240.7.0/24"

    run network_provision_for_install
    assert_failure
    assert_output --partial "nao pertence a este projeto"
    run ! grep -q "network create" "${WORKDIR}/docker_calls.log"
}

@test "provision: Docker recusa a faixa por sobreposicao -> tenta a proxima livre" {
    netsim_fail_subnet "10.240.0.0/24"

    run network_provision_for_install < /dev/null
    assert_success
    assert_output --partial "Tentando a proxima faixa livre"

    [[ "$(netsim_subnet app_net)" == "10.240.1.0/24" ]]
    [[ "$(grep -c "network create" "${WORKDIR}/docker_calls.log")" -eq 2 ]]
    grep -q "^COMPOSE_PROJECT_SUBNET=10.240.1.0/24$" .env
}

@test "provision: falha do Docker que nao e sobreposicao -> rc 1 sem insistir" {
    mock_cmd docker '
        if [[ "$1 $2" == "network inspect" ]]; then
            echo "Error: No such network: app_net" >&2
            exit 1
        fi
        if [[ "$1 $2" == "network create" ]]; then
            echo "Error response from daemon: permission denied" >&2
            exit 1
        fi
        [[ "$1 $2" == "network ls" ]] && exit 0
        exit 1
    '
    run network_provision_for_install < /dev/null
    assert_failure
    assert_output --partial "permission denied"
}

@test "provision: sem terminal NAO pergunta, usa a sugestao" {
    _network_is_interactive() { return 1; }

    run network_provision_for_install < /dev/null
    assert_success
    assert_output --partial "Sem terminal"
    refute_output --partial "Enter aceita"
    [[ "$(netsim_subnet app_net)" == "10.240.0.0/24" ]]
}

@test "provision: com terminal, Enter aceita a sugestao" {
    _network_is_interactive() { return 0; }

    run network_provision_for_install <<< ""
    assert_success
    assert_output --partial "Subnet sugerida"
    assert_output --partial "10.240.0.0/24"
    [[ "$(netsim_subnet app_net)" == "10.240.0.0/24" ]]
}

@test "provision: com terminal, faixa digitada valida e usada" {
    _network_is_interactive() { return 0; }

    run network_provision_for_install <<< "10.240.40.0/24"
    assert_success
    [[ "$(netsim_subnet app_net)" == "10.240.40.0/24" ]]
    grep -q "^COMPOSE_PROJECT_SUBNET=10.240.40.0/24$" .env
}

@test "provision: com terminal, faixa invalida e recusada com motivo e pergunta de novo" {
    _network_is_interactive() { return 0; }
    netsim_add_network "outra" "" "10.240.50.0/24"

    # 1) fora do range  2) em uso  3) CIDR quebrado  4) valida
    run network_provision_for_install <<< $'10.99.0.0/24\n10.240.50.0/24\nbanana\n10.240.60.0/24'
    assert_success
    assert_output --partial "fora do range do cctl"
    assert_output --partial "ja esta em uso"
    assert_output --partial "nao e um CIDR IPv4 valido"
    [[ "$(netsim_subnet app_net)" == "10.240.60.0/24" ]]
}

@test "network_cidr_normalize: tira zeros a esquerda; invalido volta igual" {
    run network_cidr_normalize "10.240.03.0/24"
    assert_output "10.240.3.0/24"
    run network_cidr_normalize "010.240.003.000/24"
    assert_output "10.240.3.0/24"
    run network_cidr_normalize "banana"
    assert_output "banana"
}

@test "provision: com terminal, faixa digitada com zero a esquerda e normalizada antes de validar e gravar" {
    _network_is_interactive() { return 0; }

    run network_provision_for_install <<< "10.240.03.0/24"
    assert_success
    [[ "$(netsim_subnet app_net)" == "10.240.3.0/24" ]]
    grep -q "^COMPOSE_PROJECT_SUBNET=10.240.3.0/24$" .env
}

@test "provision: grava NETWORK/SUBNET no registro do inventario quando ele existe" {
    inventory_mark_prepared "app" "moodle" "c" "app.example.com" "${WORKDIR}/instances/app"

    run network_provision_for_install < /dev/null
    assert_success

    inventory_read "app"
    [[ "${INV_NETWORK}" == "app_net" ]]
    [[ "${INV_SUBNET}" == "10.240.0.0/24" ]]
    [[ "${INV_STATUS}" == "prepared" ]]
}

@test "provision: falha ao gravar reserva em registro existente interrompe o install" {
    inventory_mark_prepared "app" "moodle" "c" "app.example.com" "${WORKDIR}/instances/app"
    inventory_set_network() { return 1; }

    run network_provision_for_install < /dev/null
    assert_failure
    assert_output --partial "Falha ao gravar a reserva"
}

@test "provision: dois projetos seguidos recebem faixas diferentes" {
    inventory_mark_prepared "app" "moodle" "c" "app.example.com" "${WORKDIR}/instances/app"
    network_provision_for_install < /dev/null

    export COMPOSE_PROJECT_NAME="outro" DOMAIN_NAME="outro.example.com"
    inventory_mark_prepared "outro" "moodle" "c" "outro.example.com" "${WORKDIR}/instances/outro"
    network_provision_for_install < /dev/null

    [[ "$(netsim_subnet app_net)" == "10.240.0.0/24" ]]
    [[ "$(netsim_subnet outro_net)" == "10.240.1.0/24" ]]
}

# ============================================================
# network_ensure_for_up (ciclo de vida: cctl up)
# ============================================================

@test "ensure_for_up: sem CCTL_PROJECT_NETWORK/COMPOSE_PROJECT_SUBNET -> rc 1 orientando reinstalar" {
    run network_ensure_for_up
    assert_failure
    assert_output --partial "nao tem rede gerenciada pelo cctl"
    assert_output --partial "cctl destroy"
}

@test "ensure_for_up: rede existe -> nao cria nada e liga o proxy se faltava" {
    export CCTL_PROJECT_NETWORK="app_net" COMPOSE_PROJECT_SUBNET="10.240.4.0/24"
    netsim_add_network "app_net" "app" "10.240.4.0/24" "app.example.com"

    run network_ensure_for_up
    assert_success
    run ! grep -q "network create" "${WORKDIR}/docker_calls.log"
    netsim_is_connected "app_net"
    grep -q "network connect --alias app.example.com app_net nginx-proxy" "${WORKDIR}/docker_calls.log"
}

@test "ensure_for_up: ao recriar a rede, devolve a reserva ao inventario (apos um clear-all)" {
    export CCTL_PROJECT_NETWORK="app_net" COMPOSE_PROJECT_SUBNET="10.240.4.0/24"
    inventory_mark_installed "app" "moodle" "c" "app.example.com" "${WORKDIR}/i/app" "app_net" "10.240.4.0/24"
    inventory_clear_network "app"
    inventory_read "app"
    [[ -z "${INV_NETWORK}" ]]

    run network_ensure_for_up
    assert_success

    inventory_read "app"
    [[ "${INV_NETWORK}" == "app_net" ]]
    [[ "${INV_SUBNET}" == "10.240.4.0/24" ]]
}

@test "ensure_for_up: falha ao restaurar reserva em registro existente interrompe o up" {
    export CCTL_PROJECT_NETWORK="app_net" COMPOSE_PROJECT_SUBNET="10.240.4.0/24"
    inventory_mark_installed "app" "moodle" "c" "app.example.com" "${WORKDIR}/i/app" "app_net" "10.240.4.0/24"
    inventory_clear_network "app"
    inventory_set_network() { return 1; }

    run network_ensure_for_up
    assert_failure
    assert_output --partial "Falha ao gravar a reserva"
}

@test "ensure_for_up: retomada apos falha de reserva na criacao reconcilia rede ja existente" {
    inventory_mark_prepared "app" "moodle" "c" "app.example.com" "${WORKDIR}/i/app"
    inventory_set_network() {
        if [[ ! -e "${WORKDIR}/reservation_failed_once" ]]; then
            : > "${WORKDIR}/reservation_failed_once"
            return 1
        fi
        command inventory_set_network "$@"
    }

    run network_provision_for_install < /dev/null
    assert_failure
    netsim_has_network "app_net"
    unset -f inventory_set_network
    source "${CCTL_ROOT}/lib/inventory.sh"
    export CCTL_PROJECT_NETWORK="app_net" COMPOSE_PROJECT_SUBNET="10.240.0.0/24"

    run network_ensure_for_up
    assert_success
    inventory_read "app"
    [[ "${INV_NETWORK}" == "app_net" ]]
    [[ "${INV_SUBNET}" == "10.240.0.0/24" ]]
}

@test "ensure_for_up: rede existe com subnet diferente do .env -> so avisa (rc 0)" {
    export CCTL_PROJECT_NETWORK="app_net" COMPOSE_PROJECT_SUBNET="10.240.4.0/24"
    netsim_add_network "app_net" "app" "10.240.9.0/24" "app.example.com"

    run network_ensure_for_up
    assert_success
    assert_output --partial "10.240.9.0/24"
    assert_output --partial "o .env diz 10.240.4.0/24"
}

@test "ensure_for_up: rede existe com label de OUTRO projeto -> so avisa (rc 0)" {
    export CCTL_PROJECT_NETWORK="app_net" COMPOSE_PROJECT_SUBNET="10.240.4.0/24"
    netsim_add_network "app_net" "outro" "10.240.4.0/24" "app.example.com"

    run network_ensure_for_up
    assert_success
    assert_output --partial "io.cctl.project"
    assert_output --partial "'outro'"
}

@test "ensure_for_up: rede coerente com o .env -> sem avisos" {
    export CCTL_PROJECT_NETWORK="app_net" COMPOSE_PROJECT_SUBNET="10.240.4.0/24"
    netsim_add_network "app_net" "app" "10.240.4.0/24" "app.example.com"
    netsim_connect "app_net"

    run network_ensure_for_up
    assert_success
    refute_output --partial "AVISO"
}

@test "ensure_for_up: proxy ja conectado -> nao reconecta" {
    export CCTL_PROJECT_NETWORK="app_net" COMPOSE_PROJECT_SUBNET="10.240.4.0/24"
    netsim_add_network "app_net" "app" "10.240.4.0/24" "app.example.com"
    netsim_connect "app_net" "app.example.com"

    run network_ensure_for_up
    assert_success
    run ! grep -q "network connect" "${WORKDIR}/docker_calls.log"
}

@test "ensure_for_up: rede sumiu e a faixa esta livre -> recria com a MESMA subnet e os labels" {
    export CCTL_PROJECT_NETWORK="app_net" COMPOSE_PROJECT_SUBNET="10.240.4.0/24"

    run network_ensure_for_up
    assert_success
    assert_output --partial "Recriando a rede app_net"

    run grep "network create" "${WORKDIR}/docker_calls.log"
    assert_output --partial "--subnet 10.240.4.0/24"
    assert_output --partial "--label io.cctl.managed=true"
    assert_output --partial "--label io.cctl.project=app"
    assert_output --partial "--label io.cctl.domain=app.example.com"
    netsim_is_connected "app_net"
}

@test "ensure_for_up: rede sumiu e a faixa foi tomada -> recusa dizendo quem a usa, sem criar nada" {
    export CCTL_PROJECT_NETWORK="app_net" COMPOSE_PROJECT_SUBNET="10.240.4.0/24"
    netsim_add_network "intrusa" "" "10.240.4.0/22"

    run network_ensure_for_up
    assert_failure
    assert_output --partial "foi tomada"
    assert_output --partial "rede Docker intrusa"
    assert_output --partial "nao troca a faixa"
    run ! grep -q "network create" "${WORKDIR}/docker_calls.log"
}

@test "ensure_for_up: faixa reservada por OUTRO projeto no inventario tambem bloqueia" {
    export CCTL_PROJECT_NETWORK="app_net" COMPOSE_PROJECT_SUBNET="10.240.4.0/24"
    inventory_mark_prepared "outro" "moodle" "c" "outro.example.com" "${WORKDIR}/instances/outro"
    inventory_set_network "outro" "outro_net" "10.240.4.0/24"

    run network_ensure_for_up
    assert_failure
    assert_output --partial "projeto outro"
}

@test "ensure_for_up: a reserva do PROPRIO projeto no inventario nao bloqueia a recriacao" {
    export CCTL_PROJECT_NETWORK="app_net" COMPOSE_PROJECT_SUBNET="10.240.4.0/24"
    inventory_mark_prepared "app" "moodle" "c" "app.example.com" "${WORKDIR}/instances/app"
    inventory_set_network "app" "app_net" "10.240.4.0/24"

    run network_ensure_for_up
    assert_success
    netsim_has_network "app_net"
}

# ============================================================
# Proxy: conectar, reconectar, remover rede
# ============================================================

@test "network_connect_nginx: chama docker network connect com alias do DOMAIN_NAME" {
    run network_connect_nginx "minha-rede"
    assert_success
    grep -q "network connect --alias app.example.com minha-rede nginx-proxy" "${WORKDIR}/docker_calls.log"
}

@test "network_connect_nginx: alias explicito tem prioridade sobre DOMAIN_NAME" {
    run network_connect_nginx "minha-rede" "outro.example.com"
    assert_success
    grep -q "network connect --alias outro.example.com minha-rede nginx-proxy" "${WORKDIR}/docker_calls.log"
}

@test "network_connect_nginx: proxy existente com conexao recusada falha depois de confirmar que a rede continua ausente" {
    netsim_add_network "app_net" "app" "10.240.0.0/24" "app.example.com"
    netsim_fail_connect "app_net"

    run network_connect_nginx "app_net"
    assert_failure
    assert_output --partial "nginx-proxy existe"
    run ! netsim_is_connected "app_net"
}

@test "network_connect_nginx: proxy inexistente mantem aviso tolerado" {
    netsim_add_network "app_net" "app" "10.240.0.0/24" "app.example.com"
    netsim_remove_proxy

    run network_connect_nginx "app_net"
    assert_success
    assert_output --partial "nginx-proxy nao existe"
    run ! netsim_is_connected "app_net"
}

@test "network_disconnect_nginx: avisa mas nao falha quando container ja nao esta conectado" {
    mock_cmd docker 'exit 1'

    run network_disconnect_nginx "minha-rede"
    assert_success
    assert_output --partial "nao estava conectado"
}

@test "network_reconnect_proxy: reconecta so as redes gerenciadas que faltam, com o alias do label" {
    netsim_add_network "a_net" "a" "10.240.0.0/24" "a.example.com"
    netsim_add_network "b_net" "b" "10.240.1.0/24" "b.example.com"
    netsim_add_network "terceiros" "" "10.99.0.0/24"
    netsim_connect "a_net" "a.example.com"

    run network_reconnect_proxy
    assert_success

    grep -q "network connect --alias b.example.com b_net nginx-proxy" "${WORKDIR}/docker_calls.log"
    run ! grep -q "network connect .* a_net " "${WORKDIR}/docker_calls.log"
    run ! grep -q "terceiros nginx-proxy" "${WORKDIR}/docker_calls.log"
    netsim_is_connected "b_net"
    run ! netsim_is_connected "terceiros"
}

@test "network_reconnect_proxy: falha agregada nao impede tentativa nas demais redes" {
    netsim_add_network "a_net" "a" "10.240.0.0/24" "a.example.com"
    netsim_add_network "b_net" "b" "10.240.1.0/24" "b.example.com"
    netsim_fail_connect "a_net"

    run network_reconnect_proxy
    assert_failure
    assert_output --partial "rede a_net"
    run ! netsim_is_connected "a_net"
    netsim_is_connected "b_net"
    grep -q "network connect --alias b.example.com b_net nginx-proxy" "${WORKDIR}/docker_calls.log"
}

@test "network_reconnect_proxy: alias vem do dominio do INVENTARIO (reinstall com outro dominio), label so de reserva" {
    # a rede foi criada com o dominio antigo (label); o reinstall atualizou o inventario
    netsim_add_network "a_net" "a" "10.240.0.0/24" "antigo.example.com"
    inventory_mark_installed "aa" "moodle" "c" "novo.example.com" "${WORKDIR}/i/aa" "a_net" "10.240.0.0/24"
    # outra rede sem registro no inventario: cai no label
    netsim_add_network "b_net" "b" "10.240.1.0/24" "b.example.com"

    run network_reconnect_proxy
    assert_success
    grep -q "network connect --alias novo.example.com a_net nginx-proxy" "${WORKDIR}/docker_calls.log"
    run ! grep -q "antigo.example.com" "${WORKDIR}/docker_calls.log"
    grep -q "network connect --alias b.example.com b_net nginx-proxy" "${WORKDIR}/docker_calls.log"
}

@test "network_remove_project_network: desconecta o proxy e apaga a rede" {
    netsim_add_network "app_net" "app" "10.240.0.0/24" "app.example.com"
    netsim_connect "app_net"

    run network_remove_project_network "app_net"
    assert_success
    grep -q "network disconnect app_net nginx-proxy" "${WORKDIR}/docker_calls.log"
    grep -q "network rm app_net" "${WORKDIR}/docker_calls.log"
    run ! netsim_has_network "app_net"
}

# ============================================================
# Auditoria (cctl paths): orfas e redes ausentes
# ============================================================

@test "network_audit_lines: OK, MISSING, NONE e ORPHAN; nao apaga nada" {
    # ok: instalado, com rede
    inventory_mark_installed "ok1" "moodle" "c" "ok1.example.com" "${WORKDIR}/i/ok1" "ok1_net" "10.240.0.0/24"
    netsim_add_network "ok1_net" "ok1" "10.240.0.0/24" "ok1.example.com"
    # missing: inventario aponta para rede que nao existe
    inventory_mark_installed "sumiu" "moodle" "c" "sumiu.example.com" "${WORKDIR}/i/sumiu" "sumiu_net" "10.240.1.0/24"
    # none: instalado sem rede registrada (versao antiga)
    inventory_mark_installed "antigo" "moodle" "c" "antigo.example.com" "${WORKDIR}/i/antigo"
    # prepared sem rede: nao e divergencia (ainda nao instalou)
    inventory_mark_prepared "novo" "moodle" "c" "novo.example.com" "${WORKDIR}/i/novo"
    # orphan: rede do cctl sem instancia
    netsim_add_network "fantasma_net" "fantasma" "10.240.9.0/24" "fantasma.example.com"
    # rede de terceiros: nao e do cctl, nao aparece
    netsim_add_network "terceiros" "" "10.99.0.0/24"

    run network_audit_lines
    assert_success
    assert_line --regexp $'^OK\tok1\tok1_net\t10.240.0.0/24$'
    assert_line --regexp $'^MISSING\tsumiu\tsumiu_net\t10.240.1.0/24$'
    assert_line --regexp $'^NONE\tantigo\t-\t-$'
    assert_line --regexp $'^ORPHAN\tfantasma\tfantasma_net\t10.240.9.0/24$'
    refute_output --partial "novo"
    refute_output --partial "terceiros"

    # so mostra: nada foi removido
    run ! grep -q "network rm" "${WORKDIR}/docker_calls.log"
    netsim_has_network "fantasma_net"
}

@test "network_audit_lines: dono ou subnet divergentes sao reportados com a subnet real" {
    inventory_mark_installed "app" "moodle" "c" "app.example.com" "${WORKDIR}/i/app" "app_net" "10.240.4.0/24"
    netsim_add_network "app_net" "outro" "10.240.9.0/24" "app.example.com"

    run network_audit_lines
    assert_success
    assert_line --regexp $'^DIVERGENT\tapp\tapp_net\t10.240.9.0/24\toutro\t10.240.4.0/24$'
}

@test "network_audit_lines: rede gerenciada SEM label de projeto vira NOPROJECT (nao quebra)" {
    netsim_add_network "semdono" "@none" "10.240.7.0/24"
    netsim_add_network "fantasma_net" "fantasma" "10.240.9.0/24"

    run network_audit_lines
    assert_success
    assert_line --regexp $'^NOPROJECT\t-\tsemdono\t10.240.7.0/24$'
    assert_line --regexp $'^ORPHAN\tfantasma\tfantasma_net\t10.240.9.0/24$'
}

# ============================================================
# network_show_details
# ============================================================

@test "network_show_details: usa CCTL_PROJECT_NETWORK (nao procura por prefixo/label do compose)" {
    export CCTL_PROJECT_NETWORK="app_net"
    netsim_add_network "app_net" "app" "10.240.5.0/24" "app.example.com"
    # outra rede com prefixo igual, que a busca antiga pegaria
    netsim_add_network "app_extra" "" "10.77.0.0/24"

    run network_show_details
    assert_success
    assert_output --partial "app_net"
    assert_output --partial "10.240.5.0/24"
    refute_output --partial "app_extra"
}

@test "network_show_details: sem CCTL_PROJECT_NETWORK avisa em vez de adivinhar" {
    run network_show_details
    assert_success
    assert_output --partial "Nenhuma rede registrada"
}

# ============================================================
# Alvo do vhost resolve para o container DESTE projeto
# ============================================================

@test "network_check_target: resolve para o IP do container na rede do projeto -> ok" {
    netsim_add_container "app-moodle-app" "app_net" "10.240.0.5"
    netsim_connect "app_net"

    run network_check_target "app-moodle-app.app_net" "app_net"
    assert_success
    assert_output --partial "Alvo app-moodle-app.app_net confere: resolve so para o container app-moodle-app (10.240.0.5)"
    grep -q "exec nginx-proxy getent ahostsv4 app-moodle-app.app_net" "${WORKDIR}/docker_calls.log"
}

@test "network_check_target: sem override, proxy desconectado nao resolve o DNS da rede" {
    netsim_add_container "app-moodle-app" "app_net" "10.240.0.5"
    # Sem netsim_connect e sem netsim_resolve_override: prova a regra default
    # do mock de que o DNS do proxy depende da conexao real a rede.

    run network_check_target "app-moodle-app.app_net" "app_net"
    assert_failure
    assert_output --partial "NAO resolve"
}

@test "network_check_target: o IP certo MAIS outro IP na resposta -> rc 1 (todas as linhas contam)" {
    netsim_add_container "app-moodle-app" "app_net" "10.240.0.5"
    netsim_resolve_override "app-moodle-app.app_net" "10.240.0.5,10.240.0.99"

    run network_check_target "app-moodle-app.app_net" "app_net"
    assert_failure
    assert_output --partial "10.240.0.99"
}

@test "network_check_target: resolve para OUTRO IP -> rc 1 dizendo o alvo, o que resolveu e o esperado" {
    netsim_add_container "app-moodle-app" "app_net" "10.240.0.5"
    netsim_resolve_override "app-moodle-app.app_net" "10.240.9.9"

    run network_check_target "app-moodle-app.app_net" "app_net"
    assert_failure
    assert_output --partial "app-moodle-app.app_net"
    assert_output --partial "resolve para 10.240.9.9"
    assert_output --partial "10.240.0.5"
}

@test "network_check_target: nao resolve -> rc 1 e manda conferir o proxy" {
    netsim_add_container "app-moodle-app" "app_net" "10.240.0.5"
    netsim_resolve_override "app-moodle-app.app_net" "none"

    run network_check_target "app-moodle-app.app_net" "app_net"
    assert_failure
    assert_output --partial "NAO resolve"
    assert_output --partial "10.240.0.5"
    assert_output --partial "cctl proxy up"
}

@test "network_check_target: container inexistente ou fora da rede -> rc 1" {
    run network_check_target "app-moodle-app.app_net" "app_net"
    assert_failure
    assert_output --partial "nao existe ou nao esta na rede app_net"

    netsim_add_container "app-moodle-app" "outra_net" "10.240.7.7"
    run network_check_target "app-moodle-app.app_net" "app_net"
    assert_failure
}

@test "network_check_target: nome curto (sem a rede) -> rc 1 sem nem consultar o proxy" {
    run network_check_target "moodle-app" "app_net"
    assert_failure
    assert_output --partial "nao termina em .app_net"
    run ! grep -q "getent" "${WORKDIR}/docker_calls.log"
}

@test "network_check_target: o mesmo nome em OUTRA rede nao serve (e o que impede o site de outro projeto)" {
    # outro projeto tem um container de mesmo nome curto em outra rede
    netsim_add_container "app-moodle-app" "app_net" "10.240.0.5"
    netsim_add_container "outro-moodle-app" "outro_net" "10.240.1.5"
    netsim_resolve_override "app-moodle-app.app_net" "10.240.1.5"

    run network_check_target "app-moodle-app.app_net" "app_net"
    assert_failure
    assert_output --partial "resolve para 10.240.1.5"
}

@test "network_check_vhost_targets: confere TODOS os alvos (dspace: backend e frontend)" {
    mkdir -p "${WORKDIR}/v"
    cat > "${WORKDIR}/v/app.conf" <<'EOF'
server {
	location /server {
		set $target app-dspace.app_net:8080;
		proxy_pass http://$target;
	}
	location / {
		set $target app-dspace-angular.app_net:4000;
		proxy_pass http://$target;
	}
}
EOF
    netsim_add_container "app-dspace" "app_net" "10.240.0.5"
    netsim_add_container "app-dspace-angular" "app_net" "10.240.0.6"
    netsim_connect "app_net"

    run network_check_vhost_targets "${WORKDIR}/v/app.conf" "app_net"
    assert_success

    # o frontend resolve para o IP errado: o conjunto falha
    netsim_resolve_override "app-dspace-angular.app_net" "10.240.0.5"
    run network_check_vhost_targets "${WORKDIR}/v/app.conf" "app_net"
    assert_failure
    assert_output --partial "app-dspace-angular.app_net"
}

@test "network_check_vhost_targets: vhost sem alvo (HTTP do desafio ACME) passa" {
    printf 'server { listen 80; }\n' > "${WORKDIR}/acme.conf"
    run network_check_vhost_targets "${WORKDIR}/acme.conf" "app_net"
    assert_success
}
