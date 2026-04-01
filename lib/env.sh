#!/bin/bash
# lib/env.sh — Load .env, render {{PLACEHOLDERS}}, validar vars

# Resolve o path do .env (suporta ENV_FILE do project.conf)
_env_file_path() {
    echo "./${ENV_FILE:-.env}"
}

# Carrega variaveis do .env de forma segura
env_load() {
    local env_file
    env_file=$(_env_file_path)

    if [[ ! -f "${env_file}" ]]; then
        log_debug "Arquivo .env nao encontrado (pode ser esperado neste contexto)"
        return 0
    fi

    while IFS= read -r line; do
        # Ignora linhas vazias e comentarios
        [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
        # Valida formato KEY=VALUE
        if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
        fi
    done < "${env_file}"

    log_debug ".env carregado: ${env_file}"
}

# Renderiza um arquivo de template substituindo {{PLACEHOLDERS}} pelos valores do .env
env_render_template() {
    local template_file="$1"
    local output_file="$2"

    if [[ ! -f "${template_file}" ]]; then
        log_error "Template nao encontrado: ${template_file}"
        return 1
    fi

    local content
    content=$(<"${template_file}")

    # Le o .env e substitui cada {{KEY}} pelo valor
    local env_file
    env_file=$(_env_file_path)
    if [[ -f "${env_file}" ]]; then
        while IFS= read -r line; do
            [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue
            if [[ "${line}" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"
                content="${content//\{\{${key}\}\}/${value}}"
            fi
        done < "${env_file}"
    fi

    # Verifica se restaram placeholders nao substituidos
    local remaining
    remaining=$(echo "${content}" | grep -oP '\{\{[A-Za-z_][A-Za-z0-9_]*\}\}' | sort -u || true)
    if [[ -n "${remaining}" ]]; then
        log_warn "Placeholders nao substituidos em ${template_file}:"
        echo "${remaining}" | while read -r ph; do
            echo "  - ${ph}"
        done
    fi

    echo "${content}" > "${output_file}"
    log_debug "Template renderizado: ${template_file} -> ${output_file}"
}

# Renderiza todos os templates definidos no manifest (TEMPLATE_FILES)
env_render_all_templates() {
    if [[ -z "${TEMPLATE_FILES+x}" ]]; then
        log_debug "Nenhum TEMPLATE_FILES definido no manifest"
        return 0
    fi

    local entry src dst
    for entry in "${TEMPLATE_FILES[@]}"; do
        src="${entry%%:*}"
        dst="${entry##*:}"
        mkdir -p "$(dirname "${dst}")"
        env_render_template "${src}" "${dst}"
    done
}

# Valida que todas as variaveis obrigatorias estao definidas no .env
env_check_required_vars() {
    if [[ -z "${REQUIRED_VARS+x}" ]]; then
        return 0
    fi

    local missing=()
    local var
    for var in "${REQUIRED_VARS[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("${var}")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Variaveis obrigatorias nao definidas no .env:"
        for var in "${missing[@]}"; do
            echo "  - ${var}"
        done
        return 1
    fi

    return 0
}

# Substitui placeholder de senha no .env (ex: _POSTGRES_PASSWORD_ -> valor real)
env_set_var() {
    local key="$1"
    local value="$2"
    local env_file
    env_file=$(_env_file_path)

    if [[ ! -f "${env_file}" ]]; then
        log_error "Arquivo .env nao encontrado"
        return 1
    fi

    if grep -q "^${key}=" "${env_file}"; then
        # Atualiza valor existente
        sed -i "s|^${key}=.*|${key}=${value}|" "${env_file}"
    else
        # Adiciona nova variavel
        echo "${key}=${value}" >> "${env_file}"
    fi

    # Exporta no ambiente atual
    export "${key}=${value}"
    log_debug "Variavel setada: ${key}"
}
