#!/bin/bash
# scripts/backup.sh — Moodle: delega ao backup nativo da imagem
#
# Executado por "cctl backup" via backup_run (lib/backup.sh), que privilegia
# este script sobre o backup generico quando ele existe. backup_run invoca
# via "bash ./scripts/backup.sh" — um processo bash NOVO, que nao herda
# funcoes/arrays do cctl (bash nao exporta arrays como COMPOSE_FILES para
# subprocessos). Por isso este script sourceia as libs do proprio cctl
# (via CCTL_ROOT, que o entry point exporta) e reidrata o project.conf do
# diretorio atual antes de usar compose_exec — mesmo padrao de isolamento
# que o post-install.sh ja segue.
#
# Por que delegar em vez de usar o backup generico do cctl:
# a imagem moodle-db (moodle-db, GHCR) ja traz /usr/local/bin/backup-banco-moodle.sh
# (v2.0), que grava em /var/backups DENTRO do container — o volume
# "backup_db" do compose, que sobrevive a recriacao do container. E o MESMO
# mecanismo ja ligado no cron criado pelo "cctl install"
# (cron/backup-db.cron.template): "-b" (aplicacao+logs) seguido de "-r"
# (cleanup por BKP_RETENTION_DAYS). Reaproveitar aqui evita ter dois
# caminhos de backup divergentes para o mesmo banco.

set -euo pipefail

if [[ -z "${CCTL_ROOT:-}" ]]; then
    echo "[backup] CCTL_ROOT nao definido no ambiente — este script deve ser executado via 'cctl backup'." >&2
    exit 1
fi

# shellcheck source=/dev/null
source "${CCTL_ROOT}/lib/colors.sh"
# shellcheck source=/dev/null
source "${CCTL_ROOT}/lib/log.sh"
# shellcheck source=/dev/null
source "${CCTL_ROOT}/lib/compose.sh"

# COMPOSE_FILES (array) nao sobrevive ao exec de um bash novo — reidrata o
# manifest do diretorio atual (backup_run roda com cwd na raiz da instancia).
if [[ -z "${COMPOSE_FILES+x}" && -f "./project.conf" ]]; then
    # shellcheck source=/dev/null
    source "./project.conf"
fi

if [[ -z "${DB_SERVICE:-}" ]]; then
    echo "[backup] DB_SERVICE nao definido em project.conf — abortando." >&2
    exit 1
fi

echo "[backup] Delegando ao backup nativo do container ${DB_SERVICE} (backup-banco-moodle.sh -b && -r)..."

rc=0
compose_exec exec -T "${DB_SERVICE}" \
    bash -c "/usr/local/bin/backup-banco-moodle.sh -b && /usr/local/bin/backup-banco-moodle.sh -r" || rc=$?

if [[ ${rc} -eq 0 ]]; then
    echo "[backup] Concluido com sucesso (backup-banco-moodle.sh)."
else
    echo "[backup] Falhou (rc=${rc}) — ver saida do backup-banco-moodle.sh acima." >&2
fi

exit "${rc}"
