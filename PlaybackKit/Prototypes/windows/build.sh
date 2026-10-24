#!/bin/bash
# Compila mpvwin.exe contra Vendor/windows-x64 (Scripts/fetch-libmpv-windows.sh) y deja libmpv-2.dll al lado.
#
#   Prototypes/windows/build.sh            # en Windows con clang (LLVM o el de Swift para Windows) o g++ de MinGW;
#                                          # en Linux/macOS con x86_64-w64-mingw32-g++ (compilación cruzada)
#
# En Windows con MSVC: cl /std:c++17 /EHsc /I ..\..\Vendor\windows-x64\include mpvwin.cpp
#   /link /LIBPATH:..\..\Vendor\windows-x64\lib mpv.lib d3d11.lib dxgi.lib dcomp.lib user32.lib gdi32.lib
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
vendor="$(cd "$here/../.." && pwd)/Vendor/windows-x64"
out="$here/build"
[[ -f "$vendor/lib/mpv.def" ]] || { echo "Falta Vendor/windows-x64: corre antes Scripts/fetch-libmpv-windows.sh" >&2; exit 1; }
mkdir -p "$out"

if command -v x86_64-w64-mingw32-g++ >/dev/null; then
    cxx=(x86_64-w64-mingw32-g++ -static -static-libgcc -static-libstdc++)
    # MinGW enlaza mejor con su propia biblioteca de importación que con la de estilo MSVC.
    x86_64-w64-mingw32-dlltool -d "$vendor/lib/mpv.def" -l "$out/libmpv.dll.a"
    mpvlib=("$out/libmpv.dll.a")
elif [[ "$(uname -s)" == MINGW* || "$(uname -s)" == MSYS* ]] && command -v clang++ >/dev/null; then
    cxx=(clang++ --target=x86_64-pc-windows-msvc -fuse-ld=lld)
    mpvlib=("$vendor/lib/mpv.lib")
else
    echo "No hay compilador para Windows x64 (x86_64-w64-mingw32-g++ o clang++ en Windows)" >&2
    exit 1
fi

"${cxx[@]}" -std=c++17 -O2 -Wall -Wextra -I "$vendor/include" -o "$out/mpvwin.exe" "$here/mpvwin.cpp" \
    "${mpvlib[@]}" -ld3d11 -ldxgi -ldcomp -luser32 -lgdi32
cp "$vendor/bin/libmpv-2.dll" "$out/"
echo "listo: $out/mpvwin.exe"
