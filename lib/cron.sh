#!/bin/bash
# lib/cron.sh — Instalar/remover crontab entries no host
#
# Caminho primario: arquivos em CRON_DIR (default /etc/cron.d), roteados por
# core_priv_run (lib/core.sh) — so escala privilegio quando o diretorio nao e
# gravavel pelo usuario atual.
#
# Fallback (usuario sem privilegio de root, ex: so no grupo docker): quando
# CRON_DIR nao e gravavel E nao ha privilegio disponivel de forma
# nao-interativa (core_sudo_usable, lib/core.sh), os jobs sao instalados na
# crontab do proprio usuario em vez de falhar o install. O
# formato muda: um arquivo de /etc/cron.d tem um campo de USUARIO entre a
# agenda e o comando ("<agenda> root <comando>"); a crontab do usuario NAO
# tem esse campo ("<agenda> <comando>") — ver _cron_convert_job_line.
#
# Idempotencia do fallback: cada bloco inserido na crontab do usuario e
# demarcado por comentarios "# cctl:begin:<projeto>:<cron>" /
# "# cctl:end:<projeto>:<cron>". Reinstalar remove o bloco anterior do mesmo
# projeto/cron antes de reinserir (ver _cron_strip_user_block).

# Verifica se CRON_DIR e utilizavel sem prompt de senha: gravavel direto, ou
# privilegio de root disponivel de forma nao-interativa (core_sudo_usable).
# Usada para decidir o fallback ANTES de chamar core_priv_run — evita que
# uma sessao interativa fique presa esperando senha que o usuario nem tem.
_cron_dir_usable() {
    local dir="$1"
    [[ -w "${dir}" ]] && return 0
    core_sudo_usable
}

