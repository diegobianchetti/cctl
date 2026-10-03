#!/bin/bash
# lib/inventory.sh — Inventario explicito de instancias (F2.4)
#
# Antes da F2.4, `cctl list` varria CCTL_INSTANCE_BASE_DIR/* procurando
# `.cctl-instance` (bug R4): nao via instancias criadas com `cctl init
# --dest` fora da base, e nao distinguia um projeto apenas preparado
# (`cctl init`, sem instalar ainda) de um projeto instalado (`cctl install`).
#
# Este modulo e a UNICA fonte de leitura/escrita do inventario. Cada
# instancia tem UM arquivo de registro em CCTL_INVENTORY_DIR, nomeado pelo
# project_name (ja validado por validate_project_name em outro lugar — este
# modulo nao valida de novo, so usa o nome como chave de arquivo).
#
# Formato do registro: texto simples, uma linha por campo, "KEY<TAB>VALUE".
# NUNCA sourceado como shell — sempre lido linha a linha (inventory_read) —
# para que um CLIENT_NAME/DOMAIN_NAME com caractere especial no valor nunca
# vire execucao de codigo. Sem segredos neste arquivo.
#
# Campos: PROJECT_NAME, PROJECT_TYPE, CLIENT_NAME, DOMAIN_NAME,
# INSTANCE_DIR (absoluto), STATUS (prepared|installed), CREATED_AT,
# UPDATED_AT.
#
# Garantia de escrita: o conteudo e criado em temp-file e copiado para um
# temporario no MESMO diretorio do destino; somente entao ocorre o rename
# atomico via core_priv_run mv. Assim nao dependemos de /tmp e do inventario
# estarem no mesmo filesystem. Em qualquer falha, o destino anterior fica
# intocado e os temporarios sao removidos quando possivel.
#
# Colisao: dois destinos diferentes nao podem compartilhar o mesmo
# project_name. inventory_upsert recusa sobrescrever um registro cujo
# INSTANCE_DIR diverge do que esta sendo gravado.
#
# Este modulo NUNCA apaga/corrige registro sozinho (nem stale, nem
# corrompido) — isso e decisao do operador (ver inventory_list).

# _inventory_validate_project_name <project_name>
#
# A entrada normalmente ja passou por validate_project_name, mas o modulo
# tambem e chamado diretamente por testes e por funcoes internas. A segunda
# barreira impede que uma chave controlada vire path traversal.
_inventory_validate_project_name() {
    local project_name="$1"
    [[ "${project_name}" =~ ^[a-z0-9][a-z0-9_-]{1,62}$ ]] || {
        log_error "Nome de projeto invalido para o inventario: '${project_name}'"
        return 1
    }
}

# _inventory_canonical_path <path>
#
# Canonicaliza tambem o componente final inexistente, permitindo comparar um
# destino preparado e o mesmo destino acessado por symlink.
_inventory_canonical_path() {
    local path="$1"
    [[ -n "${path}" ]] || return 1
    readlink -m -- "${path}"
}

# inventory_file_for <project_name>
#
# Caminho do arquivo de registro, validando a chave antes de concatenar.
inventory_file_for() {
    local project_name="$1"
    _inventory_validate_project_name "${project_name}" || return 1
    printf '%s/%s.tsv' "${CCTL_INVENTORY_DIR}" "${project_name}"
}

# Garante que CCTL_INVENTORY_DIR existe. Via core_priv_run: a primeira
# instalacao, com CCTL_BASE_DIR ainda root-owned (default /opt/cctl), precisa
# de sudo; depois de "cctl proxy up" (que da chown nas folhas operacionais de
# CCTL_INSTANCE_BASE_DIR), o dia a dia nao precisa mais.
_inventory_ensure_dir() {
    core_priv_run mkdir -p "${CCTL_INVENTORY_DIR}"
}

# Remove tab/newline de um valor de campo — o formato e uma linha por campo,
# entao um valor com tab ou newline corromperia o parser de inventory_read.
# Dominio/cliente/caminho nunca deveriam conter esses caracteres; isto e so
# a rede de seguranca.
_inventory_sanitize_field() {
    local v="$1"
    v="${v//$'\t'/ }"
    v="${v//$'\n'/ }"
    printf '%s' "${v}"
}

