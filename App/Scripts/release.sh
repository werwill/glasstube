#!/bin/bash
# Prepara una versión de Glasstube para descargar desde GitHub Releases. No publica nada: deja en dist/ (en la raíz del
# repositorio) el .dmg, su suma SHA-256 y las notas. Crear la versión en GitHub y subir los archivos lo hace la persona.
#
#   App/Scripts/release.sh 0.4.0
#
#   1. Pone la versión en Scripts/package-app.sh (CFBundleShortVersionString: con ella compara el aviso de versiones).
#   2. Compila en release y empaqueta con package-app.sh.
#   3. Arma dist/Glasstube-<versión>.dmg con hdiutil: la app, un acceso a Aplicaciones y un fondo simple
#      (Packaging/dmg-fondo.svg). Finder acomoda la ventana por AppleScript; si macOS no le da permiso a quien corre el
#      script para controlar Finder, el DMG sale igual, sin fondo ni posiciones.
#   4. Escribe la SHA-256 (dist/Glasstube-<versión>.dmg.sha256) y dist/RELEASE-NOTES-<versión>.md.
#   5. Sparkle (fase 5b): firma el DMG con EdDSA (sign_update, con la clave privada del Llavero de quien publica),
#      comprueba que la firma vale con la clave pública que lleva la app, pone la entrada de esta versión en appcast.xml
#      (en la raíz del repositorio; solo versiones de la Mac, etiquetas v…) y firma el appcast. Si la app no lleva clave
#      pública (falta Packaging/sparkle-clave-publica.txt), se salta este paso y la app usa el aviso de GitHub.
#
# Notarización (opcional). Si en el Llavero hay una identidad «Developer ID Application» (security find-identity -p
# codesigning), firma la app con ella, con hardened runtime y los entitlements de Glasstube.entitlements. Si además hay
# un perfil de notarytool guardado, notariza el .dmg (xcrun notarytool submit --wait) y lo engrapa (xcrun stapler
# staple). El perfil lo crea la persona una vez, con su Apple ID y una contraseña para apps de appleid.apple.com:
#
#   xcrun notarytool store-credentials glasstube-notarizacion --apple-id <correo> --team-id <TEAMID>
#
# Este script nunca pide ni guarda contraseñas. Sin Developer ID sigue con la firma de package-app.sh (el certificado
# propio «Glasstube Desarrollo» o ad hoc) y las notas explican cómo abrir una app sin notarizar.
#
#   NOTARY_PROFILE=<nombre>      perfil de notarytool (por omisión glasstube-notarizacion)
#   NOTARIZE=0                   con Developer ID, firma pero no notariza
#   DEVELOPER_ID=<SHA-1|nombre>  qué identidad Developer ID usar si hay varias
#   SKIP_BUILD=1                 no recompila: usa App/build/Glasstube.app si ya tiene esa versión (para rehacer el DMG)
#   CAMBIOS=<archivo.md>         qué cambió (dos o tres viñetas en markdown): va a las notas y a la ventana de Sparkle
#   SPARKLE_ED_KEY_FILE=<ruta>   la clave privada de Sparkle en un archivo en lugar del Llavero (sign_update -f)
#   APPCAST=<ruta>               otro appcast (por omisión appcast.xml en la raíz del repositorio)
#   DMG_URL=<url>                otra dirección para el DMG en el appcast (pruebas con un servidor local)
#
# La clave de Sparkle se crea UNA vez, la persona que publica, y la privada no sale de su Llavero:
#
#   App/.build/artifacts/sparkle/Sparkle/bin/generate_keys     # imprime la clave pública
#   (pega la clave pública en App/Packaging/sparkle-clave-publica.txt y súbela al repositorio)
set -euo pipefail

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || {
    echo "Uso: $0 <versión>   (p. ej. 0.4.0 o 0.5.0-beta.1)" >&2
    exit 1
}

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$(cd "$APP_DIR/.." && pwd)"
DIST="$ROOT/dist"
APP="$APP_DIR/build/Glasstube.app"
DMG="$DIST/Glasstube-$VERSION.dmg"
NOTES="$DIST/RELEASE-NOTES-$VERSION.md"
VOLNAME="Glasstube"
NOTARY_PROFILE="${NOTARY_PROFILE:-glasstube-notarizacion}"
PLIST_BUDDY=/usr/libexec/PlistBuddy
APPCAST="${APPCAST:-$ROOT/appcast.xml}"
SPARKLE_BIN="$APP_DIR/.build/artifacts/sparkle/Sparkle/bin"
if [ -n "${CAMBIOS:-}" ] && [ ! -f "$CAMBIOS" ]; then
    echo "No existe CAMBIOS=$CAMBIOS" >&2
    exit 1
