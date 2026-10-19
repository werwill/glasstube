#!/bin/bash
# Arma Glasstube.app sin Xcode: compila con SwiftPM, copia el ejecutable, Libmpv.framework (dinámica, LGPL) con sus
# licencias, los recursos de YTKit, escribe Info.plist y firma todo el paquete: con el certificado propio «Glasstube
# Desarrollo» si está en el Llavero, o ad hoc si no.
#
#   Scripts/package-app.sh            # release → build/Glasstube.app
#   CONFIG=debug Scripts/package-app.sh
#   OPEN=1 Scripts/package-app.sh     # y lo abre
#   SIGN_IDENTITY=- Scripts/package-app.sh             # ad hoc aunque haya certificado
#   SIGN_IDENTITY="Otro nombre" Scripts/package-app.sh # otra identidad de firma de código
#   HARDENED_RUNTIME=1 SIGN_IDENTITY=<Developer ID> Scripts/package-app.sh  # para notarizar (lo usa release.sh)
#   GITHUB_REPO= Scripts/package-app.sh                # sin aviso de versiones nuevas
#
# Para publicar una versión (DMG, suma y notas; notarización si hay Developer ID): Scripts/release.sh <versión>.
#
# Antes, una vez: ../PlaybackKit/Scripts/fetch-libmpv.sh && ../PlaybackKit/Scripts/link-libmpv.sh
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLAYBACKKIT="$APP_DIR/../PlaybackKit"
CONFIG="${CONFIG:-release}"
OUT="$APP_DIR/build"
APP="$OUT/Glasstube.app"
FRAMEWORK_SRC="$PLAYBACKKIT/Vendor/Libmpv.xcframework/macos-arm64/Libmpv.framework"
# La pone Scripts/release.sh; es CFBundleShortVersionString, con la que el aviso de actualizaciones compara.
VERSION="0.4.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
# Repositorio de GitHub (dueño/repo) donde se publican las versiones. ÚNICO LUGAR DONDE SE CONFIGURA: va al Info.plist
# como GlasstubeGitHubRepository; de ahí lo lee la app para el aviso de versiones nuevas (consulta
# api.github.com/repos/<dueño/repo>/releases/latest) y release.sh para los enlaces de las notas. Si publicas desde otra
# cuenta o un fork, cámbialo aquí. Vacío (GITHUB_REPO=) apaga el aviso en esa compilación.
GITHUB_REPO="${GITHUB_REPO-werwill/glasstube}"
ENTITLEMENTS="$APP_DIR/Glasstube.entitlements"

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }

# Identidad de firma. Con ad hoc la identidad es el hash del binario y cambia en cada compilación, así que el Llavero
# vuelve a pedir permiso para leer las cuentas (`mx.glasstube.cuentas`). Con un certificado propio de «Firma de código»
# (Acceso a Llaveros › Asistente para certificados › Crear un certificado; ver ../README.md) la identidad es el
# certificado y el «Permitir siempre» sirve para las compilaciones siguientes. No hace falta marcarlo como de confianza.
SIGN_NAME="Glasstube Desarrollo"
if [ -z "${SIGN_IDENTITY:-}" ]; then
    # El SHA-1 del certificado, no el nombre: si hubiera dos con el mismo nombre, codesign no sabría cuál usar.
    SIGN_IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk -v name="\"$SIGN_NAME\"" 'index($0, name) { print $2; exit }')"
    SIGN_IDENTITY="${SIGN_IDENTITY:--}"
fi
# Hardened runtime solo para Developer ID (notarizar): con él, dyld solo carga Libmpv.framework si lleva el mismo Team ID
# que la app; ad hoc y el certificado propio no tienen Team ID («mapping process and mapped file (non-platform) have
# different Team IDs», comprobado). Notarizar pide además la marca de tiempo de Apple.
if [ "${HARDENED_RUNTIME:-0}" = "1" ]; then
    if [ "$SIGN_IDENTITY" = "-" ] ||
       ! security find-identity -v -p codesigning 2>/dev/null | grep -F -- "$SIGN_IDENTITY" | grep -q '"Developer ID Application: '; then
        echo "HARDENED_RUNTIME=1 necesita una identidad «Developer ID Application» en SIGN_IDENTITY" >&2
        exit 1
    fi
    SIGN_FLAGS=(--options runtime --timestamp)
else
    SIGN_FLAGS=(--timestamp=none)
fi
sign() { codesign --force --sign "$SIGN_IDENTITY" "${SIGN_FLAGS[@]}" "$@"; }

[ -d "$FRAMEWORK_SRC" ] || { echo "Falta $FRAMEWORK_SRC: corre PlaybackKit/Scripts/fetch-libmpv.sh && link-libmpv.sh" >&2; exit 1; }

log "swift build -c $CONFIG"
cd "$APP_DIR"
swift build -c "$CONFIG" --product Glasstube
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

log "Armando $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/Licenses"
cp "$BIN/Glasstube" "$APP/Contents/MacOS/Glasstube"

# Libmpv.framework tal cual (con sus enlaces simbólicos Versions/Current, Headers…).
ditto "$FRAMEWORK_SRC" "$APP/Contents/Frameworks/Libmpv.framework"
# Las cabeceras y el module map solo sirven para compilar.
rm -rf "$APP/Contents/Frameworks/Libmpv.framework/Versions/A/Headers" "$APP/Contents/Frameworks/Libmpv.framework/Headers" \
       "$APP/Contents/Frameworks/Libmpv.framework/Versions/A/Modules" "$APP/Contents/Frameworks/Libmpv.framework/Modules"
