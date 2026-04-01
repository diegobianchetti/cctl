#!/bin/bash

# Variáveis de configuração
BASE=${POSTGRES_DB}
DATE=$(date +%Y%m%d-%H%M)
BACKUP_DIR="/var/backups/dspace"
RETENCAO="${BKP_RETENTION_DAYS:-3}"   # Dias de retenção para os backups (fornecido pelo env do docker-compose ou default=3) 
BACKUP_FILE="${BACKUP_DIR}/${BASE}-${DATE}.dump"

# Função auxiliar para executar o pg_dump com opções comuns
_pg_dump() {
    PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump -v -U ${POSTGRES_USER} \
    -d ${POSTGRES_DB} \
    --file=${BACKUP_FILE} \
    --format=custom
}

# se diretório não existe, cria
if [ ! -d "${BACKUP_DIR}" ]; then
    mkdir -p ${BACKUP_DIR}
    chown postgres -R ${BACKUP_DIR}/
fi

# executa dump
# pg_dump -v -U dspace $BASE -Fc -f ${BACKUP_DIR}/$BACKUP_FILE/
_pg_dump
md5sum ${BACKUP_FILE} > ${BACKUP_FILE}.md5
chown postgres -R ${BACKUP_DIR}/

# verifica periodo de retencao do backup
find ${BACKUP_DIR}/ -type f -mtime +${RETENCAO} -delete

exit 0
