#!/bin/bash
# lib/vhost.sh — modulo unico dono do vhost do nginx-proxy (F2.2)
#
# Ate a F2.2, tres caminhos diferentes escreviam
# ${NGINX_VHOSTS_DIR}/${COMPOSE_PROJECT_NAME}.conf com garantias distintas
# (um deles — nginx_enable_site — apagava o vhost em vez de restaurar em
# falha, ver WORK_LOG). Este modulo e agora o UNICO dono do arquivo: toda
# escrita/remocao do vhost passa por uma das tres funcoes publicas abaixo,
# que compartilham a mesma garantia via _vhost_apply.
#
# Garantia unica (ordem exata):
#   1. Backup (se o destino existe): core_priv_run cp -p <dst> <backup_dir>/
#   2. "Escreve so se mudou": se o destino existe e o conteudo a gravar e
#      identico (cmp -s), pula aplicar+reload e retorna sucesso.
#   3. Aplicar: core_priv_run cp <tmpfile> <dst> — SEMPRE `cp` por cima do
#      arquivo existente, NUNCA `mv`/rename (preserva inode/symlink do
#      destino). Em falha, restaura o backup antes de descarta-lo.
#   4. Testar+recarregar (nginx_test_and_reload, lib/nginx.sh). Em falha,
#      restaura o backup, tenta recarregar de novo (best-effort) e retorna 1.
#   5. Sucesso: limpa o diretorio de backup e retorna 0.
#
# Toda escrita/leitura do vhost passa por core_priv_run (lib/core.sh) — nunca
# `sudo` cru. O mktemp -d do backup e sempre limpo, em todos os caminhos de
# saida (sucesso, falha de backup, falha de aplicacao, falha de teste).

# _vhost_apply <dst> <tmpfile|""> <backup_fail_msg> <apply_fail_msg> <test_fail_msg>
#
# Helper interno que implementa a garantia unica. Uso:
#   - <tmpfile> nao-vazio: ESCREVE o conteudo de <tmpfile> em <dst> (modo
#     usado por vhost_write e vhost_switch_target).
#   - <tmpfile> vazio (""): REMOVE <dst> (modo usado por vhost_remove).
# As tres mensagens de log sao responsabilidade do chamador (cada wrapper
# preserva o texto que os testes/telas ja esperam para o seu caminho).
_vhost_apply() {
    local dst="$1" tmpfile="$2" backup_fail_msg="$3" apply_fail_msg="$4" test_fail_msg="$5"

    local backup_dir
    backup_dir="$(mktemp -d "${TMPDIR:-/tmp}/cctl_vhost_backup.XXXXXX")" || {
        log_error "Falha ao criar diretorio de backup temporario"
        [[ -n "${tmpfile}" ]] && rm -f "${tmpfile}"
        return 1
    }

    local had_backup=false
    if [[ -f "${dst}" ]]; then
        if ! core_priv_run cp -p "${dst}" "${backup_dir}/"; then
            log_error "${backup_fail_msg}"
            rm -rf "${backup_dir}"
            [[ -n "${tmpfile}" ]] && rm -f "${tmpfile}"
            return 1
        fi
        had_backup=true
    fi

    # "Escreve so se mudou": so se aplica ao caminho de escrita, com destino
    # ja existente e conteudo identico ao que seria gravado.
    if [[ -n "${tmpfile}" && "${had_backup}" == "true" ]] && cmp -s "${tmpfile}" "${dst}"; then
        rm -f "${tmpfile}"
        rm -rf "${backup_dir}"
        return 0
    fi

    if [[ -n "${tmpfile}" ]]; then
        # vhost e config (nao segredo): modo 644, como o `cp` antigo do
        # site.conf produzia na primeira instalacao. O mktemp nasce 600;
        # sem isto, a primeira instalacao deixaria o vhost 600 (mudanca
        # silenciosa de permissao — observacao O1 da auditoria).
        chmod 644 "${tmpfile}"
        if ! core_priv_run cp "${tmpfile}" "${dst}"; then
            # `cp` trunca o destino antes de escrever: uma falha aqui
            # (ENOSPC, EIO, ticket do `sudo -n` perdido, sinal) pode deixar
            # o vhost meio-escrito ou vazio. Restaurar ANTES de descartar o
            # backup — nunca descartar o unico backup sem tentar recuperar.
            log_error "${apply_fail_msg}"
            rm -f "${tmpfile}"
            if _vhost_restore "${dst}" "${backup_dir}" "${had_backup}"; then
                rm -rf "${backup_dir}"
            fi
            return 1
        fi
        rm -f "${tmpfile}"
    else
        core_priv_run rm -f "${dst}"
    fi

    if nginx_test_and_reload; then
        rm -rf "${backup_dir}"
        return 0
    fi

    log_error "${test_fail_msg}"
    if _vhost_restore "${dst}" "${backup_dir}" "${had_backup}"; then
        nginx_test_and_reload || true
        rm -rf "${backup_dir}"
    fi
    return 1
}

