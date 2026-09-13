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
        project)
            _help_project_commands
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
    echo "  init <template> <nome>  Inicializa diretorio de projeto a partir de um template"
    echo "  proxy <up|down|reload|test|logs|status>  Gerencia o proxy nginx compartilhado"
    echo "  help                    Exibe esta ajuda"
}

_help_project_commands() {
    echo -e "${BOLD}Comandos disponiveis (diretorio de projeto — pre-install):${RESET}"
    echo "  install             Instala a instancia no servidor"
    echo "  ssl <status|issue|renew>  Gerencia o certificado SSL (SSL_MODE do manifest)"
    echo "  proxy <up|down|reload|test|logs|status>  Gerencia o proxy nginx compartilhado"
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
    echo -e "  ${CYAN}SSL:${RESET}"
    echo "  ssl status [dominio]  Modo SSL, caminho do certificado e expiracao"
    echo "  ssl issue [dominio]   Emite/instala o certificado conforme SSL_MODE"
    echo "  ssl renew [dominio]   Renova o certificado conforme SSL_MODE"
    echo ""
    echo -e "  ${CYAN}Proxy Nativo:${RESET}"
    echo "  proxy up            Sobe a infraestrutura do proxy (rede + diretorios + container)"
    echo "  proxy down          Para e remove o container do proxy"
    echo "  proxy reload        Testa e recarrega a configuracao nginx"
    echo "  proxy test          Testa a sintaxe da configuracao (todos os vhosts)"
    echo "  proxy logs [flags]  Encaminha argumentos extras para 'docker logs'"
    echo "  proxy status        Status do container, saude, portas e rede"
    echo ""
    echo -e "  ${CYAN}Rollout (Blue/Green):${RESET}"
    echo "  rollout bluegreen   Sobe a nova versao em slot paralelo, testa saude e"
    echo "                      troca o trafego no nginx sem downtime"
    echo "  rollout rolling     Recreate seguro do slot atual (mesmo alias), com"
    echo "                      rollback automatico se o healthcheck falhar"
    echo "  rollout status      Slot live, container, saude, alvo do vhost e imagem"
    echo "  rollout help        Exibe o uso sintetico de 'cctl rollout'"
    echo "    --service <svc>     Servico alvo (default: ROLLOUT_SERVICE do manifest)"
    echo "    --image <ref>       Imagem a implantar no candidato"
    echo "    --health-mode <m>   auto|docker|http (default: auto)"
    echo "    --timeout <s>       Timeout do healthcheck em segundos"
    echo "    --health-path <p>   Path HTTP da sonda (default: /)"
    echo "    --health-port <p>   Porta da sonda (default: derivada do vhost)"
    echo "    --drain <s>         [bluegreen] Segundos de dreno antes de derrubar o slot antigo"
    echo "    --keep-old          [bluegreen] Nao derruba o slot anterior"
    echo ""
    echo -e "  ${CYAN}Manutencao:${RESET}"
    echo "  build [servico...]  Build/rebuild de imagens (locais ou customizadas)"
    echo "    --no-cache          Repassa --no-cache ao docker compose build"
    echo "    --pull              Atualiza imagens base antes do build"
    echo "    -t, --tag <tag>     Aplica tag customizada as imagens construidas"
    echo "    --custom <servico>  Build via docker/custom/<servico>/Dockerfile"
    echo "    --push              Publica as imagens no registry (ve --registry)"
    echo "    --registry <url>    Sobrescreve o registry alvo do push"
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
    echo "  init <template> <nome>  Inicializa diretorio de projeto a partir de um template"
    echo "  install                 Instala a instancia no servidor"
    echo "  proxy <up|down|reload|test|logs|status>  Gerencia o proxy nginx compartilhado"
    echo "  help                    Exibe esta ajuda"
    echo ""
    echo -e "${DIM}Execute 'cctl help' dentro do diretorio de um projeto ou de uma instancia instalada para ver todos os comandos.${RESET}"
}
