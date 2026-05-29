#!/bin/bash
# lib/colors.sh — Output colorido com deteccao de terminal
# shellcheck disable=SC2034  # variáveis exportadas para uso em outros scripts via source

# Detecta suporte a cores
if [[ -t 1 ]]; then
    RED='\033[31m'
    GREEN='\033[32m'
    YELLOW='\033[33m'
    BLUE='\033[34m'
    CYAN='\033[36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' RESET=''
fi

# Funcoes de output padronizadas
msg_info()    { echo -e "${BLUE}[INFO]${RESET} $*"; }
msg_success() { echo -e "${GREEN}[OK]${RESET} $*"; }
msg_warn()    { echo -e "${YELLOW}[AVISO]${RESET} $*"; }
msg_error()   { echo -e "${RED}[ERRO]${RESET} $*" >&2; }
msg_step()    { echo -e "${YELLOW}[$1]${RESET} $2"; }
msg_header()  { echo -e "\n${BOLD}$*${RESET}"; }

# Output para confirmacoes destrutivas
msg_danger() {
    echo -e "${RED}============================================================${RESET}"
    echo -e "${RED} $* ${RESET}"
    echo -e "${RED}============================================================${RESET}"
}