fi

log() { printf '\033[1m==> %s\033[0m\n' "$*"; }
# hdiutil sigue funcionando en macOS 27, pero avisa en cada llamada que lo reemplaza `diskutil image`; el aviso se calla.
hdi() { hdiutil "$@" 2> >(grep -v 'is deprecated' >&2); }
warn() { printf '\033[33mAVISO: %s\033[0m\n' "$*" >&2; }

TMP="$(mktemp -d)"
DEVICE=""
cleanup() {
    [ -z "$DEVICE" ] || hdiutil detach "$DEVICE" -force >/dev/null 2>&1 || true
    rm -rf "$TMP"
}
trap cleanup EXIT

# --- Firma: Developer ID si hay ------------------------------------------------------------------------------------------

DEVID_SHA=""
DEVID_NAME=""
while read -r sha name; do
    if [ -z "${DEVELOPER_ID:-}" ] || [ "$sha" = "$DEVELOPER_ID" ] || [[ "$name" == *"$DEVELOPER_ID"* ]]; then
        DEVID_SHA="$sha"
        DEVID_NAME="$name"
        break
    fi
done < <(security find-identity -v -p codesigning 2>/dev/null |
         sed -n 's/^ *[0-9]*) \([0-9A-F]\{40\}\) "\(Developer ID Application: .*\)"$/\1 \2/p')

NOTARIZE_READY=0
if [ -n "$DEVID_SHA" ]; then
    log "Developer ID: $DEVID_NAME"
    if [ "${NOTARIZE:-1}" = "0" ]; then
        warn "NOTARIZE=0: se firma con Developer ID pero no se notariza"
    elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        NOTARIZE_READY=1
        log "Perfil de notarytool «$NOTARY_PROFILE»: listo para notarizar"
    else
        warn "No hay un perfil de notarytool «$NOTARY_PROFILE» que funcione: se firma con Developer ID sin notarizar."
        warn "Para notarizar, créalo una vez (pide la contraseña para apps; este script no la ve):"
        warn "  xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <correo> --team-id <TEAMID>"
    fi
else
    log "Sin identidad «Developer ID Application» en el Llavero: firma de package-app.sh, sin notarizar"
fi

# --- 1 y 2. Versión, compilación y empaquetado -------------------------------------------------------------------------

PACKAGE="$APP_DIR/Scripts/package-app.sh"
if [ "${SKIP_BUILD:-0}" = "1" ]; then
    log "SKIP_BUILD=1: se usa $APP tal cual"
else
    log "Versión $VERSION en Scripts/package-app.sh"
    sed -i '' -E "s/^VERSION=\"[^\"]*\"/VERSION=\"$VERSION\"/" "$PACKAGE"
    grep -q "^VERSION=\"$VERSION\"\$" "$PACKAGE" || { echo "No se pudo poner la versión en $PACKAGE" >&2; exit 1; }
    if [ -n "$DEVID_SHA" ]; then
        CONFIG=release SPARKLE=1 HARDENED_RUNTIME=1 SIGN_IDENTITY="$DEVID_SHA" "$PACKAGE"
    else
        CONFIG=release SPARKLE=1 "$PACKAGE"
    fi