# Monta o conteudo de um registro (8 linhas "KEY<TAB>VALUE").
_inventory_record_content() {
    local project_name="$1" project_type="$2" client_name="$3" domain_name="$4"
    local instance_dir="$5" status="$6" created_at="$7" updated_at="$8"

    printf 'PROJECT_NAME\t%s\n' "${project_name}"
    printf 'PROJECT_TYPE\t%s\n' "${project_type}"
    printf 'CLIENT_NAME\t%s\n' "${client_name}"
    printf 'DOMAIN_NAME\t%s\n' "${domain_name}"
    printf 'INSTANCE_DIR\t%s\n' "${instance_dir}"
    printf 'STATUS\t%s\n' "${status}"
    printf 'CREATED_AT\t%s\n' "${created_at}"
    printf 'UPDATED_AT\t%s\n' "${updated_at}"
}

# Escreve <content> em <dst> via temp-file + rename atomico (core_priv_run
# mv). Em qualquer falha, <dst> fica intocado (nunca escrita parcial) e o
# temp-file e removido.
_inventory_write_atomic() {
    local dst="$1" content="$2"

    local tmpfile stage
    tmpfile="$(mktemp "${TMPDIR:-/tmp}/cctl_inventory.XXXXXX")" || {
        log_error "Falha ao criar arquivo temporario para registro de inventario"
        return 1
    }

    # printf '%s\n' (nao '%s'): $(...) em _inventory_record_content ja
    # removeu a quebra de linha final do ultimo campo — sem o \n aqui, o
    # arquivo gravado terminaria sem newline (ainda legivel por
    # inventory_read, mas inconsistente com as outras 7 linhas).
    if ! printf '%s\n' "${content}" > "${tmpfile}"; then
        log_error "Falha ao escrever registro temporario de inventario (${tmpfile})"
        rm -f "${tmpfile}"
        return 1
    fi
    chmod 644 "${tmpfile}"

    # Primeiro copia para um nome temporario no diretorio final. O cp pode
    # exigir sudo, mas o arquivo final ainda nao e tocado; o rename seguinte
    # ocorre no mesmo filesystem e e atomico.
    stage="${dst}.tmp.$$.$RANDOM"
    while [[ -e "${stage}" ]]; do
        stage="${dst}.tmp.$$.$RANDOM"
    done

    if ! core_priv_run cp -- "${tmpfile}" "${stage}"; then
        log_error "Falha ao preparar registro de inventario em ${dst}"
        core_priv_run rm -f "${stage}" || true
        rm -f "${tmpfile}"
        return 1
    fi

    if ! core_priv_run mv -- "${stage}" "${dst}"; then
        log_error "Falha ao gravar registro de inventario em ${dst}"
        core_priv_run rm -f "${stage}" || true
        rm -f "${tmpfile}"
        return 1
    fi

    rm -f "${tmpfile}"
    return 0
}

# inventory_read <project_name>
#
# Le o registro e preenche as variaveis globais INV_* (PROJECT_NAME,
# PROJECT_TYPE, CLIENT_NAME, DOMAIN_NAME, INSTANCE_DIR, STATUS, CREATED_AT,
# UPDATED_AT). Nunca sourcea o arquivo — le linha a linha.
#
# Retorno:
#   0  registro lido e com os campos minimos presentes
#   1  arquivo nao existe
#   2  arquivo existe mas esta corrompido (falta PROJECT_NAME/INSTANCE_DIR/
#      STATUS) — INV_* fica com o que foi lido, melhor esforco
inventory_read() {
    local project_name="$1"
    local file
    file="$(inventory_file_for "${project_name}")" || return 1

    [[ -f "${file}" ]] || return 1

    INV_PROJECT_NAME="" INV_PROJECT_TYPE="" INV_CLIENT_NAME="" INV_DOMAIN_NAME=""
    INV_INSTANCE_DIR="" INV_STATUS="" INV_CREATED_AT="" INV_UPDATED_AT=""

    local key value
    while IFS=$'\t' read -r key value; do
        case "${key}" in
            PROJECT_NAME)  INV_PROJECT_NAME="${value}" ;;
            PROJECT_TYPE)  INV_PROJECT_TYPE="${value}" ;;
            CLIENT_NAME)   INV_CLIENT_NAME="${value}" ;;
            DOMAIN_NAME)   INV_DOMAIN_NAME="${value}" ;;
            INSTANCE_DIR)  INV_INSTANCE_DIR="${value}" ;;
            STATUS)        INV_STATUS="${value}" ;;
            CREATED_AT)    INV_CREATED_AT="${value}" ;;
            UPDATED_AT)    INV_UPDATED_AT="${value}" ;;
        esac
    done < "${file}"

    if [[ -z "${INV_PROJECT_NAME}" || -z "${INV_INSTANCE_DIR}" || -z "${INV_STATUS}" ]]; then
        return 2
    fi

    return 0
}

