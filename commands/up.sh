#!/bin/bash
# commands/up.sh — Cria containers e inicia o ambiente
#
# Antes de subir, garante a rede do projeto: se ela sumiu, e recriada com a
# mesma faixa; se a faixa foi tomada por outra coisa, o "up" recusa (ver
# network_ensure_for_up em lib/network.sh).

cmd_up() {
    network_ensure_for_up || return 1
    compose_up "$@"
}
