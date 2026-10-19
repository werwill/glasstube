#!/bin/bash
# Descarga los binarios LGPL de MPVKit listados en libmpv-sources.txt, verifica su SHA-256 y extrae cada uno en su
# propio directorio. No compila ni instala nada. Después, link-libmpv.sh arma Vendor/Libmpv.xcframework.
#
#   Scripts/fetch-libmpv.sh            # descarga lo que falte y verifica todo
#
# Directorios (relativos al paquete): Vendor/downloads/<nombre>.xcframework.zip y Vendor/extracted/<nombre>/.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
list="$here/libmpv-sources.txt"
downloads="$root/Vendor/downloads"
extracted="$root/Vendor/extracted"
mkdir -p "$downloads" "$extracted"

fail=0
while read -r name sha url; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    zip="$downloads/$name.xcframework.zip"
    if [[ ! -f "$zip" ]]; then
        echo "descargando $name ($url)"
        curl -fL --retry 3 --silent --show-error -o "$zip.part" "$url"
        mv "$zip.part" "$zip"
    fi
    actual="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
    if [[ "$actual" != "$sha" ]]; then
        echo "ERROR: SHA-256 de $name no coincide: esperado $sha, obtenido $actual" >&2
        rm -f "$zip"
        fail=1
        continue
    fi
    echo "ok $name $sha"
    dest="$extracted/$name"
    if [[ ! -d "$dest" ]]; then
        mkdir -p "$dest.tmp"
        # Solo la rebanada de macOS (los zips traen también iOS, tvOS y visionOS: ~1 GB extraídos en total).
        unzip -q -o "$zip" '*.xcframework/Info.plist' '*.xcframework/macos-*' -d "$dest.tmp"
        mv "$dest.tmp" "$dest"
    fi
done < "$list"

if [[ $fail -ne 0 ]]; then
    echo "Algún archivo no pasó la verificación; se borró. Vuelve a correr el script." >&2
    exit 1
fi
echo "Todos los archivos verificados en $downloads"