# inventory_upsert <project_name> <project_type> <client_name> <domain_name> <instance_dir> <status>
#
# Cria ou atualiza o registro. CREATED_AT e preservado em atualizacao;
# UPDATED_AT e sempre o momento da chamada.
#
# Falha SEM escrever (registro anterior, se havia, fica intocado) quando:
#   - project_name ou instance_dir vazios;
#   - ja existe um registro desse project_name apontando para OUTRO
#     instance_dir que ainda existe (colisao de nome — dois destinos
#     diferentes nao podem compartilhar a mesma chave);
#   - a escrita atomica falha (disco, permissao, sudo).
#
# Um registro divergente cujo destino ja nao existe e stale: e substituido
# com aviso, permitindo recriar um projeto depois de uma remocao manual.
# Um registro CORROMPIDO (inventory_read retorna 2) tambem e substituido,
# com aviso.
inventory_upsert() {
    local project_name="$1" project_type="$2" client_name="$3" domain_name="$4"
    local instance_dir="$5" status="$6"

    _inventory_validate_project_name "${project_name}" || return 1

    if [[ -z "${project_name}" ]]; then
        log_error "inventory_upsert: nome do projeto vazio"
        return 1
    fi
    if [[ -z "${instance_dir}" ]]; then
        log_error "inventory_upsert: instance_dir vazio"
        return 1
    fi
    if [[ "${status}" != "prepared" && "${status}" != "installed" ]]; then
        log_error "inventory_upsert: status invalido: '${status}'"
        return 1
    fi
    if ! instance_dir="$(_inventory_canonical_path "${instance_dir}")"; then
        log_error "inventory_upsert: nao foi possivel canonicalizar instance_dir: '${instance_dir}'"
        return 1
    fi

    _inventory_ensure_dir || return 1

    local file
    file="$(inventory_file_for "${project_name}")" || return 1

    local now created_at
    now="$(date -Iseconds)"
    created_at="${now}"

    if [[ -f "${file}" ]]; then
        local read_rc=0
        inventory_read "${project_name}" || read_rc=$?

        if [[ "${read_rc}" -eq 0 ]]; then
            local existing_dir existing_canonical
            existing_dir="${INV_INSTANCE_DIR}"
            existing_canonical="$(_inventory_canonical_path "${existing_dir}")" || existing_canonical="${existing_dir}"
            if [[ "${existing_canonical}" != "${instance_dir}" ]]; then
                if [[ ! -d "${existing_dir}" ]]; then
                    log_warn "Registro stale de '${project_name}' aponta para '${existing_dir}'; substituindo pelo destino '${instance_dir}'."
                else
                    log_error "Colisao de inventario: '${project_name}' ja registrado em '${existing_dir}' (tentativa de registrar '${instance_dir}'). Registro: ${file}"
                    return 1
                fi
            fi
            created_at="${INV_CREATED_AT:-${now}}"
        else
            log_warn "Registro de inventario existente para '${project_name}' esta corrompido (${file}) — sobrescrevendo."
        fi
    fi

    project_type="$(_inventory_sanitize_field "${project_type}")"
    client_name="$(_inventory_sanitize_field "${client_name}")"
    domain_name="$(_inventory_sanitize_field "${domain_name}")"
    instance_dir="$(_inventory_sanitize_field "${instance_dir}")"

    local content
    content="$(_inventory_record_content "${project_name}" "${project_type}" "${client_name}" "${domain_name}" "${instance_dir}" "${status}" "${created_at}" "${now}")"

    _inventory_write_atomic "${file}" "${content}"
}