fi

[ -d "$APP" ] || { echo "Falta $APP" >&2; exit 1; }
BUILT_VERSION="$($PLIST_BUDDY -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$BUILT_VERSION" = "$VERSION" ] || { echo "$APP es la versión $BUILT_VERSION, no $VERSION" >&2; exit 1; }
BUILD_NUMBER="$($PLIST_BUDDY -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
REPO="$($PLIST_BUDDY -c 'Print :GlasstubeGitHubRepository' "$APP/Contents/Info.plist" 2>/dev/null || true)"
[ -n "$REPO" ] || warn "La app no tiene GlasstubeGitHubRepository (GITHUB_REPO vacío): sin aviso de versiones ni enlaces"
SPARKLE_KEY="$($PLIST_BUDDY -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist" 2>/dev/null || true)"
SPARKLE_FEED="$($PLIST_BUDDY -c 'Print :SUFeedURL' "$APP/Contents/Info.plist" 2>/dev/null || true)"
MINIMUM_SYSTEM="$($PLIST_BUDDY -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
if [ -n "$SPARKLE_KEY" ]; then
    log "Sparkle: $SPARKLE_FEED"
    [ -x "$SPARKLE_BIN/sign_update" ] || { echo "Falta $SPARKLE_BIN/sign_update (corre swift build en App/)" >&2; exit 1; }
else
    warn "La app no lleva clave pública de Sparkle (App/Packaging/sparkle-clave-publica.txt): sin appcast; esta versión"
    warn "solo tendrá el aviso de GitHub. Para crear la clave: App/.build/artifacts/sparkle/Sparkle/bin/generate_keys"
fi
codesign --verify --deep --strict "$APP"

SIGN_INFO="$(codesign -dvv "$APP" 2>&1)"
if grep -q '^Authority=Developer ID Application' <<<"$SIGN_INFO"; then
    SIGN_KIND="devid"
    SIGN_TEXT="Developer ID ($(sed -n 's/^Authority=Developer ID Application: //p' <<<"$SIGN_INFO"))"
    SIGN_TEXT_EN="$SIGN_TEXT"
elif grep -q '^Signature=adhoc' <<<"$SIGN_INFO"; then
    SIGN_KIND="adhoc"
    SIGN_TEXT="firma ad hoc"
    SIGN_TEXT_EN="ad hoc signature"
else
    SIGN_KIND="propia"
    SIGN_TEXT="certificado propio «$(sed -n 's/^Authority=//p' <<<"$SIGN_INFO" | head -1)»"
    SIGN_TEXT_EN="self-signed certificate"
fi
if grep -q 'flags=.*runtime' <<<"$SIGN_INFO"; then
    SIGN_TEXT="$SIGN_TEXT, hardened runtime"
    SIGN_TEXT_EN="$SIGN_TEXT_EN, hardened runtime"
fi
log "App $VERSION ($BUILD_NUMBER): $SIGN_TEXT"

# --- 3. DMG ----------------------------------------------------------------------------------------------------------

if mount | grep -q " on /Volumes/$VOLNAME "; then
    echo "Ya hay un volumen /Volumes/$VOLNAME montado: expúlsalo antes (Finder confundiría los dos al acomodar la ventana)." >&2
    exit 1
fi

log "Armando $DMG"
STAGE="$TMP/$VOLNAME"
mkdir -p "$STAGE/.fondo" "$DIST"
ditto "$APP" "$STAGE/Glasstube.app"
ln -s /Applications "$STAGE/Applications"

