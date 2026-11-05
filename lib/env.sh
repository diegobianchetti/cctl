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

# Grava uma chave do .env literalmente. O arquivo deve ser regular e local:
# o mktemp cria o substituto em modo 0600, pertencente ao usuario corrente.
# Chaves duplicadas sao todas atualizadas; symlinks sao recusados.
env_set_var() {
    local key="$1" value="$2" env_file tmp line content found=false
    env_file=$(_env_file_path)

    if [[ -L "${env_file}" ]]; then
        log_error "Arquivo .env nao pode ser symlink"
        return 1
    fi
    if [[ ! -f "${env_file}" ]]; then
        log_error "Arquivo .env nao encontrado"
        return 1
    fi
    if [[ ! "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || [[ "${value}" == *$'\n'* ]]; then
        log_error "Chave ou valor invalido para .env"
        return 1
    fi

    tmp="$(mktemp "$(dirname "${env_file}")/.env.cctl.XXXXXX")" || {
        log_error "Falha ao preparar escrita do .env"
        return 1
    }
    # Leitura real e integral antes de autorizar o rename: -r isolado nao
    # detecta erro de abertura/leitura quando o chamador usa if ou ||. A
    # captura normaliza newlines finais e linhas vazias finais; efeito cosmetico
    # aceito, sem alterar o valor das configuracoes.
    if ! content="$(cat -- "${env_file}")"; then
        rm -f "${tmp}"
        log_error "Falha ao ler .env original"
        return 1
    fi
    while IFS= read -r line || [[ -n "${line}" ]]; do
        if [[ "${line}" == "${key}="* ]]; then
            printf '%s=%s\n' "${key}" "${value}" >> "${tmp}" || { rm -f "${tmp}"; log_error "Falha ao escrever .env"; return 1; }
            found=true
        else
            printf '%s\n' "${line}" >> "${tmp}" || { rm -f "${tmp}"; log_error "Falha ao escrever .env"; return 1; }
        fi
    done <<< "${content}"
    [[ "${found}" == true ]] || printf '%s=%s\n' "${key}" "${value}" >> "${tmp}" || { rm -f "${tmp}"; log_error "Falha ao escrever .env"; return 1; }
    if ! mv -f "${tmp}" "${env_file}"; then
        rm -f "${tmp}"
        log_error "Falha ao gravar .env"
        return 1
    fi
    local verified=false
    while IFS= read -r line; do
        [[ "${line}" == "${key}=${value}" ]] && { verified=true; break; }
    done < "${env_file}"
    if [[ "${verified}" != true ]]; then
        rm -f "${tmp}"
        log_error "Falha ao conferir gravacao de ${key} no .env"
        return 1
    fi
    export "${key}=${value}"
    log_debug "Variavel setada: ${key}"
}
