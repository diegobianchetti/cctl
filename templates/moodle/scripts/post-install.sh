#!/bin/bash
# scripts/post-install.sh — Moodle: acoes pos-instalacao
#
# Executado automaticamente pelo cctl install apos subir os containers.
# Variaveis do .env e project.conf ja estao disponiveis no ambiente.

set -euo pipefail

# Instala logrotate para logs do Apache
_install_logrotate() {
    local logrotate_src="./cron/logrotate-apache"
    local logrotate_dst="/etc/logrotate.d/rotate-apache-logs-${COMPOSE_PROJECT_NAME}"

    if [[ -f "${logrotate_src}" ]]; then
        sudo cp "${logrotate_src}" "${logrotate_dst}"
        sudo chmod 644 "${logrotate_dst}"
        echo "[post-install] Logrotate instalado: ${logrotate_dst}"
    fi
}

_install_logrotate
