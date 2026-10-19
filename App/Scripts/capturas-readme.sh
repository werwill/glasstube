#!/bin/bash
# Rehace las capturas de la portada (../docs/capturas/) y el GIF (../docs/glasstube.gif) con build/Glasstube.app
# (Scripts/package-app.sh antes). Solo contenido Creative Commons de la Blender Foundation (Big Buck Bunny, CC BY 3.0),
# sin sesión ni Llavero (-GTSinLlavero), sin fotos de quien comenta (-GTSinPersonas) y con el código de vinculación de
# prueba. Necesita el permiso de Grabación de pantalla para la terminal; el GIF, ffmpeg (FFMPEG=/ruta/ffmpeg).
#
#   Scripts/capturas-readme.sh            # capturas y GIF
#   Scripts/capturas-readme.sh reproductor  # solo las que contienen "reproductor" (sin GIF)
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXE="$APP_DIR/build/Glasstube.app/Contents/MacOS/Glasstube"
DOCS="$APP_DIR/../docs"
OUT="$DOCS/capturas"
TMP="$(mktemp -d)"
FILTER="${1:-}"
WIDTH=1600   # ancho de las capturas publicadas (la ventana es de 1440×900 puntos)
mkdir -p "$OUT"
[ -x "$EXE" ] || { echo "Falta $EXE: corre Scripts/package-app.sh" >&2; exit 1; }

shot() { # shot <nombre> <segundos> [ACTIVAR=1] opciones…
    local name="$1" wait="$2"; shift 2
    [[ -z "$FILTER" || "$name" == *"$FILTER"* ]] || return 0
    pkill -f "Glasstube.app/Contents/MacOS/Glasstube" || true
    sleep 1
    rm -f "$TMP/wid"
    "$EXE" -GTWindowFile "$TMP/wid" -GTWindowSize 1440x900 -GTSinLlavero YES -GTSinPersonas YES "$@" \
        > "$TMP/$name.log" 2>&1 &
    if [[ "${ACTIVAR:-0}" == 1 ]]; then
        # Con una hoja abierta, la ventana sale inactiva si otra app tiene el foco.
        sleep $((wait - 2)); osascript -e 'tell application id "mx.glasstube.Glasstube" to activate' >/dev/null 2>&1 || true; sleep 2
    else
        sleep "$wait"
    fi
    screencapture -x -o -l"$(cat "$TMP/wid")" "$TMP/$name.png"
    sips --resampleWidth "$WIDTH" "$TMP/$name.png" --out "$OUT/$name.png" >/dev/null
    echo "docs/capturas/$name.png"
}

BUNNY=aqz-KE-bpKQ   # Big Buck Bunny 60fps 4K, canal oficial de Blender
shot busqueda 12 -appearance light -GTSearch "big buck bunny blender"
# -GTSponsorDemo: un tramo de patrocinio DE PRUEBA (el corto no tiene) para que se vea «Saltar patrocinio».
shot reproductor 17 -appearance dark -GTPlay "$BUNNY" -GTStartAt 62 -GTKeepControls YES -GTSponsorDemo 60-95 \
    -GTPopover quality
shot comentarios 18 -appearance dark -GTKeepControls YES -GTPlay "$BUNNY" -GTStartAt 120 -GTPanel comments
ACTIVAR=1 shot vincular-telefono 10 -appearance light -GTRemotoEnMemoria YES -remoteEnabled YES \
    -remoteName "Glasstube en la Mac" -GTCodigoDePrueba YES -GTPairing 4 -GTSearch "big buck bunny blender"
shot ajustes-sponsorblock 7 -appearance light -GTOpenSettings YES -settingsTab sponsorblock
pkill -f "Glasstube.app/Contents/MacOS/Glasstube" || true

# GIF: las cuatro pantallas con un fundido de medio segundo, a 880 px y 10 cuadros por segundo (unos 3 MB).
[[ -z "$FILTER" ]] || exit 0
FFMPEG="${FFMPEG:-ffmpeg}"
command -v "$FFMPEG" >/dev/null || { echo "Sin ffmpeg: no se rehízo docs/glasstube.gif" >&2; exit 0; }
HOLD=2.6 FADE=0.5
inputs=(); filters=""; i=0
for name in busqueda reproductor comentarios vincular-telefono; do
    inputs+=(-loop 1 -t "$HOLD" -i "$OUT/$name.png")
    filters+="[$i:v]scale=880:-2:flags=lanczos,fps=10,format=rgb24,setsar=1[s$i];"
    i=$((i + 1))
done
filters+="[s0][s1]xfade=transition=fade:duration=$FADE:offset=$(echo "$HOLD - $FADE" | bc)[x1];"
filters+="[x1][s2]xfade=transition=fade:duration=$FADE:offset=$(echo "2 * ($HOLD - $FADE)" | bc)[x2];"
filters+="[x2][s3]xfade=transition=fade:duration=$FADE:offset=$(echo "3 * ($HOLD - $FADE)" | bc),split[a][b];"
filters+="[a]palettegen=max_colors=160:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle"
"$FFMPEG" -v error -y "${inputs[@]}" -filter_complex "$filters" -loop 0 "$DOCS/glasstube.gif"
echo "docs/glasstube.gif ($(du -h "$DOCS/glasstube.gif" | cut -f1))"
echo "Revisa las capturas antes de publicarlas: las miniaturas de terceros pueden traer logos o caras."