# Reconhece uma linha de job de /etc/cron.d (agenda + usuario + comando).
# Rejeita linhas vazias, comentarios e atribuicoes de variavel (SHELL=,
# PATH=, etc.) — essas sao copiadas verbatim para a crontab do usuario.
_cron_is_job_line() {
    local line="$1"
    [[ -z "${line// /}" ]] && return 1
    [[ "${line}" =~ ^[[:space:]]*# ]] && return 1
    [[ "${line}" =~ ^[[:space:]]*[A-Za-Z_][A-Za-Z0-9_]*= ]] && return 1
    return 0
}

# Remove o campo de usuario de uma linha de job de /etc/cron.d, produzindo o
# formato de crontab de usuario. Agenda pode ser 5 campos (min hora dom mes
# dow) ou uma macro "@algo" (1 campo). Linhas que nao batem com o numero
# minimo de campos esperado sao devolvidas sem alteracao (defensivo).
_cron_convert_job_line() {
    local line="$1"
    local -a f
    read -r -a f <<< "${line}"
    local n=${#f[@]}
    local sched_fields=5
    [[ "${f[0]}" == @* ]] && sched_fields=1

    if (( n < sched_fields + 2 )); then
        echo "${line}"
        return
    fi

    local i out=""
    for (( i = 0; i < sched_fields; i++ )); do
        out+="${f[i]} "
    done
    # pula f[sched_fields] (campo de usuario)
    for (( i = sched_fields + 1; i < n; i++ )); do
        out+="${f[i]} "
    done
    echo "${out% }"
}

# Remove um bloco "# cctl:begin:<marker>" .. "# cctl:end:..." do conteudo de
# uma crontab (idempotencia: reinstalar nao duplica).
#
# Casa a linha de abertura por igualdade exata (nao por prefixo): com
# index($0, b) == 1, o marcador "# cctl:begin:moodle:backup" tambem casava
# "# cctl:begin:moodle:backup-db" (prefixo de outro cron_name), apagando o
# bloco errado a cada reinstalacao. Se o marcador de abertura aparecer sem um
# "# cctl:end:" correspondente (crontab corrompida/editada a mao), a versao
# antiga descartava o resto da crontab do usuario a partir dali; aqui o
# bloco original e preservado sem alteracao e um aviso e emitido.
_cron_strip_user_block() {
    local content="$1"
    local begin_marker="$2"

    local result rc
    result="$(awk -v b="${begin_marker}" '
        $0 == b { skip = 1; next }
        skip == 1 && /^# cctl:end:/ { skip = 0; next }
        skip != 1 { print }
        END { if (skip == 1) exit 2 }
    ' <<< "${content}")"
    rc=$?

    if [[ ${rc} -eq 2 ]]; then
        log_warn "Marcador '${begin_marker}' encontrado na crontab do usuario sem o '# cctl:end:' correspondente — bloco preservado sem alteracao para nao descartar o restante da crontab."
        printf '%s' "${content}"
        return
    fi

    printf '%s' "${result}"
}

# Instala um unico cron_file na crontab do usuario atual, sob os marcadores
# do projeto/cron_name. Nao falha o install do projeto por conta disso (os
# chamadores em cron_install ignoram o retorno de proposito), mas retorna 1 e
# loga erro explicito quando o job efetivamente nao foi agendado — nunca
# reporta sucesso sem confirmar o resultado.
_cron_install_user_crontab() {
    local project="$1" cron_name="$2" cron_file="$3"
    local begin_marker="# cctl:begin:${project}:${cron_name}"
    local end_marker="# cctl:end:${project}:${cron_name}"

    if ! command -v crontab >/dev/null 2>&1; then
        log_error "Sem privilegio de escrita em ${CRON_DIR}, sem privilegio de root disponivel e sem 'crontab' instalado neste host — job '${cron_name}' NAO foi agendado. Instale um daemon de cron com 'crontab' ou libere privilegio para ${CRON_DIR}."
        return 1
    fi

    local block
    block="$(
        echo "${begin_marker}"
        local line
        while IFS= read -r line || [[ -n "${line}" ]]; do
            if _cron_is_job_line "${line}"; then
                _cron_convert_job_line "${line}"
            else
                echo "${line}"
            fi
        done < "${cron_file}"
        echo "${end_marker}"
    )"

    local current
    current="$(crontab -l 2>/dev/null || true)"
    current="$(_cron_strip_user_block "${current}" "${begin_marker}")"

    if ! { [[ -n "${current}" ]] && printf '%s\n' "${current}"; printf '%s\n' "${block}"; } | crontab -; then
        log_error "Falha ao instalar o job '${cron_name}' na crontab do usuario atual ($(whoami)) — o comando 'crontab -' retornou erro. O job NAO foi agendado."
        return 1
    fi

    log_warn "Sem privilegio de escrita em ${CRON_DIR} e sem privilegio de root disponivel — job '${cron_name}' instalado na crontab do usuario atual ($(whoami)). Para remover: cctl cron remove (ou 'crontab -e', bloco marcado '${begin_marker}')."
}

# Remove todas as entradas do projeto na crontab do usuario atual. Retorna 0
# se algo foi removido, 1 se nao havia nada a remover (para o chamador
# decidir se conta como "removido").
_cron_remove_user_crontab() {
    local prefix="$1"
    local current
    current="$(crontab -l 2>/dev/null || true)"
    [[ -z "${current}" ]] && return 1

    local begin_marker="# cctl:begin:${prefix}:"
    local filtered
    filtered="$(awk -v b="${begin_marker}" '
        index($0, b) == 1 { skip = 1 }
        skip != 1 { print }
        /^# cctl:end:/ { skip = 0 }
    ' <<< "${current}")"

    [[ "${filtered}" == "${current}" ]] && return 1

    if [[ -n "${filtered}" ]]; then
        printf '%s\n' "${filtered}" | crontab -
    else
        crontab -r 2>/dev/null || true
    fi
    return 0
}

# Lista as entradas do projeto na crontab do usuario atual (sem alterar
# nada). Devolve vazio se nao houver.
_cron_list_user_crontab() {
    local prefix="$1"
    local current
    current="$(crontab -l 2>/dev/null || true)"
    [[ -z "${current}" ]] && return 0

    local begin_marker="# cctl:begin:${prefix}:"
    awk -v b="${begin_marker}" '
        index($0, b) == 1 { inblock = 1 }
        inblock { print }
        /^# cctl:end:/ { inblock = 0 }
    ' <<< "${current}"
}

# Instala cron jobs a partir dos arquivos em cron/
cron_install() {
    local cron_dir="./cron"

    if [[ ! -d "${cron_dir}" ]]; then
        log_debug "Diretorio cron/ nao encontrado"
        return 0
    fi

    local cron_file
    for cron_file in "${cron_dir}"/*.cron; do
        [[ -f "${cron_file}" ]] || continue

        local cron_name
        cron_name=$(basename "${cron_file}" .cron)

        if _cron_dir_usable "${CRON_DIR}"; then
            local dest="${CRON_DIR}/${cron_name}-${COMPOSE_PROJECT_NAME}"
            if core_priv_run install -m 644 "${cron_file}" "${dest}"; then
                log_success "Cron instalado: ${dest}"
            else
                log_warn "Falha ao instalar em ${dest}, tentando crontab do usuario"
                _cron_install_user_crontab "${COMPOSE_PROJECT_NAME}" "${cron_name}" "${cron_file}" || true
            fi
        else
            _cron_install_user_crontab "${COMPOSE_PROJECT_NAME}" "${cron_name}" "${cron_file}" || true
        fi
    done
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

# Remove todos os cron jobs do projeto (CRON_DIR + crontab do usuario).
# So conta como removido o que o `rm` de fato confirmou — nao promete
# sucesso por arquivo que continuou no disco (ex.: CRON_DIR nao gravavel e
# sem privilegio).
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

    if _cron_remove_user_crontab "${prefix}"; then
        echo -e "  Removido: ${CYAN}crontab do usuario ($(whoami))${RESET}"
        removed=$((removed + 1))
    fi

    if [[ ${removed} -gt 0 ]]; then
        log_success "${removed} cron job(s) removido(s)"
    else
        log_debug "Nenhum cron job encontrado para ${prefix}"
    fi
}

# Lista cron jobs do projeto (CRON_DIR + crontab do usuario)
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

    local user_entries
    user_entries="$(_cron_list_user_crontab "${prefix}")"
    if [[ -n "${user_entries}" ]]; then
        found=$((found + 1))
        echo -e "  ${CYAN}crontab do usuario ($(whoami))${RESET}"
        sed 's/^/    /' <<< "${user_entries}"
        echo ""
    fi

    if [[ ${found} -eq 0 ]]; then
        echo "  Nenhum cron job encontrado."
    fi
}
