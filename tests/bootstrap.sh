#!/usr/bin/env bash
# tests/bootstrap.sh — busca o bats-core/bats-support/bats-assert vendorizados
#
# tests/vendor/ nao e versionado (ver .gitignore) para nao inflar o repo com
# codigo de terceiros. Rodar uma vez por clone antes de tests/run_tests.sh.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
vendor_dir="${script_dir}/vendor"

clone_if_missing() {
    local repo="$1"
    local dest="$2"
    local tag="$3"

    if [[ -d "${dest}" ]]; then
        echo "  ja presente: ${dest}"
        return 0
    fi

    echo "  clonando ${repo}@${tag} -> ${dest}"
    git clone --depth 1 -q --branch "${tag}" "${repo}" "${dest}"
    rm -rf "${dest}/.git"
}

mkdir -p "${vendor_dir}"

echo "Buscando frameworks de teste em ${vendor_dir}..."
# Tags fixas — evita quebra silenciosa por mudanca upstream nao anunciada.
clone_if_missing "https://github.com/bats-core/bats-core.git" "${vendor_dir}/bats-core" "v1.11.1"
clone_if_missing "https://github.com/bats-core/bats-support.git" "${vendor_dir}/bats-support" "v0.3.0"
clone_if_missing "https://github.com/bats-core/bats-assert.git" "${vendor_dir}/bats-assert" "v2.2.4"

echo "Pronto. Rode: tests/run_tests.sh"
