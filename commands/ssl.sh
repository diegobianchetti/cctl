#!/bin/bash
# commands/ssl.sh — Subcomando de gerenciamento de certificados SSL
#
# Uso: cctl ssl <status|issue|renew> [dominio]
#
# Disponivel em contexto "instance" e "project" (lib/core.sh). O dominio e
# opcional em todas as acoes — quando omitido, usa DOMAIN_NAME do manifest.

cmd_ssl() {
    local action="${1:-}"
    [[ $# -gt 0 ]] && shift
    local domain="${1:-${DOMAIN_NAME:-}}"

    case "${action}" in
        status)
            ssl_status "${domain}"
            ;;
        issue)
            ssl_issue "${domain}"
            ;;
        renew)
            ssl_renew "${domain}"
            ;;
        help|-h|--help|"")
            _ssl_usage
            ;;
        *)
            msg_error "Acao desconhecida: '${action}'"
            _ssl_usage
            return 1
            ;;
    esac
}

_ssl_usage() {
    echo ""
    echo "Uso: cctl ssl <acao> [dominio]"
    echo ""
    echo "Acoes:"
    echo "  status [dominio]   Exibe modo SSL, caminho do certificado e data de expiracao"
    echo "  issue [dominio]    Emite/instala o certificado conforme SSL_MODE"
    echo "  renew [dominio]    Renova o certificado conforme SSL_MODE"
    echo "  help               Exibe esta ajuda"
    echo ""
    echo "Dominio e opcional — usa DOMAIN_NAME do manifest quando omitido."
    echo ""
    echo "Modos SSL suportados (SSL_MODE no project.conf):"
    echo "  self-signed  Par autoassinado gerado na hora via OpenSSL (dev/homologacao)"
    echo "  letsencrypt  Certbot via webroot compartilhado com o proxy"
    echo "  manual       Certificados fornecidos pelo usuario (SSL_CERT_FILE/SSL_KEY_FILE)"
    echo "  none         Sem SSL — fallback puramente HTTP"
    echo ""
}