# Fondo: el SVG a 1x y 2x y un TIFF con los dos tamaños para Retina. qlmanage siempre da un cuadrado, así que el SVG de
# 660×400 se centra en uno de 660×660 (viewBox desde y = -130) y sips recorta la franja del medio, que es exacta.
BACKGROUND=""
sed 's/width="660" height="400" viewBox="0 0 660 400"/width="660" height="660" viewBox="0 -130 660 660"/' \
    "$APP_DIR/Packaging/dmg-fondo.svg" >"$TMP/dmg-fondo.svg"
if grep -q 'viewBox="0 -130 660 660"' "$TMP/dmg-fondo.svg" &&
   qlmanage -t -s 1320 -o "$TMP" "$TMP/dmg-fondo.svg" >/dev/null 2>&1 && [ -f "$TMP/dmg-fondo.svg.png" ]; then
    sips --cropToHeightWidth 800 1320 "$TMP/dmg-fondo.svg.png" --out "$TMP/fondo@2x.png" >/dev/null
    sips -z 400 660 "$TMP/fondo@2x.png" --out "$TMP/fondo.png" >/dev/null
    tiffutil -cathidpicheck "$TMP/fondo.png" "$TMP/fondo@2x.png" -out "$STAGE/.fondo/fondo.tiff" >/dev/null 2>&1
    [ -f "$STAGE/.fondo/fondo.tiff" ] && BACKGROUND="fondo.tiff"
fi
[ -n "$BACKGROUND" ] || warn "No se pudo rasterizar Packaging/dmg-fondo.svg: el DMG va sin fondo"

SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 20 ))
hdi create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ -format UDRW -size "${SIZE_MB}m" -ov "$TMP/rw.dmg" >/dev/null
ATTACH="$(hdi attach "$TMP/rw.dmg" -readwrite -noverify -noautoopen)"
DEVICE="$(awk '/Apple_HFS/ { print $1; exit }' <<<"$ATTACH")"
MOUNT="$(awk -F'\t' '/Apple_HFS/ { sub(/[ \t]+$/, "", $NF); print $NF; exit }' <<<"$ATTACH")"
[ -n "$DEVICE" ] && [ -d "$MOUNT" ] || { echo "No se pudo montar el DMG de trabajo" >&2; exit 1; }

# Ventana de 660×400 con los íconos centrados en (165, 180) y (495, 180), como dibuja el fondo. Los límites de la ventana
# incluyen la barra de título (32 pt en macOS 26 y 27 sin barra de herramientas): 400 + 32 de alto.
if [ -n "$BACKGROUND" ]; then
    # Recién montado, Finder puede tardar en ver el disco (-1728, «No puede obtenerse disk»).
    for _ in $(seq 1 20); do
        [ "$(osascript -e "tell application \"Finder\" to exists disk \"$VOLNAME\"" 2>/dev/null)" = "true" ] && break
        sleep 1
    done
    if ! osascript <<APPLESCRIPT >/dev/null 2>"$TMP/osascript.log"
tell application "Finder"
    with timeout of 60 seconds
        tell disk "$VOLNAME"
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {200, 120, 860, 552}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 128
            set text size of viewOptions to 13
            set label position of viewOptions to bottom
            set shows item info of viewOptions to false
            set shows icon preview of viewOptions to false
            set background picture of viewOptions to file ".fondo:$BACKGROUND"
            set position of item "Glasstube.app" of container window to {165, 180}
            set position of item "Applications" of container window to {495, 180}
            update without registering applications
            delay 1
            close
        end tell
    end timeout
end tell
APPLESCRIPT
    then
        warn "Finder no acomodó la ventana del DMG ($(tr '\n' ' ' <"$TMP/osascript.log")). Si macOS lo pidió, permite"
        warn "controlar Finder (Ajustes del Sistema › Privacidad y seguridad › Automatización) y vuelve a correr el script."
    fi
