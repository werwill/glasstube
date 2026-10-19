#!/bin/bash
# Genera Icon/AppIcon.icns a partir de Icon/Glasstube.svg (y de Icon/Glasstube-pequeno.svg para 16 y 32 px) sin Xcode:
# qlmanage rasteriza el SVG a 1024 px, sips lo reduce a cada tamaño e iconutil arma el .icns.
#
#   Scripts/make-icon.sh
#
# Es un ícono estático. El ícono "vivo" de macOS 26 (vidrio del sistema, modos teñido y transparente) se arma en
# Icon Composer con las capas de Icon/capas/ y necesita Xcode para compilarse.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ICON_DIR="$APP_DIR/Icon"
TMP="$(mktemp -d)"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"

render() { # render <svg> <salida.png>
    qlmanage -t -s 1024 -o "$TMP" "$1" >/dev/null 2>&1
    mv "$TMP/$(basename "$1").png" "$2"
}

render "$ICON_DIR/Glasstube.svg" "$TMP/grande.png"
render "$ICON_DIR/Glasstube-pequeno.svg" "$TMP/pequeno.png"

resize() { # resize <origen.png> <lado> <nombre>
    sips -z "$2" "$2" "$1" --out "$SET/$3" >/dev/null
}

resize "$TMP/pequeno.png" 16 icon_16x16.png
resize "$TMP/pequeno.png" 32 icon_16x16@2x.png
resize "$TMP/pequeno.png" 32 icon_32x32.png
resize "$TMP/grande.png" 64 icon_32x32@2x.png
resize "$TMP/grande.png" 128 icon_128x128.png
resize "$TMP/grande.png" 256 icon_128x128@2x.png
resize "$TMP/grande.png" 256 icon_256x256.png
resize "$TMP/grande.png" 512 icon_256x256@2x.png
resize "$TMP/grande.png" 512 icon_512x512.png
cp "$TMP/grande.png" "$SET/icon_512x512@2x.png"

iconutil -c icns "$SET" -o "$ICON_DIR/AppIcon.icns"
rm -rf "$TMP"
echo "Icon/AppIcon.icns"
