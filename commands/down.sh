#!/bin/bash
# commands/down.sh — Remove containers (mantem volumes e rede)
#
# A rede do projeto e do cctl, nao do compose: ela continua existindo (e com a
# faixa reservada) enquanto o projeto esta parado, e o nginx-proxy continua
# conectado a ela. Quem apaga a rede e so o clear-all/destroy.

cmd_down() {
    compose_down "$@"
}