# Sin la información de depuración: son las rutas de los .o de esta Mac (/Users/<usuario>/…/.build/…), que no sirven
# dentro de la app y dirían en qué carpeta se compiló. Se conservan los símbolos (las mpv_* exportadas incluidas).
strip -S "$APP/Contents/MacOS/Glasstube" "$APP/Contents/Frameworks/Libmpv.framework/Versions/A/Libmpv" 2>/dev/null

# Recursos de los paquetes (YTKit: clients.json, solver de n y firma, página del PoToken). El accesor de SwiftPM busca
# primero en Bundle.main.resourceURL, o sea Contents/Resources.
for bundle in "$BIN"/*.bundle; do
    [ -e "$bundle" ] || continue
    ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"
done

# Licencias.
cp "$APP_DIR"/Licenses/* "$APP/Contents/Resources/Licenses/"
for required in LGPL-2.1.txt LGPL-3.0.txt GPL-3.0.txt SmartTube-MIT.txt libmpv-sources.txt; do
    [ -f "$APP_DIR/Licenses/$required" ] || echo "AVISO: falta Licenses/$required (ver Licenses/THIRD-PARTY-NOTICES.md)" >&2
done

# Ícono (estático; lo genera Scripts/make-icon.sh a partir de Icon/Glasstube.svg).
if [ -f "$APP_DIR/Icon/AppIcon.icns" ]; then
    cp "$APP_DIR/Icon/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
else
    echo "AVISO: falta Icon/AppIcon.icns (corre Scripts/make-icon.sh); la app usará el ícono genérico" >&2
fi

# El aviso de versiones nuevas solo existe si hay repositorio (ver GITHUB_REPO).
REPO_PLIST=""
if [ -n "$GITHUB_REPO" ]; then
    [[ "$GITHUB_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "GITHUB_REPO debe ser dueño/repo: $GITHUB_REPO" >&2; exit 1; }
    REPO_PLIST="    <!-- Aviso de versiones nuevas: api.github.com/repos/$GITHUB_REPO/releases/latest (Ajustes › General). -->
    <key>GlasstubeGitHubRepository</key><string>$GITHUB_REPO</string>
"
fi
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>es</string>
    <key>CFBundleDisplayName</key><string>Glasstube</string>
    <key>CFBundleExecutable</key><string>Glasstube</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>mx.glasstube.Glasstube</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>Glasstube</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
    <key>NSHumanReadableCopyright</key><string>Reimplementación de SmartTube (MIT). Usa mpv y FFmpeg bajo LGPL.</string>
$REPO_PLIST    <!-- Fase 4: glasstube://watch?v=…, ://channel/…, ://playlist?list=…, ://search?q=…, ://open?url=… -->
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>mx.glasstube.Glasstube</string>
            <key>CFBundleURLSchemes</key><array><string>glasstube</string></array>
            <key>CFBundleTypeRole</key><string>Viewer</string>
        </dict>
    </array>
    <!-- Fase 4: «Abrir en Glasstube» en el menú Servicios para texto o enlaces seleccionados. -->
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>Abrir en Glasstube</string></dict>
            <key>NSMessage</key><string>openInGlasstube</string>
            <key>NSPortName</key><string>Glasstube</string>
            <key>NSSendTypes</key>
            <array>
                <string>public.utf8-plain-text</string>
                <string>NSStringPboardType</string>
                <string>public.url</string>
            </array>
            <key>NSRequiredContext</key><dict/>
        </dict>
    </array>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

# rpath: el ejecutable carga @rpath/Libmpv.framework/… desde Contents/Frameworks.
if ! otool -l "$APP/Contents/MacOS/Glasstube" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Glasstube"
fi

if [ "$SIGN_IDENTITY" = "-" ]; then
    log "Firma ad hoc (de dentro hacia fuera); sin el certificado «$SIGN_NAME» el Llavero pedirá permiso tras cada compilación"
elif [ "${HARDENED_RUNTIME:-0}" = "1" ]; then
    log "Firma con $SIGN_IDENTITY, hardened runtime y marca de tiempo (de dentro hacia fuera)"
else
    log "Firma con $SIGN_IDENTITY (de dentro hacia fuera)"
fi
# Por omisión sin hardened runtime: con él y una firma sin Team ID (ad hoc o certificado propio), la validación de
# bibliotecas no dejaría cargar un Libmpv.framework vuelto a compilar por el usuario, que es lo que pide la LGPL. Con
# Developer ID (HARDENED_RUNTIME=1) carga porque lleva el mismo Team ID; quien la reemplace vuelve a firmar ad hoc.
sign "$APP/Contents/Frameworks/Libmpv.framework"
for bundle in "$APP"/Contents/Resources/*.bundle; do
    [ -e "$bundle" ] || continue
    sign "$bundle" 2>/dev/null || true
done
# La app con sus entitlements (Glasstube.entitlements: el JIT de JavaScriptCore para el solver; ver ese archivo).
sign --entitlements "$ENTITLEMENTS" "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign -dr - "$APP" 2>&1 | sed -n 's/^designated => /Requisito designado: /p'

plutil -lint "$APP/Contents/Info.plist" >/dev/null
# Que macOS sepa del esquema glasstube:// y del servicio sin esperar al primer arranque.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" || true

log "Listo: $APP ($(du -sh "$APP" | cut -f1))"
otool -L "$APP/Contents/MacOS/Glasstube" | grep -i libmpv
if [ "${OPEN:-0}" = "1" ]; then open "$APP"; fi