fi
# Finder escribe .DS_Store al cerrar la ventana; se le da un momento.
for _ in 1 2 3 4 5; do [ -f "$MOUNT/.DS_Store" ] && break; sleep 1; done
# Ícono del volumen: el de la app. Va después de Finder, que al acomodar la ventana borra .VolumeIcon.icns.
if [ -f "$APP/Contents/Resources/AppIcon.icns" ]; then
    cp "$APP/Contents/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
    SetFile -a C "$MOUNT" 2>/dev/null || warn "SetFile no marcó el ícono del volumen (viene con las Command Line Tools)"
fi
rm -rf "$MOUNT/.fseventsd" "$MOUNT/.Trashes"
chmod -Rf go-w "$MOUNT" 2>/dev/null || true
sync
for attempt in 1 2 3 4 5; do
    hdi detach "$DEVICE" >/dev/null 2>&1 && { DEVICE=""; break; }
    sleep 2
done
[ -z "$DEVICE" ] || { hdi detach "$DEVICE" -force >/dev/null; DEVICE=""; }

rm -f "$DMG"
hdi convert "$TMP/rw.dmg" -format ULMO -o "$DMG" >/dev/null

# --- Notarización -----------------------------------------------------------------------------------------------------

NOTARIZED=0
if [ -n "$DEVID_SHA" ]; then
    log "Firma del DMG con Developer ID"
    codesign --force --sign "$DEVID_SHA" --timestamp "$DMG"
fi
if [ "$NOTARIZE_READY" = "1" ]; then
    log "Notarizando (xcrun notarytool submit --wait; suele tardar unos minutos)"
    SUBMIT="$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee /dev/stderr)"
    SUBMISSION="$(sed -n 's/^ *id: //p' <<<"$SUBMIT" | head -1)"
    if grep -q 'status: Accepted' <<<"$SUBMIT"; then
        xcrun stapler staple "$DMG"
        xcrun stapler validate "$DMG"
        spctl --assess --type open --context context:primary-signature --verbose "$DMG" || true
        NOTARIZED=1
    else
        echo "Apple no aceptó la notarización. Registro:" >&2
        [ -n "$SUBMISSION" ] && xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        exit 1
    fi
fi

# --- Comprobación del DMG ---------------------------------------------------------------------------------------------

log "Comprobando el DMG"
hdi verify "$DMG" >/dev/null 2>&1 || { echo "hdiutil verify falló" >&2; exit 1; }
mkdir -p "$TMP/comprobar"
ATTACH="$(hdi attach "$DMG" -readonly -nobrowse -noautoopen -mountpoint "$TMP/comprobar")"
DEVICE="$(awk '/Apple_HFS/ { print $1; exit }' <<<"$ATTACH")"
codesign --verify --deep --strict "$TMP/comprobar/Glasstube.app"
[ "$(readlink "$TMP/comprobar/Applications")" = "/Applications" ]
[ "$($PLIST_BUDDY -c 'Print :CFBundleShortVersionString' "$TMP/comprobar/Glasstube.app/Contents/Info.plist")" = "$VERSION" ]
# Nada de rutas de esta Mac dentro de la app (package-app.sh quita la información de depuración con strip -S).
LEAKS="$(LC_ALL=C grep -rlaF "$HOME/" "$TMP/comprobar/Glasstube.app" 2>/dev/null || true)"
[ -z "$LEAKS" ] || { echo "La app lleva rutas de esta Mac ($HOME/…) en: $LEAKS" >&2; exit 1; }
LAYOUT="sin fondo"
[ -f "$TMP/comprobar/.DS_Store" ] && [ -n "$BACKGROUND" ] && LAYOUT="con fondo"
hdi detach "$DEVICE" >/dev/null
DEVICE=""

# --- 4. Suma y notas --------------------------------------------------------------------------------------------------

SHA256="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "$SHA256  $(basename "$DMG")" >"$DMG.sha256"
SIZE="$(stat -f %z "$DMG" | awk '{ printf "%.1f MB", $1 / 1048576 }')"
TAG="v$VERSION"
REPO_URL="https://github.com/${REPO:-<dueño>/<repo>}"
MPVKIT_COMMIT="98c3453e252922e3136422da3fbb2e341ed9edc8"

