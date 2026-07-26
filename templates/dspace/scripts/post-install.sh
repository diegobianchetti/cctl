#!/bin/bash
# scripts/post-install.sh — DSpace: acoes pos-instalacao (ambiente dev/teste)
#
# Executado automaticamente pelo cctl install apos subir os containers.

set -euo pipefail

# Ajusta DSPACE_DISPLAY_NAME no .env se ainda for placeholder
_set_display_name() {
    local env_file="${ENV_FILE:?}"
    if grep -q '_DSPACE_DISPLAY_NAME_' "${env_file}" 2>/dev/null; then
        local display_name="Repositorio ${CLIENT_NAME} - DSpace"
        sed -i "s|_DSPACE_DISPLAY_NAME_|${display_name}|g" "${env_file}"
        echo "[post-install] DSPACE_DISPLAY_NAME definido: ${display_name}"
    fi
}

_set_display_name
