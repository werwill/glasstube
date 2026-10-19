#!/bin/bash
# Arma Vendor/Libmpv.xcframework (un framework dinámico de macOS arm64) con las bibliotecas estáticas LGPL de MPVKit
# que dejó fetch-libmpv.sh en Vendor/extracted/. MPVKit las publica estáticas; la app enlaza libmpv de forma dinámica
# (LGPL), así que aquí se juntan en una sola biblioteca dinámica que exporta solo la API cliente de mpv (`_mpv_*`).
# Quien reciba la app puede sustituir Libmpv.framework por otra compilación de libmpv con la misma API.
#
#   Scripts/fetch-libmpv.sh && Scripts/link-libmpv.sh
#
# No necesita Xcode: usa swiftc (Command Line Tools) como enlazador, porque libmpv trae código Swift (cocoa).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
extracted="$root/Vendor/extracted"
work="$root/Vendor/work"
xcframework="$root/Vendor/Libmpv.xcframework"
arch=arm64
min_macos=15.0

[[ -d "$extracted/Libmpv" ]] || { echo "Falta Vendor/extracted: corre antes Scripts/fetch-libmpv.sh" >&2; exit 1; }
rm -rf "$work"
mkdir -p "$work/lib"

# 1. Rebanada arm64 de macOS de cada biblioteca estática.
libs=()
for dir in "$extracted"/*/; do
    name="$(basename "$dir")"
    slice="$(ls -d "$dir"*.xcframework/macos-* | head -1)"
    if [[ -f "$slice/$name.framework/$name" ]]; then
        binary="$slice/$name.framework/$name"
    else
        binary="$(ls "$slice"/*.a | head -1)" # MoltenVK: libMoltenVK.a suelto
    fi
    out="$work/lib/lib$name.a"
    lipo -thin "$arch" "$binary" -output "$out"
    [[ "$name" == Libmpv ]] || libs+=("$out")
done

# 2. Enlace: libmpv completo (-force_load) y del resto solo lo que haga falta.
framework="$work/Libmpv.framework"
mkdir -p "$framework/Versions/A/Headers" "$framework/Versions/A/Modules" "$framework/Versions/A/Resources"
touch "$work/empty.swift"
swiftc -emit-library -target "$arch-apple-macos$min_macos" -module-name LibmpvLink \
    -o "$framework/Versions/A/Libmpv" "$work/empty.swift" \
    -Xlinker -install_name -Xlinker @rpath/Libmpv.framework/Versions/A/Libmpv \
    -Xlinker -current_version -Xlinker 2.5 -Xlinker -compatibility_version -Xlinker 2.0 \
    -Xlinker -force_load -Xlinker "$work/lib/libLibmpv.a" \
    "${libs[@]}" \
    -Xlinker -exported_symbols_list -Xlinker "$here/libmpv.exports" \
    -Xlinker -dead_strip \
    -framework AVFoundation -framework AudioToolbox -framework CoreAudio -framework CoreFoundation \
    -framework CoreMedia -framework CoreVideo -framework VideoToolbox -framework Metal -framework QuartzCore \
    -framework IOSurface -framework OpenGL -framework Cocoa -framework IOKit -framework Security \
    -framework CoreGraphics -framework CoreText -framework MediaPlayer -framework Carbon \
    -lbz2 -liconv -lexpat -lresolv -lxml2 -lz -lc++

# 3. Cabeceras (ISC) y module map; estructura de framework de macOS (Versions/A + enlaces).
cp "$extracted"/Libmpv/Libmpv.xcframework/macos-*/Libmpv.framework/Headers/mpv/*.h "$framework/Versions/A/Headers/"
cat > "$framework/Versions/A/Modules/module.modulemap" <<'EOF'
framework module Libmpv {
    header "client.h"
    header "render.h"
    header "render_gl.h"
    header "stream_cb.h"
    export *
}
EOF
cat > "$framework/Versions/A/Resources/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Libmpv</string>
    <key>CFBundleIdentifier</key><string>mx.glasstube.libmpv</string>
    <key>CFBundleName</key><string>Libmpv</string>
    <key>CFBundlePackageType</key><string>FMWK</string>
    <key>CFBundleShortVersionString</key><string>0.41.0</string>
    <key>CFBundleVersion</key><string>0.41.0</string>
    <key>LSMinimumSystemVersion</key><string>$min_macos</string>
</dict>
</plist>
EOF
ln -sfn A "$framework/Versions/Current"
for item in Libmpv Headers Modules Resources; do ln -sfn "Versions/Current/$item" "$framework/$item"; done
codesign --force --sign - "$framework/Versions/A/Libmpv"

# 4. XCFramework a mano (xcodebuild -create-xcframework necesita Xcode completo).
rm -rf "$xcframework"
mkdir -p "$xcframework/macos-arm64"
cp -R "$framework" "$xcframework/macos-arm64/"
cat > "$xcframework/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>LibraryIdentifier</key><string>macos-arm64</string>
            <key>LibraryPath</key><string>Libmpv.framework</string>
            <key>SupportedArchitectures</key><array><string>arm64</string></array>
            <key>SupportedPlatform</key><string>macos</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key><string>XFWK</string>
    <key>XCFrameworkFormatVersion</key><string>1.0</string>
</dict>
</plist>
EOF

dylib="$xcframework/macos-arm64/Libmpv.framework/Versions/A/Libmpv"
echo "listo: $xcframework"
echo "  $(du -h "$dylib" | cut -f1) $(shasum -a 256 "$dylib" | cut -d' ' -f1)"
echo "  exporta $(nm -gU "$dylib" | grep -c ' T _mpv_') funciones mpv_*; depende de:"
otool -L "$dylib" | tail -n +2 | sed 's/^/   /'
