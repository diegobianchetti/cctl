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
    local cron_dir="./cron" cron_listing cron_dir_rc

    # A existencia da fonte local e consultada pelo mesmo caminho privilegiado
    # da leitura. rc 1 significa diretorio ausente; rc 2 e erro de consulta
    # (por exemplo, sudo indisponivel), nunca motivo para usar o fallback.
    core_priv_run test -d "${cron_dir}"
    cron_dir_rc=$?
    if [[ ${cron_dir_rc} -eq 0 ]]; then
        # Capture a listagem inteira antes de processar qualquer entrada: ls
        # pode devolver dados parciais e rc != 0, que nao podem liberar um
        # teardown baseado numa lista incompleta.
        cron_listing="$(core_priv_run ls -1 -- "${cron_dir}")" || return $?

        local name cron_file
        while IFS= read -r name; do
            [[ "${name}" == *.cron ]] || continue
            cron_file="${cron_dir}/${name}"
            core_priv_run test -f "${cron_file}"
            cron_dir_rc=$?
            [[ ${cron_dir_rc} -eq 0 ]] || return "${cron_dir_rc}"
            cron_file="${CRON_DIR}/${name%.cron}-${prefix}"
            # Consulta privilegiada: falta de acesso a CRON_DIR nao pode virar
            # "nao ha cron" e liberar um teardown incompleto.
            if core_priv_run test -f "${cron_file}"; then
                echo "${cron_file}"
            else
                local test_rc=$?
                [[ ${test_rc} -eq 1 ]] && continue
                return "${test_rc}"
            fi
        done <<< "${cron_listing}"
        return 0
    elif [[ ${cron_dir_rc} -ne 1 ]]; then
        return "${cron_dir_rc}"
    fi

    # O fallback preserva a semantica best-effort historica, mas tambem faz a
    # listagem real com core_priv_run: CRON_DIR sem acesso ou lista parcial nao
    # e equivalente a "nenhum cron".
    core_priv_run test -d "${CRON_DIR}"
    cron_dir_rc=$?
    [[ ${cron_dir_rc} -eq 0 ]] || {
        [[ ${cron_dir_rc} -eq 1 ]] && return 0
        return "${cron_dir_rc}"
    }
    cron_listing="$(core_priv_run ls -1 -- "${CRON_DIR}")" || return $?

    local -a matches=()
    local name cron_file
    while IFS= read -r name; do
        [[ "${name}" == *-"${prefix}" ]] || continue
        cron_file="${CRON_DIR}/${name}"
        if core_priv_run test -f "${cron_file}"; then
            matches+=("${cron_file}")
        else
            cron_dir_rc=$?
            [[ ${cron_dir_rc} -eq 1 ]] && continue
            return "${cron_dir_rc}"
        fi
    done <<< "${cron_listing}"

    if [[ ${#matches[@]} -gt 0 ]]; then
        # ATENCAO: o stdout desta funcao E o stream de caminhos capturado por
        # cron_remove/cron_list. Um aviso sem `>&2` entra no stream como se
        # fosse um caminho de arquivo.
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
    local prefix="${COMPOSE_PROJECT_NAME}" removed=0 failed=0 cron_files
    if ! cron_files="$(_cron_system_files "${prefix}")"; then
        log_error "Nao foi possivel descobrir cron jobs de ${prefix}"
        return 1
    fi

    local cron_file
    while IFS= read -r cron_file; do
        [[ -n "${cron_file}" ]] || continue
        echo -e "  Removendo: ${CYAN}${cron_file}${RESET}"
        if core_priv_run rm -f "${cron_file}"; then
            removed=$((removed + 1))
        else
            log_error "Falha ao remover ${cron_file}"
            failed=1
        fi
    done <<< "${cron_files}"

    if [[ ${removed} -gt 0 && ${failed} -eq 0 ]]; then
        log_success "${removed} cron job(s) removido(s)"
    elif [[ ${removed} -eq 0 && ${failed} -eq 0 ]]; then
        log_debug "Nenhum cron job encontrado para ${prefix}"
    fi
    return "${failed}"
}

# Lista cron jobs do projeto (arquivos em CRON_DIR)
cron_list() {
    local prefix="${COMPOSE_PROJECT_NAME}"
    local found=0

    msg_header "Cron jobs do projeto ${prefix}"
    echo ""

    local cron_files cron_file
    if ! cron_files="$(_cron_system_files "${prefix}")"; then
        log_error "Nao foi possivel descobrir cron jobs de ${prefix}"
        return 1
    fi
    while IFS= read -r cron_file; do
        [[ -n "${cron_file}" ]] || continue
        found=$((found + 1))
        echo -e "  ${CYAN}${cron_file}${RESET}"
        grep -v '^#' "${cron_file}" | grep -v '^$' | sed 's/^/    /'
        echo ""
    done <<< "${cron_files}"

    if [[ ${found} -eq 0 ]]; then
        echo "  Nenhum cron job encontrado."
    fi
}
