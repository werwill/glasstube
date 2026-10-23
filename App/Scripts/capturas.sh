#!/bin/bash
# Rehace las capturas de capturas/ con build/Glasstube.app (Scripts/package-app.sh antes). Lanza la app con las opciones
# de prueba de Sources/Glasstube/Support/Automation.swift (GT…) y captura solo su ventana con `screencapture -l`.
# Necesita el permiso de Grabación de pantalla para la terminal. Cada captura activa la app unos segundos.
#
#   Scripts/capturas.sh            # todas
#   Scripts/capturas.sh inicio     # las que contienen "inicio"
#   CON_SESION=1 Scripts/capturas.sh sesion   # las de la cuenta (hace falta haber iniciado sesión en la app)
#
# Todas usan la bóveda en memoria (-GTSinLlavero): sin sesión y sin el aviso del Llavero tras recompilar. Solo las de
# CON_SESION=1 leen el Llavero de verdad (CON_LLAVERO=1 en `shot`).
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXE="$APP_DIR/build/Glasstube.app/Contents/MacOS/Glasstube"
OUT="$APP_DIR/capturas"
TMP="$(mktemp -d)"
FILTER="${1:-}"
mkdir -p "$OUT"

shot() {
    local name="$1" wait="$2"; shift 2
    [[ -z "$FILTER" || "$name" == *"$FILTER"* ]] || return 0
    pkill -f "Glasstube.app/Contents/MacOS/Glasstube" || true
    sleep 1
    rm -f "$TMP/wid"
    local store=(-GTSinLlavero YES)
    [[ "${CON_LLAVERO:-0}" == 1 ]] && store=()
    "$EXE" -GTWindowFile "$TMP/wid" -GTWindowSize 1440x900 ${store[@]+"${store[@]}"} "$@" > "$TMP/$name.log" 2>&1 &
    if [[ "${ACTIVAR:-0}" == 1 ]]; then
        # Con una hoja abierta, la ventana sale inactiva si otra app tiene el foco: `open` trae la que ya corre al frente.
        sleep $((wait - 2)); osascript -e 'tell application id "mx.glasstube.Glasstube" to activate' >/dev/null 2>&1 || open "$APP_DIR/build/Glasstube.app"; sleep 2
    else
        sleep "$wait"
    fi
    screencapture -x -o -l"$(cat "$TMP/wid")" "$OUT/$name.png"
    echo "capturas/$name.png"
}

# Reproductor como la maqueta: menú de calidad, burbuja del storyboard y "Saltar patrocinio" (tramo real de SponsorBlock
# en qF4vZxbSmjo, 399–440 s).
PLAYER=(-GTPlay qF4vZxbSmjo -GTStartAt 404 -GTKeepControls YES -GTScrub 352 -GTPopover quality)
shot reproductor-claro 17 -appearance light "${PLAYER[@]}"
shot reproductor-oscuro 17 -appearance dark "${PLAYER[@]}"
shot reproductor-controles-ocultos 13 -appearance dark -GTPlay aqz-KE-bpKQ -GTStartAt 210 -GTHidden YES
shot reproductor-foco-teclado 14 -appearance dark -GTPlay rfscVS0vtbw -GTStartAt 1500 -GTKeepControls YES -GTKeys "4:down,5:right,6:right,7:right"
# Inicio: la primera tarjeta de "Para ti" con la vista previa (el estado por omisión de la maqueta). "Seguir viendo"
# sale del historial local que dejan las corridas del reproductor.
shot inicio-claro 12 -appearance light -GTHoverIndex 0
shot inicio-oscuro 12 -appearance dark -GTHoverIndex 0
shot busqueda-claro 11 -appearance light -GTSearch "lofi hip hop" -GTKeys "7:down,8:right"
shot canal-oscuro 11 -appearance dark -GTChannel @MKBHD
shot ajustes-reproductor-claro 7 -appearance light -GTOpenSettings YES -settingsTab player
shot ajustes-interfaz-oscuro 7 -appearance dark -GTOpenSettings YES -settingsTab interface
# Cuentas (fase 2). La hoja pide un código real a YouTube; vence solo si nadie lo usa. Las de "con sesión" necesitan una
# cuenta iniciada en la app (y el permiso del Llavero); -GTAnonimo cambia nombre, correo y avatar por unos de prueba.
shot cuenta-inicio-sesion-claro 8 -appearance light -GTSignIn YES
shot cuenta-inicio-sesion-oscuro 8 -appearance dark -GTSignIn YES
shot ajustes-cuentas-claro 7 -appearance light -GTOpenSettings YES -settingsTab accounts
# Solo pantallas sin contenido de la cuenta (Suscripciones, Historial e Inicio con sesión muestran lo que ve la cuenta y
# no se guardan aquí).
if [[ "${CON_SESION:-0}" == 1 ]]; then
    CON_LLAVERO=1 shot sesion-guardar-en-playlist-claro 10 -appearance light -GTAnonimo YES -GTSection music -GTPlaylistPicker aqz-KE-bpKQ
    CON_LLAVERO=1 shot sesion-reproductor-oscuro 16 -appearance dark -GTAnonimo YES -GTPlay aqz-KE-bpKQ -GTStartAt 30 -GTKeepControls YES
    CON_LLAVERO=1 shot sesion-ajustes-cuentas-claro 8 -appearance light -GTAnonimo YES -GTOpenSettings YES -settingsTab accounts
