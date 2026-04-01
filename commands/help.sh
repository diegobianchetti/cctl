#!/bin/bash
# commands/help.sh — Sistema de ajuda

cmd_help() {
    echo -e "${BOLD}cctl${RESET} — Orquestrador de containers Docker"
    echo -e "Versao: ${CCTL_VERSION}\n"
    echo -e "${BOLD}Uso:${RESET} cctl <comando> [opcoes]\n"

    case "${CCTL_CONTEXT}" in
        template)
            _help_template_commands
            ;;
        client_branch)
            _help_client_branch_commands
            ;;
        instance)
            _help_instance_commands
            ;;
        *)
            _help_all_commands
            ;;
    esac

    echo ""
    echo -e "${BOLD}Opcoes globais:${RESET}"
    echo "  --version, -v       Exibe a versao do cctl"
    echo "  --help, -h          Exibe esta ajuda"
    echo "  --verbose           Saida detalhada"
}

_help_template_commands() {
    echo -e "${BOLD}Comandos disponiveis (repositorio de templates):${RESET}"
    echo "  init                Cria branch de cliente a partir de um template"
    echo "  help                Exibe esta ajuda"
}

_help_client_branch_commands() {
    echo -e "${BOLD}Comandos disponiveis (branch de cliente — pre-install):${RESET}"
    echo "  install             Instala a instancia no servidor"
    echo "  help                Exibe esta ajuda"
}

_help_instance_commands() {
    echo -e "${BOLD}Comandos disponiveis (instancia instalada):${RESET}"
    echo ""
    echo -e "  ${CYAN}Ciclo de vida:${RESET}"
    echo "  up                  Cria containers e inicia o ambiente"
    echo "  down                Remove containers e rede (mantem volumes)"
    echo "  start               Inicia containers parados"
    echo "  stop                Para containers em execucao"
    echo "  restart             Reinicia containers"
    echo ""
    echo -e "  ${CYAN}Monitoramento:${RESET}"
    echo "  ps                  Lista containers do ambiente"
    echo "  logs [servico]      Exibe logs dos containers"
    echo "  status              Resumo de saude do ambiente"
    echo "  network             Detalhes da rede Docker (subnet, IPs)"
    echo "  volumes             Lista volumes e bind mounts"
    echo ""
    echo -e "  ${CYAN}Acesso:${RESET}"
    echo "  connect <servico>   Abre shell no container do servico"
    echo ""
    echo -e "  ${CYAN}Manutencao:${RESET}"
    echo "  build               Build/rebuild de imagens locais"
    echo "  update              Pull de imagens e recria containers"
    echo "  backup              Executa backup do ambiente"
    echo "  config              Exibe configuracao resolvida"
    echo "  list                Lista instancias instaladas no servidor"
    echo ""
    echo -e "  ${CYAN}Banco de dados:${RESET}"
    echo "  db-check-config     Verifica config customizada do banco"
    echo "  db-update-config    Aplica config customizada no banco"
    echo ""
    echo -e "  ${CYAN}Limpeza (destrutivo):${RESET}"
    echo "  clear-volumes       Remove volumes (dados permanentes)"
    echo "  clear-all           Remove tudo: containers, volumes, configs"
    echo "  destroy             Teardown completo da instancia"
    echo ""
    echo "  help                Exibe esta ajuda"
}

_help_all_commands() {
    echo -e "${BOLD}Comandos:${RESET}"
    echo "  init                Cria branch de cliente a partir de um template"
    echo "  install             Instala a instancia no servidor"
    echo "  help                Exibe esta ajuda"
    echo ""
    echo -e "${DIM}Execute 'cctl help' dentro do diretorio do repositorio ou de uma instancia para ver todos os comandos.${RESET}"
}
