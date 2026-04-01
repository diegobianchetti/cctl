#!/bin/bash
# scripts/post-install.sh — DSpace: acoes pos-instalacao
#
# Executado automaticamente pelo cctl install apos subir os containers.
# Variaveis do .env e project.conf ja estao disponiveis no ambiente.

set -euo pipefail

# Copia configs do DSpace backend para o diretorio de deploy
_sync_dspace_config() {
    local config_src="./custom-DSpace/dspace/config"
    local config_dst="./docker/dspace/config"

    if [[ -d "${config_src}" ]]; then
        mkdir -p "${config_dst}"
        cp -r "${config_src}/"* "${config_dst}/"
        echo "[post-install] Configs do DSpace sincronizadas: ${config_dst}"
    fi
}

# Ajusta DSPACE_DISPLAY_NAME no .env se ainda for placeholder
_set_display_name() {
    local env_file="${ENV_FILE:?}"
    if grep -q '_DSPACE_DISPLAY_NAME_' "${env_file}" 2>/dev/null; then
        local display_name="Repositorio ${CLIENT_NAME} - DSpace"
        sed -i "s|_DSPACE_DISPLAY_NAME_|${display_name}|g" "${env_file}"
        echo "[post-install] DSPACE_DISPLAY_NAME definido: ${display_name}"
    fi
}

_sync_dspace_config
_set_display_name
