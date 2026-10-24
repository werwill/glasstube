#!/bin/bash
# libmpv para Windows x64 (LGPL): descarga el paquete de libmpv-windows-sources.txt, verifica su SHA-256 y arma
# Vendor/windows-x64/ con lo que necesita un enlazador de Windows (MSVC, clang o el de Swift para Windows):
#
#   Vendor/windows-x64/bin/libmpv-2.dll        la biblioteca (va junto al .exe; quien reciba la app puede cambiarla)
#   Vendor/windows-x64/include/mpv/*.h         cabeceras de la API cliente (ISC)
#   Vendor/windows-x64/include/module.modulemap   módulo `Libmpv`, el mismo nombre que el xcframework de macOS
#   Vendor/windows-x64/lib/mpv.def, mpv.lib    biblioteca de importación (`link "mpv"`), hecha desde las cabeceras
#
#   Scripts/fetch-libmpv-windows.sh
#
# Corre en Git Bash (Windows), Linux o macOS. Necesita curl, sha256sum o shasum, 7z o un tar que lea .7z (bsdtar),
# y una de estas para la biblioteca de importación: llvm-dlltool, x86_64-w64-mingw32-dlltool o lib.exe (MSVC).
# Si el .7z ya está en Vendor/downloads/ (p. ej. bajado con el navegador) no se vuelve a descargar.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
list="$here/libmpv-windows-sources.txt"
downloads="$root/Vendor/downloads"
extracted="$root/Vendor/extracted"
out="$root/Vendor/windows-x64"
mkdir -p "$downloads" "$extracted"

sha256() {
    if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

read -r name sha url < <(grep -v '^\s*\(#\|$\)' "$list" | head -1)
archive="$downloads/$name.7z"
if [[ ! -f "$archive" ]]; then
    echo "descargando $name ($url)"
    curl -fL --retry 3 --silent --show-error -o "$archive.part" "$url"
    mv "$archive.part" "$archive"
fi
actual="$(sha256 "$archive")"
if [[ "$actual" != "$sha" ]]; then
    echo "ERROR: SHA-256 de $name no coincide: esperado $sha, obtenido $actual" >&2
    rm -f "$archive"
    exit 1
fi
echo "ok $name $sha"

dest="$extracted/$name"
if [[ ! -d "$dest" ]]; then
    rm -rf "$dest.tmp"
    mkdir -p "$dest.tmp"
    if command -v 7z >/dev/null; then
        7z x -y -bd -o"$dest.tmp" "$archive" >/dev/null
    else
        tar -xf "$archive" -C "$dest.tmp" # bsdtar (el tar.exe de Windows 10/11) lee .7z
    fi
    mv "$dest.tmp" "$dest"
fi

dll="$(find "$dest" -iname 'libmpv-2.dll' | head -1)"
client="$(find "$dest" -path '*mpv/client.h' | head -1)"
[[ -n "$dll" && -n "$client" ]] || { echo "ERROR: el paquete no trae libmpv-2.dll o include/mpv/client.h" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out/bin" "$out/include/mpv" "$out/lib"
cp "$dll" "$out/bin/"
cp "$(dirname "$client")"/*.h "$out/include/mpv/"

# Biblioteca de importación: las funciones que las cabeceras marcan con MPV_EXPORT (las mismas que exporta la DLL).
# Se hace aquí y no se usa el libmpv.dll.a del paquete porque ese es de MinGW y el enlazador de MSVC no lo lee.
{
    echo "LIBRARY libmpv-2.dll"
    echo "EXPORTS"
    grep -ho 'MPV_EXPORT[^;]*mpv_[a-z0-9_]*(' "$out"/include/mpv/*.h | grep -o 'mpv_[a-z0-9_]*($' | tr -d '(' | sort -u | sed 's/^/    /'
} > "$out/lib/mpv.def"
if command -v llvm-dlltool >/dev/null; then
    llvm-dlltool -m i386:x86-64 -d "$out/lib/mpv.def" -l "$out/lib/mpv.lib"
elif command -v x86_64-w64-mingw32-dlltool >/dev/null; then
    x86_64-w64-mingw32-dlltool -d "$out/lib/mpv.def" -l "$out/lib/mpv.lib"
elif command -v lib.exe >/dev/null; then
    lib.exe -nologo -machine:x64 -def:"$(cygpath -w "$out/lib/mpv.def")" -out:"$(cygpath -w "$out/lib/mpv.lib")"
else
    echo "ERROR: no hay llvm-dlltool, x86_64-w64-mingw32-dlltool ni lib.exe para hacer mpv.lib" >&2
    exit 1
fi

# Módulo de Swift: `import Libmpv` igual que en macOS. render_d3d11.h existe desde la API 2.6 (mpv 0.42).
{
    echo "module Libmpv [system] {"
    for header in client render render_gl render_d3d11 stream_cb; do
        [[ -f "$out/include/mpv/$header.h" ]] && echo "    header \"mpv/$header.h\""
    done
    echo "    link \"mpv\""
    echo "    export *"
    echo "}"
} > "$out/include/module.modulemap"

version="$(grep -o 'MPV_MAKE_VERSION([0-9]*, *[0-9]*)' "$out/include/mpv/client.h" | head -1)"
echo "listo: $out"
echo "  libmpv-2.dll $(du -h "$out/bin/libmpv-2.dll" | cut -f1) $(sha256 "$out/bin/libmpv-2.dll")"
echo "  API cliente $version; $(grep -c '^    mpv_' "$out/lib/mpv.def") funciones en mpv.def"
