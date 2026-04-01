#!/bin/bash
# lib/log.sh — Logging estruturado (arquivo + stdout)

# Diretorio de logs (dentro da instancia ou /tmp para init)
CCTL_LOG_DIR="${CCTL_INSTANCE_DIR:-.}/logs"
CCTL_LOG_FILE=""

# Inicializa logging para arquivo
log_init() {
    local command_name="${1:-cctl}"
    mkdir -p "${CCTL_LOG_DIR}" 2>/dev/null || CCTL_LOG_DIR="/tmp"
    CCTL_LOG_FILE="${CCTL_LOG_DIR}/${command_name}-$(date +%Y%m%d-%H%M%S).log"
}

# Escreve no log (arquivo + stdout opcional)
_log_write() {
    local level="$1"
    shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local entry="[${timestamp}] [${level}] $*"

    # Sempre grava no arquivo se inicializado
    if [[ -n "${CCTL_LOG_FILE}" ]]; then
        echo "${entry}" >> "${CCTL_LOG_FILE}"
    fi
}

# Funcoes de log por nivel (gravam no arquivo E mostram na tela)
log_info() {
    _log_write "INFO" "$@"
    msg_info "$@"
}

log_success() {
    _log_write "OK" "$@"
    msg_success "$@"
}

log_warn() {
    _log_write "AVISO" "$@"
    msg_warn "$@"
}

log_error() {
    _log_write "ERRO" "$@"
    msg_error "$@"
}

# Log silencioso (so arquivo, sem stdout)
log_debug() {
    _log_write "DEBUG" "$@"
}