fi
# Fase 3 (contenido Creative Commons: Big Buck Bunny y Sintel de la Blender Foundation). -GTSinPersonas: quien comenta
# sale como @personaN con un círculo en lugar de su foto.
F3=(-GTSinPersonas YES -appearance dark -GTKeepControls YES)
shot panel-comentarios-oscuro 18 "${F3[@]}" -GTPlay aqz-KE-bpKQ -GTStartAt 60 -GTPanel comments -GTPanelFocus 2 -GTPanelFocusDelay 6
shot panel-descripcion-oscuro 16 "${F3[@]}" -GTPlay aqz-KE-bpKQ -GTStartAt 60 -GTPanel description
shot a-continuacion-oscuro 19 "${F3[@]}" -GTPlay aqz-KE-bpKQ -GTStartAt 626 -GTQueue eRsGyueVLvQ
shot dearrow-busqueda-claro 12 -appearance light -deArrowEnabled YES -GTSearch "big buck bunny blender"
# Minirreproductor: la ventana flotante (su propio número de ventana) y la principal de vuelta en la navegación.
shot_mini() {
    local name="$1" wait="$2"; shift 2
    [[ -z "$FILTER" || "$name" == *"$FILTER"* ]] || return 0
    pkill -f "Glasstube.app/Contents/MacOS/Glasstube" || true
    sleep 1
    rm -f "$TMP/wid" "$TMP/mwid"
    "$EXE" -GTWindowFile "$TMP/wid" -GTMiniWindowFile "$TMP/mwid" -GTWindowSize 1440x900 -GTSinLlavero YES "$@" > "$TMP/$name.log" 2>&1 &
    sleep "$wait"
    screencapture -x -o -l"$(cat "$TMP/mwid")" "$OUT/$name.png"
    echo "capturas/$name.png"
}
shot_mini minirreproductor 14 -appearance dark -GTKeepControls YES -GTPlay aqz-KE-bpKQ -GTStartAt 120 -GTMini 3 -GTSection home
# Fase 4: la hoja «Vincular un teléfono» con un código DE PRUEBA (-GTCodigoDePrueba: 123-456-789-012, sin pedirlo a
# YouTube) y Ajustes > Control remoto. -GTRemotoEnMemoria: una pantalla de Lounge desechable (no toca la vinculación
# guardada); -remoteName: un nombre sin el de la Mac. De fondo, una búsqueda de Big Buck Bunny (Blender, CC BY): ni el
# historial de esta Mac ni caras.
F4=(-GTRemotoEnMemoria YES -remoteEnabled YES -remoteName "Glasstube en la Mac")
ACTIVAR=1 shot vincular-telefono-claro 10 -appearance light "${F4[@]}" -GTCodigoDePrueba YES -GTPairing 4 -GTSearch "big buck bunny blender"
ACTIVAR=1 shot vincular-telefono-oscuro 10 -appearance dark "${F4[@]}" -GTCodigoDePrueba YES -GTPairing 4 -GTSearch "big buck bunny blender"
ACTIVAR=1 shot ajustes-control-remoto-claro 9 -appearance light "${F4[@]}" -GTOpenSettings YES -settingsTab remote
# Fase 5a: grupos de canales, suscripciones de esta Mac, filtros de búsqueda y bloqueos. Grupos, suscripciones e
# historial solo en memoria (no tocan groups.json ni library.json); sin control remoto. Los feeds RSS son reales, pero
# -GTSoloVideos deja a la vista solo videos del canal oficial de Blender con licencia Creative Commons (CC BY, «permite
# reutilización» en `next`) y sin caras de personas, revisados el 23-oct-2026. El RSS solo trae los 15 últimos de cada
# canal: si estos ya no salen, elige otros (`ytkit rss UCSMOQeBJ2RAnuFungnQOxLg`) y revisa sus miniaturas.
BLENDER=UCSMOQeBJ2RAnuFungnQOxLg
STUDIO=UCz75RVbH8q2jdBJ4SnwuZZQ
CC_BLENDER="dVrELpmfcEQ,k6l1CK0O_r4,YsKxkP_kGbE,EycY6jDFK74"
F5=(-GTGruposEnMemoria YES -GTBibliotecaEnMemoria YES -remoteEnabled NO -GTSoloVideos "$CC_BLENDER"
    -GTGrupos "Blender=$BLENDER;Software libre=$BLENDER;Animación 3D=$BLENDER")