# _vhost_restore <dst> <backup_dir> <had_backup>
#
# Restaura <dst> a partir do backup, se ele existir. Se <dst> nao existia
# antes da operacao (had_backup=false — ex.: primeira instalacao, sem vhost
# previo), "restaurar" significa devolver o estado original: ausencia do
# arquivo (rm -f), nunca deixar o conteudo novo/parcial para tras.
_vhost_restore() {
    local dst="$1" backup_dir="$2" had_backup="$3"

    if [[ "${had_backup}" == "true" ]]; then
        if ! core_priv_run cp -p "${backup_dir}/$(basename "${dst}")" "${dst}"; then
            log_error "Falha ao restaurar vhost de backup para ${dst} — vhost pode estar em estado inconsistente. Backup preservado em: ${backup_dir}"
            return 1
        fi
    else
        core_priv_run rm -f "${dst}"
    fi
    return 0
}

# vhost_write <src> <dst>
#
# Escreve o conteudo de <src> em <dst> com a garantia unica. Usado por
# nginx_enable_site (lib/nginx.sh) para o vhost de instalacao/bootstrap ACME.
vhost_write() {
    local src="$1" dst="$2"

    local tmpfile
    tmpfile="$(mktemp)" || {
        log_error "Falha ao criar arquivo temporario"
        return 1
    }

    if ! cp "${src}" "${tmpfile}"; then
        log_error "Falha ao copiar configuracao nginx para ${dst}"
        rm -f "${tmpfile}"
        return 1
    fi

    _vhost_apply "${dst}" "${tmpfile}" \
        "Falha ao criar backup do vhost ${dst}" \
        "Falha ao copiar configuracao nginx para ${dst}" \
        "Config nginx invalida! Restaurando..."
}

# vhost_regex_escape <texto>
#
# Escapa <texto> para entrar LITERAL numa regex estendida (grep -E / sed -E):
# os pontos de "proj-app.proj_net" nao podem casar "qualquer caractere". O
# hifen fica de fora de proposito (fora de colchetes ele ja e literal, e
# "\-" gera aviso em alguns greps). Unica funcao de escape do cctl para
# regex de "set $target".
vhost_regex_escape() {
    printf '%s' "$1" | sed -E 's/[][\\.*^$+?(){}|\/]/\\&/g'
}

# vhost_sed_replacement_escape <texto>
#
# Escapa <texto> para o LADO DE SUBSTITUICAO de um "s/…/…/" do sed: &, \ e o
# delimitador / teriam efeito especial.
vhost_sed_replacement_escape() {
    printf '%s' "$1" | sed -E 's/[&\\\/]/\\&/g'
}

# vhost_target_hosts <conteudo-do-vhost>
#
# Imprime o HOST (sem a porta) de cada "set $target <host>:<porta>;" do
# conteudo, um por linha, na ordem em que aparecem.
vhost_target_hosts() {
    local line
    while IFS= read -r line; do
        line="${line#*set}"
        line="$(sed -E 's/^[[:space:]]*[$]target[[:space:]]+//; s/;.*$//; s/[[:space:]]+$//' <<< "${line}")"
        printf '%s\n' "${line%:*}"
    done < <(grep -E '^[[:space:]]*set[[:space:]]+[$]target[[:space:]]+' <<< "$1" || true)
}

