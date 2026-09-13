#!/bin/bash
# commands/rollout.sh — Estrategias de rollout em single-host (lib/rollout.sh)
#
# Uso:
#   cctl rollout bluegreen [--service <svc>] [--image <ref>] [--health-mode auto|docker|http]
#                          [--timeout <s>] [--health-path <p>] [--health-port <p>]
#                          [--drain <s>] [--keep-old]
#   cctl rollout rolling   [mesmas flags, exceto --drain/--keep-old]
#   cctl rollout status
#   cctl rollout help

cmd_rollout() {
    local action="${1:-}"
    [[ $# -gt 0 ]] && shift

    case "${action}" in
        bluegreen) rollout_bluegreen "$@" ;;
        rolling)   rollout_rolling "$@" ;;
        status)    rollout_status "$@" ;;
        help|"")   _rollout_usage ;;
        *)
            msg_error "Acao desconhecida: '${action}'"
            _rollout_usage
            return 1
            ;;
    esac
}
