#!/bin/bash
# lib/cron.sh — Instalar/remover/listar cron jobs do projeto no host
#
# Os jobs ficam em arquivos de CRON_DIR (default /etc/cron.d), um por job:
# ${CRON_DIR}/<nome>-<projeto>. A escrita passa por core_priv_run
# (lib/core.sh), que so escala para sudo quando o diretorio nao e gravavel
# pelo usuario atual. Se nao der para instalar, cron_install retorna 1.

# Instala cron jobs a partir dos arquivos em cron/. Cada job vai para
# ${CRON_DIR}/<nome>-<projeto>. Se algum job nao puder ser instalado, loga
# o erro e retorna 1 no fim (o install do projeto falha).
cron_install() {
    local cron_dir="./cron"

    if [[ ! -d "${cron_dir}" ]]; then
        log_debug "Diretorio cron/ nao encontrado"
        return 0
    fi

    local failed=0
    local cron_file
    for cron_file in "${cron_dir}"/*.cron; do
        [[ -f "${cron_file}" ]] || continue

        local cron_name dest
        cron_name=$(basename "${cron_file}" .cron)
        dest="${CRON_DIR}/${cron_name}-${COMPOSE_PROJECT_NAME}"

        if core_priv_run install -m 644 "${cron_file}" "${dest}"; then
            log_success "Cron instalado: ${dest}"
        else
            log_error "Falha ao instalar o cron job '${cron_name}' em ${dest} — o job NAO foi agendado. Confira as permissoes de ${CRON_DIR} e o sudo."
            failed=1
        fi
    done

    return "${failed}"
}

# Enumera os caminhos exatos em CRON_DIR pertencentes ao projeto atual —
# usado por cron_remove/cron_list. Caminho normal: deriva o nome de cada
# job a partir de ./cron/*.cron (a mesma fonte que cron_install usa),
# montando "${CRON_DIR}/<cron_name>-<prefix>". NUNCA globa CRON_DIR pelo
# sufixo "*-<prefix>" no caminho normal — esse glob so ancora a direita
# (nome do projeto) e e irrestrito a esquerda, entao "moodle" tambem casaria
# "prod-moodle" (colisao de sufixo, com potencial destrutivo em
# cron_remove).
#
# Fallback best-effort (com aviso): se ./cron nao existir neste diretorio
# (comando rodado fora do diretorio da instancia, ou instancia sem cron
# nenhum), cai para o glob antigo em CRON_DIR.
_cron_system_files() {
    local prefix="$1"
    local cron_dir="./cron"

    if [[ -d "${cron_dir}" ]]; then
        local f name cron_file
        for f in "${cron_dir}"/*.cron; do
            [[ -f "${f}" ]] || continue
            name="$(basename "${f}" .cron)"
            cron_file="${CRON_DIR}/${name}-${prefix}"
            [[ -f "${cron_file}" ]] || continue
            echo "${cron_file}"
        done
        return 0
    fi

    local -a matches=()
    local cron_file
    for cron_file in "${CRON_DIR}"/*-"${prefix}"; do
        [[ -f "${cron_file}" ]] && matches+=("${cron_file}")
    done

    if [[ ${#matches[@]} -gt 0 ]]; then
        # ATENCAO: o stdout desta funcao E o stream de caminhos consumido por
        # `done < <(_cron_system_files ...)` em cron_remove/cron_list. Um aviso
        # sem `>&2` entra no stream como se fosse um caminho de arquivo:
        # `msg_warn` (lib/colors.sh:22) escreve em stdout — so `msg_error` usa
        # stderr. Sem o redirecionamento, o chamador tentaria `rm -f` no texto
        # do aviso, contaria uma remocao que nao houve, e o `dirname` do texto
        # cairia num diretorio nao gravavel, podendo disparar `sudo` interativo
        # pedindo senha. (`_log_write` registra em arquivo, nao e afetado.)
        log_warn "Diretorio ./cron nao encontrado nesta pasta — usando padrao best-effort em ${CRON_DIR} ('*-${prefix}'), que pode casar prefixos de outro projeto (ex.: 'prod-${prefix}'). Rode a partir do diretorio da instancia para o casamento exato." >&2
        local m
        for m in "${matches[@]}"; do
            echo "${m}"
        done
    fi
}

# Remove todos os cron jobs do projeto (arquivos em CRON_DIR).
# So conta como removido o que o `rm` de fato confirmou — nao promete
# sucesso por arquivo que continuou no disco.
cron_remove() {
    local prefix="${COMPOSE_PROJECT_NAME}"
    local removed=0

    local cron_file
    while IFS= read -r cron_file; do
        [[ -n "${cron_file}" ]] || continue
        echo -e "  Removendo: ${CYAN}${cron_file}${RESET}"
        if core_priv_run rm -f "${cron_file}"; then
            removed=$((removed + 1))
        else
            log_error "Falha ao remover ${cron_file}"
        fi
    done < <(_cron_system_files "${prefix}")

    if [[ ${removed} -gt 0 ]]; then
        log_success "${removed} cron job(s) removido(s)"
    else
        log_debug "Nenhum cron job encontrado para ${prefix}"
    fi
}

# Lista cron jobs do projeto (arquivos em CRON_DIR)
cron_list() {
    local prefix="${COMPOSE_PROJECT_NAME}"
    local found=0

    msg_header "Cron jobs do projeto ${prefix}"
    echo ""

    local cron_file
    while IFS= read -r cron_file; do
        [[ -n "${cron_file}" ]] || continue
        found=$((found + 1))
        echo -e "  ${CYAN}${cron_file}${RESET}"
        grep -v '^#' "${cron_file}" | grep -v '^$' | sed 's/^/    /'
        echo ""
    done < <(_cron_system_files "${prefix}")

    if [[ ${found} -eq 0 ]]; then
        echo "  Nenhum cron job encontrado."
    fi
}