# inventory_mark_prepared <project_name> <project_type> <client_name> <domain_name> <instance_dir>
#
# Usado por `cctl init` ao final de um init bem-sucedido.
inventory_mark_prepared() {
    inventory_upsert "$1" "$2" "$3" "$4" "$5" "prepared"
}

# inventory_mark_installed <project_name> <project_type> <client_name> <domain_name> <instance_dir>
#
# Usado por `cctl install` depois de escrever .cctl-instance. Se nao havia
# registro "prepared" prévio para este project_name/instance_dir (projeto
# nunca passou por `cctl init`, ou inventario anterior a F2.4), cria um novo
# registro direto em installed — "adota" a instancia.
inventory_mark_installed() {
    inventory_upsert "$1" "$2" "$3" "$4" "$5" "installed"
}

# inventory_remove <project_name>
#
# Remove o registro. Chamar SOMENTE depois que o diretorio da instancia
# tiver sido removido com sucesso (ver commands/destroy.sh) — nunca antes:
# falha na remocao do diretorio deve preservar o registro, para que a
# instancia continue aparecendo em `cctl list` (ainda existe no disco).
inventory_remove() {
    local project_name="$1"
    [[ -z "${project_name}" ]] && return 0

    local file
    file="$(inventory_file_for "${project_name}")" || return 1
    [[ -f "${file}" ]] || return 0

    core_priv_run rm -f "${file}"
}

# inventory_list
#
# Emite uma linha TSV por registro em CCTL_INVENTORY_DIR, nesta ordem:
#   PROJECT_NAME  PROJECT_TYPE  CLIENT_NAME  DOMAIN_NAME  INSTANCE_DIR
#   STATUS  STATE  CREATED_AT  UPDATED_AT
#
# STATE e derivado em tempo de leitura (nunca gravado no arquivo):
#   ok         instance_dir existe; se STATUS=installed, .cctl-instance
#              tambem existe la.
#   stale      instance_dir nao existe, OU STATUS=installed sem
#              .cctl-instance no instance_dir.
#   corrupted  arquivo sem os campos minimos — PROJECT_NAME vem do nome do
#              arquivo, os demais campos saem "?".
#
# Nao corrige nem remove nada: so avisa e segue para o proximo arquivo — um
# registro ruim nunca derruba a listagem inteira.
#
# Avisos vao DIRETO para stderr (nunca log_warn/msg_warn, que escrevem no
# STDOUT — ver lib/colors.sh) porque stdout desta funcao e um contrato de
# dados (TSV) consumido por quem chama (commands/list.sh); um aviso
# misturado no stdout seria lido como uma linha de registro a mais.
_inventory_warn_stderr() {
    printf '[AVISO] %s\n' "$*" >&2
}

inventory_list() {
    [[ -d "${CCTL_INVENTORY_DIR}" ]] || return 0

    local file base project_name
    for file in "${CCTL_INVENTORY_DIR}"/*.tsv; do
        [[ -f "${file}" ]] || continue
        base="$(basename "${file}")"
        project_name="${base%.tsv}"

        local read_rc=0
        inventory_read "${project_name}" || read_rc=$?

        if [[ "${read_rc}" -eq 2 || "${read_rc}" -eq 1 ]]; then
            _inventory_warn_stderr "Registro de inventario corrompido/ilegivel: ${file}"
            printf '%s\t?\t?\t?\t?\t?\tcorrupted\t?\t?\n' "${project_name}"
            continue
        fi

        local state="ok"
        if [[ ! -d "${INV_INSTANCE_DIR}" ]]; then
            state="stale"
            _inventory_warn_stderr "Instancia '${project_name}' stale: diretorio nao encontrado (${INV_INSTANCE_DIR})"
        elif [[ "${INV_STATUS}" == "installed" && ! -f "${INV_INSTANCE_DIR}/.cctl-instance" ]]; then
            state="stale"
            _inventory_warn_stderr "Instancia '${project_name}' stale: status installed mas .cctl-instance ausente em ${INV_INSTANCE_DIR}"
        fi

        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "${INV_PROJECT_NAME}" "${INV_PROJECT_TYPE}" "${INV_CLIENT_NAME}" \
            "${INV_DOMAIN_NAME}" "${INV_INSTANCE_DIR}" "${INV_STATUS}" \
            "${state}" "${INV_CREATED_AT}" "${INV_UPDATED_AT}"
    done
}
