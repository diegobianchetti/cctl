#!/bin/bash
# commands/init.sh — Prepara branch de cliente a partir de um template (roda local)
#
# Uso: cctl init --project <tipo> --client <nome> --domain <dominio>
#
# Fluxo:
#   1. Valida que esta na branch main do repo containers-control
#   2. Valida que o template existe
#   3. Cria branch <projeto>-<cliente> a partir de main
#   4. Copia template para a raiz da branch
#   5. Remove diretorio templates/ da branch
#   6. Seta dados nao-sensiveis no .env
#   7. Commit + push
#   8. Imprime instrucoes para install no servidor

cmd_init() {
    local project_type=""
    local client_name=""
    local domain_name=""

    # Parse argumentos
    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --project|--project=*)
                if [[ "$1" == *=* ]]; then
                    project_type="${1#*=}"
                else
                    shift; project_type="${1:-}"
                fi
                ;;
            --client|--client=*)
                if [[ "$1" == *=* ]]; then
                    client_name="${1#*=}"
                else
                    shift; client_name="${1:-}"
                fi
                ;;
            --domain|--domain=*)
                if [[ "$1" == *=* ]]; then
                    domain_name="${1#*=}"
                else
                    shift; domain_name="${1:-}"
                fi
                ;;
            *)
                msg_error "Opcao desconhecida: $1"
                _init_usage
                return 1
                ;;
        esac
        shift
    done

    # Valida parametros obrigatorios
    if [[ -z "${project_type}" || -z "${client_name}" || -z "${domain_name}" ]]; then
        msg_error "Parametros obrigatorios faltando."
        _init_usage
        return 1
    fi

    local branch_name="${project_type}-${client_name}"
    local template_dir="${CCTL_ROOT}/templates/${project_type}"

    msg_header "Inicializando instancia: ${branch_name}"
    echo -e "  Projeto: ${CYAN}${project_type}${RESET}"
    echo -e "  Cliente: ${CYAN}${client_name}${RESET}"
    echo -e "  Dominio: ${CYAN}${domain_name}${RESET}"
    echo ""

    # 1. Valida que esta na branch main
    _init_check_main_branch || return 1

    # 2. Valida que o template existe
    if [[ ! -d "${template_dir}" ]]; then
        msg_error "Template '${project_type}' nao encontrado em ${template_dir}"
        msg_info "Templates disponiveis:"
        ls -1 "${CCTL_ROOT}/templates/" 2>/dev/null | sed 's/^/  - /'
        return 1
    fi

    # 3. Valida DNS (aviso, nao bloqueante)
    validate_dns "${domain_name}" || true

    # 4. Valida git
    validate_git || return 1

    # 5. Verifica se a branch ja existe
    if git show-ref --verify --quiet "refs/heads/${branch_name}" 2>/dev/null; then
        msg_error "Branch '${branch_name}' ja existe."
        msg_info "Use 'git branch -D ${branch_name}' para remover se deseja recriar."
        return 1
    fi

    # 6. Cria branch a partir de main
    msg_step "1/5" "Criando branch ${branch_name}..."
    git checkout -b "${branch_name}" || return 1

    # 7. Copia template para a raiz
    msg_step "2/5" "Copiando template ${project_type}..."
    cp -r "${template_dir}"/* . 2>/dev/null || true
    cp -r "${template_dir}"/.* . 2>/dev/null || true

    # 8. Remove diretorio templates/ (nao precisa no servidor)
    rm -rf templates/

    # 9. Carrega manifest para pegar ENV_FILE/ENV_TEMPLATE se definidos
    if [[ -f "./project.conf" ]]; then
        source "./project.conf"
    fi

    # Resolve paths do .env
    local env_file
    env_file="./${ENV_FILE:-.env}"
    local env_template="${ENV_TEMPLATE:-.env.template}"

    msg_step "3/5" "Configurando .env..."

    # Procura o template do .env (pode estar em subdir)
    if [[ -f "./${env_template}" ]]; then
        mkdir -p "$(dirname "${env_file}")"
        cp "./${env_template}" "${env_file}"
        rm -f "./${env_template}"
    elif [[ ! -f "${env_file}" ]]; then
        mkdir -p "$(dirname "${env_file}")"
        touch "${env_file}"
    fi

    # Seta variaveis nao-sensiveis
    env_set_var "CLIENT_NAME" "${client_name}"
    env_set_var "DOMAIN_NAME" "${domain_name}"
    env_set_var "COMPOSE_PROJECT_NAME" "${branch_name}"

    # 10. Commit
    msg_step "4/5" "Commit..."
    git add -A
    git commit -m "init: ${branch_name} (${project_type} para ${client_name})"

    # 11. Push (se remote configurado)
    msg_step "5/5" "Push..."
    if git remote get-url origin &>/dev/null; then
        git push -u origin "${branch_name}"
        log_success "Branch ${branch_name} enviada para o remote"
    else
        log_warn "Nenhum remote configurado. Push sera necessario manualmente."
    fi

    # Instrucoes para o install
    echo ""
    msg_header "Proximo passo: instalar no servidor"
    echo ""

    local repo_url
    repo_url=$(git remote get-url origin 2>/dev/null || echo "<URL_DO_REPOSITORIO>")

    echo -e "  ${DIM}# No servidor:${RESET}"
    echo -e "  cd /var/docker"
    echo -e "  git clone --branch ${branch_name} --single-branch ${repo_url} ${branch_name}"
    echo -e "  cd ${branch_name}"
    echo -e "  cctl install"
    echo ""

    log_success "Init concluido para ${branch_name}!"
}

_init_check_main_branch() {
    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null)

    if [[ "${current_branch}" != "main" && "${current_branch}" != "master" ]]; then
        msg_error "Voce deve estar na branch 'main' para executar init."
        msg_info "Branch atual: ${current_branch}"
        msg_info "Execute: git checkout main"
        return 1
    fi
    return 0
}

_init_usage() {
    echo ""
    echo "Uso: cctl init --project <tipo> --client <nome> --domain <dominio>"
    echo ""
    echo "Exemplo:"
    echo "  cctl init --project dspace --client iac --domain repositorio.iac.sp.gov.br"
    echo ""
    echo "Templates disponiveis:"
    ls -1 "${CCTL_ROOT}/templates/" 2>/dev/null | sed 's/^/  - /' || echo "  (nenhum)"
}
