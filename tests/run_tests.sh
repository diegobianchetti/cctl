#!/usr/bin/env bash
# tests/run_tests.sh — roda a suíte de testes unitários (Bats) do cctl
#
# Isolamento: usa o bats-core vendorizado em tests/vendor/ — nao depende de
# instalacao no sistema. Todos os comandos externos (docker, ss, host, sudo,
# certbot) sao mockados por teste; nenhum container, porta ou config real do
# host e tocado.
#
# Uso:
#   tests/run_tests.sh              # roda todas as baterias .bats
#   tests/run_tests.sh validate     # roda so tests/validate.bats
#   tests/run_tests.sh -t           # modo TAP (passa flags extras pro bats)

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bats_bin="${script_dir}/vendor/bats-core/bin/bats"

if [[ ! -x "${bats_bin}" ]]; then
    echo "ERRO: bats-core nao encontrado em ${bats_bin}" >&2
    echo "Rode: git clone --depth 1 https://github.com/bats-core/bats-core.git ${script_dir}/vendor/bats-core" >&2
    exit 1
fi

# Sem argumentos ou argumento comecando com '-': roda tudo, repassando flags
if [[ $# -eq 0 ]]; then
    exec "${bats_bin}" "${script_dir}"/*.bats
fi

if [[ "$1" == -* ]]; then
    exec "${bats_bin}" "$@" "${script_dir}"/*.bats
fi

# Primeiro argumento e um nome de bateria (ex: "validate" -> validate.bats)
targets=()
for name in "$@"; do
    file="${script_dir}/${name}.bats"
    if [[ -f "${file}" ]]; then
        targets+=("${file}")
    elif [[ -f "${name}" ]]; then
        targets+=("${name}")
    else
        echo "AVISO: bateria nao encontrada: ${name}" >&2
    fi
done

if [[ ${#targets[@]} -eq 0 ]]; then
    echo "ERRO: nenhuma bateria valida informada." >&2
    exit 1
fi

exec "${bats_bin}" "${targets[@]}"
