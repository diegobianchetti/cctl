#!/bin/bash
# commands/proxy.sh — Gerencia o proxy Nginx nativo compartilhado (cctl-proxy-net)
#
# Uso:
#   cctl proxy up       — sobe a infraestrutura do proxy (rede + diretorios + container)
#   cctl proxy down     — para e remove o container do proxy
#   cctl proxy reload   — testa e recarrega a configuracao nginx
#   cctl proxy test     — testa a sintaxe da configuracao (todos os vhosts)
#   cctl proxy logs     — encaminha argumentos extras para `docker logs`
#   cctl proxy status   — status do container, saude, portas e rede

cmd_proxy() {
    local action="${1:-}"
    [[ $# -gt 0 ]] && shift

    case "${action}" in
        up)     nginx_proxy_up ;;
        down)   nginx_proxy_down ;;
        reload) nginx_proxy_reload ;;
        test)   nginx_proxy_test ;;
        logs)   nginx_proxy_logs "$@" ;;
        status) nginx_proxy_status ;;
        "")
            _proxy_usage
            ;;
        *)
            msg_error "Acao desconhecida: '${action}'"
            _proxy_usage
            return 1
            ;;
    esac
}

_proxy_usage() {
    echo -e "${BOLD}Uso:${RESET} cctl proxy <up|down|reload|test|logs|status>"
}