# vhost_validate_targets <arquivo-do-vhost> <rede>
#
# Confere, ANTES de publicar, que todo "set $target" do vhost renderizado usa
# o nome qualificado "<container>.<rede do projeto>". Falha (rc 1, com a
# causa) se a rede estiver vazia (o render deixou "<container>.:porta") ou se
# o alvo for um nome curto: o vhost so e publicado com alvo inequivoco, para
# um erro virar falha (502) e nunca o site de outro projeto.
# Vhost sem "set $target" (ex.: o HTTP temporario do desafio ACME) passa.
vhost_validate_targets() {
    local file="$1" network="${2:-}"
    local content host
    # arquivo ausente: quem publica (nginx_enable_site) reclama com a mensagem certa
    [[ -f "${file}" ]] || return 0
    content="$(cat "${file}")" || return 1

    while IFS= read -r host; do
        [[ -n "${host}" ]] || continue
        if [[ -z "${network}" ]]; then
            log_error "CCTL_PROJECT_NETWORK esta vazio, entao o alvo '${host}' do vhost ficaria incompleto. O vhost NAO foi publicado. A rede do projeto e criada no install; confira o .env."
            return 1
        fi
        if [[ "${host}" != *".${network}" || "${host}" == ".${network}" || "${host}" == *".${network}.${network}" ]]; then
            log_error "O alvo '${host}' do vhost nao esta no formato <container>.${network}. O vhost NAO foi publicado. Use {{COMPOSE_PROJECT_NAME}}-<servico>.{{CCTL_PROJECT_NETWORK}} no template (o nome curto pode cair no projeto errado)."
            return 1
        fi
        if [[ -z "${COMPOSE_PROJECT_NAME:-}" || "${host}" != "${COMPOSE_PROJECT_NAME}-"* ]]; then
            log_error "O alvo '${host}' do vhost nao comeca com '${COMPOSE_PROJECT_NAME:-<COMPOSE_PROJECT_NAME vazio>}-' (nome do container do projeto). O vhost NAO foi publicado. Confira se {{COMPOSE_PROJECT_NAME}} foi renderizado."
            return 1
        fi
    done < <(vhost_target_hosts "${content}")
    return 0
}

# vhost_switch_target <vhost> <old_alias> <new_alias>
#
# Reescreve SO as linhas "set $target <old_alias>:" para <new_alias>
# (preserva porta/indentacao/restante do arquivo — mesmo `sed` de antes em
# lib/rollout.sh), com a garantia unica. Usado por _rollout_switch_vhost.
vhost_switch_target() {
    local vhost="$1" old_alias="$2" new_alias="$3"

    local content
    content="$(core_priv_run cat "${vhost}")" || {
        log_error "Falha ao ler o vhost ${vhost}"
        return 1
    }

    local tmpfile
    tmpfile="$(mktemp)" || {
        log_error "Falha ao criar arquivo temporario"
        return 1
    }

    # os aliases tem '.' e '-' (<container>.<rede>): escapados, so casa o alias
    # inteiro (ex.: "proj-dspace.net:" nunca casa "proj-dspace-angular.net:")
    local old_re new_repl
    old_re="$(vhost_regex_escape "${old_alias}")"
    new_repl="$(vhost_sed_replacement_escape "${new_alias}")"
    printf '%s\n' "${content}" | sed -E "s/^([[:space:]]*set[[:space:]]+[\$]target[[:space:]]+)${old_re}:/\1${new_repl}:/" > "${tmpfile}"

    _vhost_apply "${vhost}" "${tmpfile}" \
        "Falha ao criar backup do vhost ${vhost}" \
        "Falha ao aplicar a nova configuracao no vhost ${vhost} — restaurando backup..." \
        "Configuracao nginx invalida apos o switch! Restaurando vhost anterior..."
}

# vhost_remove <vhost>
#
# Remove <vhost> com a garantia unica (backup antes de remover; restaura se
# o `nginx -t` pos-remocao falhar). Usado por nginx_disable_site.
vhost_remove() {
    local vhost="$1"

    _vhost_apply "${vhost}" "" \
        "Falha ao criar backup do vhost ${vhost}" \
        "Falha ao remover vhost ${vhost}" \
        "Config nginx invalida apos remocao! Restaurando..."
}