if [ -n "$SPARKLE_KEY" ]; then
    UPDATES_TEXT="Glasstube busca versiones nuevas una vez al día y las instala sin salir de la app (Sparkle, con
> firma EdDSA); se apaga en **Ajustes › General › Actualizaciones**. Si vienes de la 0.5 o anterior, esta la instalas a
> mano una vez; las siguientes llegan solas."
    UPDATES_TEXT_EN="The app looks for new versions once a day and installs them in place (Sparkle, EdDSA-signed); turn it
off in Settings › General › Updates."
    ONCE_TEXT="una sola vez (las versiones siguientes llegan por Sparkle y abren sin este paso)"
    ONCE_TEXT_EN="You only do this once: later versions arrive through Sparkle and open without it."
else
    UPDATES_TEXT="Glasstube avisa al abrirse cuando hay una nueva (consulta GitHub como mucho una vez al día; se
> apaga en **Ajustes › General › Actualizaciones**)."
    UPDATES_TEXT_EN="The app checks GitHub for new versions at most once a day (turn it off in Settings › General › Updates)."
    ONCE_TEXT="una sola vez por versión"
    ONCE_TEXT_EN="You only do this once per version."
fi
if [ "$NOTARIZED" = "1" ]; then
    OPEN_STEPS="Está firmada con Developer ID y notarizada por Apple: se abre directo, sin avisos de Gatekeeper.

