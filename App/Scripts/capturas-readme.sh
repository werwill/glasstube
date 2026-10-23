#!/bin/bash
# Rehace las capturas de la portada (../docs/capturas/) con build/Glasstube.app
# (Scripts/package-app.sh antes). Solo contenido Creative Commons de la Blender Foundation (Big Buck Bunny, CC BY 3.0),
# sin sesión ni Llavero (-GTSinLlavero), sin fotos de quien comenta (-GTSinPersonas) y con el código de vinculación de
# prueba. Necesita el permiso de Grabación de pantalla para la terminal.
#
#   Scripts/capturas-readme.sh            # todas
#   Scripts/capturas-readme.sh reproductor  # solo las que contienen "reproductor"
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

echo "Revisa las capturas antes de publicarlas: las miniaturas de terceros pueden traer logos o caras."