ACTIVAR=1 shot grupo-claro 13 -appearance light "${F5[@]}" -GTGrupo Blender
ACTIVAR=1 shot grupo-oscuro 13 -appearance dark "${F5[@]}" -GTGrupo Blender
ACTIVAR=1 shot grupo-canales-claro 12 -appearance light "${F5[@]}" -GTGrupo Blender -GTEditarGrupo Blender
ACTIVAR=1 shot grupo-nuevo-oscuro 11 -appearance dark "${F5[@]}" -GTGrupo Blender -GTNuevoGrupo YES
ACTIVAR=1 shot suscripciones-esta-mac-oscuro 13 -appearance dark "${F5[@]}" -GTSuscripcionesLocales "$BLENDER,$STUDIO" -GTSection subscriptions
# Con un menú abierto: `screencapture -R` con el marco de la ventana (con -l el menú no sale). El menú se abre con un
# clic real (en 1440×900: el botón de filtros a la derecha del título; «En 3 grupos» en la cabecera del canal).
shot_rect() {
    local name="$1" wait="$2"; shift 2
    [[ -z "$FILTER" || "$name" == *"$FILTER"* ]] || return 0
    pkill -f "Glasstube.app/Contents/MacOS/Glasstube" || true
    sleep 1
    rm -f "$TMP/wid" "$TMP/frame"
    "$EXE" -GTWindowFile "$TMP/wid" -GTWindowFrameFile "$TMP/frame" -GTWindowSize 1440x900 -GTSinLlavero YES "$@" > "$TMP/$name.log" 2>&1 &
    sleep "$wait"
    # -R captura lo que haya en pantalla en ese rectángulo: solo si Glasstube quedó al frente (la app se trae sola con
    # -GTWindowFrameFile, pero si se usa otra app mientras tanto, saldría esa).
    if ! lsappinfo info -only bundleid "$(lsappinfo front)" | grep -q 'mx.glasstube.Glasstube'; then
        echo "capturas/$name.png: Glasstube no quedó al frente; no se captura (repítela sin usar otra app)" >&2
        return 0
    fi
    screencapture -x -R"$(cat "$TMP/frame")" "$OUT/$name.png"
    echo "capturas/$name.png"
}
shot_rect filtros-busqueda-claro 13 -appearance light -remoteEnabled NO -GTBibliotecaEnMemoria YES -GTSearch "big buck bunny blender" \
    -GTFiltro "tipo=video,duracion=3-20,cc" -GTClicks "9:1340;84"
shot_rect canal-grupos-oscuro 14 -appearance dark "${F5[@]}" -GTChannel $BLENDER -GTClicks "10:1222;312"
shot filtros-sin-resultados-oscuro 12 -appearance dark -remoteEnabled NO -GTBibliotecaEnMemoria YES -GTSearch "blender open movie" \
    -GTFiltro "tipo=shorts,cc"
# Ajustes: la pestaña Bloqueos (canales de prueba, ids inventados) y Respaldo tras importar el PocketTube de las pruebas.
ACTIVAR=1 shot ajustes-bloqueos-claro 8 -appearance light "${F5[@]}" -GTOpenSettings YES -settingsTab blocked \
    -GTBloquear "UCcanaldeprueba000000001=Canal de prueba 1;UCcanaldeprueba000000002=Canal de prueba 2"
ACTIVAR=1 shot ajustes-respaldo-claro 8 -appearance light -GTGruposEnMemoria YES -GTBibliotecaEnMemoria YES -remoteEnabled NO \
    -GTImportar "$APP_DIR/../YTKit/Tests/YTKitTests/Fixtures/descubrir/pockettube.json" -GTOpenSettings YES -settingsTab backup
pkill -f "Glasstube.app/Contents/MacOS/Glasstube" || true