1. Abre \`Glasstube-$VERSION.dmg\` y arrastra **Glasstube** a **Applications** (Aplicaciones).
2. Abre Glasstube desde Aplicaciones."
    OPEN_STEPS_EN="Signed with Developer ID and notarised by Apple: it opens without Gatekeeper warnings. Open the DMG,
drag Glasstube to Applications and open it."
else
    OPEN_STEPS="Es una **vista previa sin notarizar** ($SIGN_TEXT): Apple no la revisó, así que macOS la bloquea la primera
vez. Se abre así, $ONCE_TEXT:

1. Abre \`Glasstube-$VERSION.dmg\` y arrastra **Glasstube** a **Applications** (Aplicaciones).
2. Abre Glasstube desde Aplicaciones. macOS dice que no puede verificar que esté libre de malware: pulsa **Listo**
   (no «Trasladar a la Papelera»).
3. Ve a **Ajustes del Sistema › Privacidad y seguridad**, baja hasta **Seguridad** y, junto a «Se bloqueó
   \"Glasstube\"…», pulsa **Abrir de todos modos**. Confirma con tu contraseña o Touch ID y pulsa **Abrir**.
4. Desde ahí se abre normal.

Si prefieres la terminal, esto quita la marca de cuarentena (solo si comprobaste la suma de arriba):

\`\`\`bash
xattr -dr com.apple.quarantine /Applications/Glasstube.app
\`\`\`"
    OPEN_STEPS_EN="This is an **unnotarised preview** ($SIGN_TEXT_EN), so macOS blocks it the first time. Open the DMG,
drag Glasstube to Applications and open it; click **Done**, then go to **System Settings › Privacy & Security**, click
**Open Anyway** next to the Glasstube message and confirm. $ONCE_TEXT_EN"
fi
if [ "$SIGN_KIND" = "adhoc" ]; then
    KEYCHAIN_NOTE="Si inicias sesión en YouTube, macOS pregunta si Glasstube puede usar el Llavero: elige **Permitir siempre**.
Con la firma ad hoc lo vuelve a preguntar después de cada actualización."
else
    KEYCHAIN_NOTE="Si inicias sesión en YouTube, macOS pregunta si Glasstube puede usar el Llavero: elige **Permitir siempre**."
fi

if [ -n "${CAMBIOS:-}" ]; then
    CHANGES_TEXT="$(cat "$CAMBIOS")"
else
    CHANGES_TEXT="<!-- Escribe aquí, en dos o tres viñetas, qué cambió en esta versión (o pásalas con CAMBIOS=archivo.md). -->"
fi

cat >"$NOTES" <<NOTES
# Glasstube $VERSION

$CHANGES_TEXT

> [!NOTE]
> **Vista previa.** YouTube cambia seguido su reproductor y sus defensas, y a veces eso rompe la reproducción hasta la
> siguiente versión. $UPDATES_TEXT

Glasstube no está afiliado a YouTube ni a Google. Lee las [preguntas frecuentes]($REPO_URL#preguntas-frecuentes) antes
de usarlo con tu cuenta.

## Descarga

| Archivo | Tamaño | SHA-256 |
|---|---|---|
| \`Glasstube-$VERSION.dmg\` | $SIZE | \`$SHA256\` |

Para comprobar la descarga: \`shasum -a 256 ~/Downloads/Glasstube-$VERSION.dmg\` debe dar la misma suma.

## Requisitos

- **macOS 26 Tahoe o posterior.**
- **Mac con Apple Silicon** (M1 o posterior). No funciona en Mac con Intel.

## Instalar

$OPEN_STEPS

$KEYCHAIN_NOTE

## Código fuente y licencias

- **Glasstube** (MIT): [$TAG]($REPO_URL/tree/$TAG). Reimplementa [SmartTube](https://github.com/yuliskov/SmartTube) (MIT).
- **Libmpv.framework** (LGPL-3.0-o-posterior), dentro de \`Glasstube.app/Contents/Frameworks/\`: mpv y FFmpeg, enlazados
  de forma dinámica, a partir de los binarios LGPL de MPVKit 1.1.0-n9.0.2. Código fuente correspondiente:
  - MPVKit, con sus parches y los scripts que fijan la versión de cada biblioteca:
    [mpvkit/MPVKit@${MPVKIT_COMMIT:0:7}](https://github.com/mpvkit/MPVKit/tree/$MPVKIT_COMMIT)
  - [mpv v0.41.0](https://github.com/mpv-player/mpv/tree/v0.41.0) y [FFmpeg n9.0.2](https://github.com/FFmpeg/FFmpeg/tree/n9.0.2)
  - Las demás bibliotecas, sus versiones y la suma SHA-256 de cada binario:
    [App/Licenses/libmpv-sources.txt]($REPO_URL/blob/$TAG/App/Licenses/libmpv-sources.txt) y
    [THIRD-PARTY-NOTICES.md]($REPO_URL/blob/$TAG/THIRD-PARTY-NOTICES.md)
  - Para rehacerla: \`PlaybackKit/Scripts/fetch-libmpv.sh\` y \`link-libmpv.sh\`. Para usar otra compilación, reemplaza
    \`Libmpv.framework\` y vuelve a firmar la app: \`codesign --force --deep --sign - /Applications/Glasstube.app\`.
- Los textos completos de las licencias van en \`Glasstube.app/Contents/Resources/Licenses/\`.

## English

Glasstube $VERSION for **macOS 26 or later on Apple silicon**. Not affiliated with YouTube or Google.

$OPEN_STEPS_EN

$UPDATES_TEXT_EN Source
code: [$TAG]($REPO_URL/tree/$TAG); the LGPL sources for the bundled libmpv are linked above.

---

<sub>Versión $VERSION ($BUILD_NUMBER) · $SIGN_TEXT · $([ "$NOTARIZED" = "1" ] && echo "notarizada" || echo "sin notarizar") · DMG $LAYOUT</sub>
NOTES

# --- 5. Sparkle: firma EdDSA del DMG y entrada del appcast ------------------------------------------------------------

APPCAST_DONE=0
if [ -n "$SPARKLE_KEY" ]; then
    log "Firma EdDSA del DMG para Sparkle"
    KEY_ARGS=()
    [ -n "${SPARKLE_ED_KEY_FILE:-}" ] && KEY_ARGS=(--ed-key-file "$SPARKLE_ED_KEY_FILE")
    # sign_update lee la clave privada del Llavero (macOS puede pedir permiso); imprime `sparkle:edSignature="…" …length="…"`.
    SIGNED="$("$SPARKLE_BIN/sign_update" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$DMG")" || {
        echo "sign_update no pudo firmar. ¿Creaste la clave con generate_keys en esta Mac (o pasaste SPARKLE_ED_KEY_FILE)?" >&2
        exit 1
    }
    ED_SIGNATURE="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' <<<"$SIGNED")"
    ED_LENGTH="$(sed -n 's/.*length="\([0-9]*\)".*/\1/p' <<<"$SIGNED")"
    [ -n "$ED_SIGNATURE" ] && [ "$ED_LENGTH" = "$(stat -f %z "$DMG")" ] || { echo "Salida inesperada de sign_update: $SIGNED" >&2; exit 1; }
    # La pareja de la clave privada tiene que ser la clave pública que viaja en la app; si no, nadie podría actualizar.
    swift "$APP_DIR/Scripts/verificar-firma-sparkle.swift" "$SPARKLE_KEY" "$ED_SIGNATURE" "$DMG" || {
        echo "La clave privada con la que firmaste no es la de Packaging/sparkle-clave-publica.txt" >&2
        exit 1
    }
    DMG_URL="${DMG_URL:-$REPO_URL/releases/download/$TAG/$(basename "$DMG")}"
    python3 -I "$APP_DIR/Scripts/appcast-entrada.py" "$APPCAST" "$VERSION" "$BUILD_NUMBER" "$DMG_URL" "$ED_SIGNATURE" \
        "$ED_LENGTH" "$REPO_URL/releases/tag/$TAG" "$MINIMUM_SYSTEM" ${CAMBIOS:+"$CAMBIOS"}
    "$SPARKLE_BIN/sign_update" ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$APPCAST" >/dev/null
    "$SPARKLE_BIN/sign_update" --verify ${KEY_ARGS[@]+"${KEY_ARGS[@]}"} "$APPCAST" >/dev/null || { echo "El appcast firmado no se verifica" >&2; exit 1; }
    APPCAST_DONE=1
fi

log "Listo"
echo "  $DMG ($SIZE, $LAYOUT)"
echo "  $DMG.sha256: $SHA256"
echo "  $NOTES"
echo "  Firma: $SIGN_TEXT · $([ "$NOTARIZED" = "1" ] && echo "notarizada y engrapada" || echo "sin notarizar")"
echo
[ "$APPCAST_DONE" = "1" ] && echo "  $APPCAST: entrada de $VERSION ($BUILD_NUMBER), firmado"
echo
echo "Para publicarla (lo haces tú): crea la versión $TAG en $REPO_URL/releases/new con el texto de"
echo "$(basename "$NOTES") y adjunta el .dmg y el .sha256. No la marques como «pre-release» y déjala como «Latest»: las"
echo "apps 0.4 y 0.5 (sin Sparkle) consultan releases/latest. Las versiones de Windows (windows-v…) van con --latest=false."
echo "Con gh:"
echo "  gh release create $TAG \"$DMG\" \"$DMG.sha256\" --title \"Glasstube $VERSION\" --notes-file \"$NOTES\" --latest"
if [ "$APPCAST_DONE" = "1" ]; then
    echo "Después (cuando el DMG ya esté en la versión de GitHub), sube el appcast a main; Sparkle lo lee de ahí:"
    echo "  git -C \"$ROOT\" add \"$APPCAST\" && git -C \"$ROOT\" commit -m \"Appcast: Glasstube $VERSION\" && git -C \"$ROOT\" push"
fi
