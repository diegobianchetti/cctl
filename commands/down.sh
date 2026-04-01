#!/bin/bash
# commands/down.sh — Remove containers e rede (mantem volumes)

cmd_down() {
    compose_down "$@"
}
