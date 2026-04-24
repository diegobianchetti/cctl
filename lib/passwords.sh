#!/bin/bash
# lib/passwords.sh — Geracao de senhas seguras e injecao no .env

# Gera uma senha aleatoria segura
# Uso: passwords_generate [tamanho]
passwords_generate() {
    local length="${1:-32}"

    # Usa /dev/urandom com caracteres alfanumericos + simbolos seguros
    tr -dc 'A-Za-z0-9!@#%^&*_-' < /dev/urandom | head -c "${length}" || true
}

# Gera e injeta senhas para todas as variaveis em AUTO_PASSWORD_VARS do manifest
# Substitui placeholders no formato _VARIAVEL_ pelo valor gerado
passwords_generate_all() {
    if [[ -z "${AUTO_PASSWORD_VARS+x}" || ${#AUTO_PASSWORD_VARS[@]} -eq 0 ]]; then
        log_debug "Nenhuma variavel de senha definida no manifest (AUTO_PASSWORD_VARS)"
        return 0
    fi

    msg_step "SENHAS" "Gerando senhas..."

    local var password
    for var in "${AUTO_PASSWORD_VARS[@]}"; do
        # Verifica se ja tem um valor real (nao e placeholder)
        local current_value="${!var:-}"
        if [[ -n "${current_value}" && "${current_value}" != "_${var}_" ]]; then
            log_debug "Variavel ${var} ja tem valor definido, pulando"
            continue
        fi

        password=$(passwords_generate 32)
        env_set_var "${var}" "${password}"
        log_success "Senha gerada para ${var}"
    done
}
