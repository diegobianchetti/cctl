#!/bin/bash
# scripts/post-install.sh — Moodle: acoes pos-instalacao
#
# Executado automaticamente pelo cctl install (_install_post_hook, via
# "bash ./scripts/post-install.sh") — um processo bash NOVO, que nao herda
# funcoes/variaveis do cctl (so CCTL_ROOT e exportado pelo entry point). Por
# isso este script sourceia as libs do proprio cctl e reidrata o
# project.conf do diretorio atual — mesmo padrao de isolamento que
# scripts/backup.sh ja segue.

set -euo pipefail

if [[ -z "${CCTL_ROOT:-}" ]]; then
    echo "[post-install] CCTL_ROOT nao definido no ambiente — este script deve ser executado via 'cctl install'." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "${CCTL_ROOT}/cctl.conf"
# shellcheck source=/dev/null
source "${CCTL_ROOT}/lib/colors.sh"
# shellcheck source=/dev/null
source "${CCTL_ROOT}/lib/log.sh"
# shellcheck source=/dev/null
source "${CCTL_ROOT}/lib/core.sh"

if [[ -z "${COMPOSE_PROJECT_NAME:-}" && -f "./project.conf" ]]; then
    # shellcheck source=/dev/null
    source "./project.conf"
fi

if [[ -z "${COMPOSE_PROJECT_NAME:-}" ]]; then
    echo "[post-install] COMPOSE_PROJECT_NAME nao definido (nem no ambiente, nem em ./project.conf) — abortando." >&2
    exit 1
fi

# Instala logrotate para logs do Apache. Raiz-only (sem fallback de
# crontab de usuario como lib/cron.sh) — se o destino nao for gravavel e nao
# houver privilegio de root disponivel, apenas avisa: o arquivo gerado no
# projeto (./cron/logrotate-apache) fica disponivel para instalacao manual.
_install_logrotate() {
    local logrotate_src="./cron/logrotate-apache"
    local logrotate_dst="${LOGROTATE_DIR}/rotate-apache-logs-${COMPOSE_PROJECT_NAME}"

    [[ -f "${logrotate_src}" ]] || return 0

    if core_priv_run install -m 644 "${logrotate_src}" "${logrotate_dst}"; then
        echo "[post-install] Logrotate instalado: ${logrotate_dst}"
    else
        echo "[post-install] AVISO: sem privilegio para instalar logrotate em ${logrotate_dst}. Instale manualmente como root: cp ${logrotate_src} ${logrotate_dst} && chmod 644 ${logrotate_dst}" >&2
    fi
}

_install_logrotate
