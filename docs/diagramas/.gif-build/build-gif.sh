#!/usr/bin/env bash
# build-gif.sh — gera um GIF animado (dark) a partir de um artefato archify.
#
# Contexto medido no proprio artefato: a animacao `trace` e UMA PASSADA
# ambiente (arestas 2.4s, nos 3.8s no preset blueprint, com animation-delay
# escalonado de 160ms por passo) — nao e loop continuo. O unico `infinite`
# do arquivo e o pulse-dot do indicador "Live" da toolbar.
#
# Como funciona:
#   1. copia scratch do HTML forcando o tema dark via localStorage
#      (o viewer le a chave 'archify-theme');
#   2. varre budgets de tempo virtual do headless Chrome, que avanca o tempo
#      de forma deterministica — cada budget amostra um instante da passada;
#   3. descarta os frames finais identicos (a passada repousa no fim), para o
#      loop ficar justo;
#   4. monta o GIF com ffmpeg (paleta otimizada) e reporta o tamanho.
#
# Uso: build-gif.sh <input.html> <output.gif> [largura] [fps] [b0] [b1] [passo_ms]

set -euo pipefail

IN="$1"; OUT="$2"
WIDTH="${3:-1100}"
FPS="${4:-10}"
B0="${5:-2500}"
B1="${6:-8000}"
STEP="${7:-200}"

for c in ffmpeg google-chrome; do
    command -v "$c" >/dev/null 2>&1 || { echo "ERRO: '$c' nao encontrado no PATH"; exit 1; }
done

WORK="$(mktemp -d)"
FRAMES="${WORK}/frames"
mkdir -p "${FRAMES}"

DARK="${WORK}/dark.html"
sed 's|<head>|<head><script>try{localStorage.setItem("archify-theme","dark")}catch(e){}</script>|' \
    "${IN}" > "${DARK}"
grep -q 'archify-theme","dark' "${DARK}" || { echo "ERRO: nao consegui injetar o tema dark"; exit 1; }

D="${WORK}/chrome"; export HOME="$D" XDG_CONFIG_HOME="$D/.config" XDG_CACHE_HOME="$D/.cache"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

i=0
for (( b=B0; b<=B1; b+=STEP )); do
    idx=$(printf '%04d' "$i")
    google-chrome --headless=new --no-sandbox --disable-gpu --hide-scrollbars \
        --window-size=1440,900 --virtual-time-budget="$b" \
        --user-data-dir="${D}/p${idx}" \
        --screenshot="${FRAMES}/f${idx}.png" \
        "file://${DARK}" >/dev/null 2>&1 || true
    [[ -s "${FRAMES}/f${idx}.png" ]] || echo "AVISO: frame ${idx} (budget ${b}) vazio"
    i=$((i+1))
done

n=$(find "${FRAMES}" -name 'f*.png' | wc -l)
echo "frames capturados: ${n} (budgets ${B0}..${B1} passo ${STEP}ms)"
[[ "$n" -ge 4 ]] || { echo "ERRO: poucos frames"; exit 1; }

# indice do ultimo frame que difere do anterior = fim do movimento
last_change=0
prev=""
k=0
for f in "${FRAMES}"/f*.png; do
    h=$(sha256sum "$f" | awk '{print $1}')
    if [[ -n "$prev" && "$h" != "$prev" ]]; then last_change=$k; fi
    prev="$h"; k=$((k+1))
done
echo "ultimo frame com mudanca: ${last_change} (de $((n-1)))"

LIST="${WORK}/list.txt"
: > "${LIST}"
for (( j=0; j<=last_change; j++ )); do
    idx=$(printf '%04d' "$j")
    [[ -s "${FRAMES}/f${idx}.png" ]] && echo "file '${FRAMES}/f${idx}.png'" >> "${LIST}"
done
usados=$(wc -l < "${LIST}")
echo "frames usados no GIF: ${usados}"

ffmpeg -y -loglevel error -f concat -safe 0 -r "${FPS}" -i "${LIST}" \
    -vf "scale=${WIDTH}:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=${COLORS:-128}[p];[s1][p]paletteuse=dither=${DITHER:-bayer:bayer_scale=3}" \
    -loop 0 "${OUT}"

sz=$(stat -c%s "${OUT}")
echo "GIF: ${OUT}"
echo "  bytes: ${sz}"
awk -v s="${sz}" 'BEGIN{ printf "  tamanho: %.2f MB\n", s/1048576 }'
rm -rf "${WORK}"
