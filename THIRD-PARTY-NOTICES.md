# Avisos de terceros

Glasstube es código nuevo bajo la licencia MIT (ver [LICENSE](LICENSE)). Reimplementa para macOS la lógica de
**SmartTube** y usa piezas de otros proyectos libres. Este archivo resume qué se usa, de dónde viene y con qué licencia.
Los textos completos están en [App/Licenses/](App/Licenses/), y `App/Scripts/package-app.sh` los copia en
`Glasstube.app/Contents/Resources/Licenses/`.

*Third-party notices: Glasstube is new MIT-licensed code that reimplements SmartTube for macOS. It ships mpv and FFmpeg
as a replaceable LGPL dynamic library and bundles the yt-dlp/ejs challenge solver (Unlicense) with meriyah (ISC) and
astring (MIT). Full texts are in `App/Licenses/`.*

## Código y recursos incluidos

| Componente | Dónde está | Licencia | Texto |
|---|---|---|---|
| **SmartTube** (yuliskov): la lógica portada a Swift (catálogo, cuentas, streams, SABR, PoToken, control remoto) | todo `YTKit/`, `PlaybackKit/YouTubeSource/` y `App/` | MIT, © 2020-present yuliskov | [SmartTube-MIT.txt](App/Licenses/SmartTube-MIT.txt) |
| **SmartTube / MediaServiceCore**: `po_token2.html` (cliente de BotGuard para el PoToken), `tcl.solver.js` y `polyfill.js` | `YTKit/Sources/YTKit/Resources/potoken/` y `…/nsigsolver/` | MIT, © 2020-present yuliskov | [SmartTube-MIT.txt](App/Licenses/SmartTube-MIT.txt) |
| **yt-dlp/ejs**: `yt.solver.core.js` (resuelve los desafíos `n` y de firma del reproductor de YouTube) | `YTKit/Sources/YTKit/Resources/nsigsolver/` | Unlicense (dominio público) | encabezado del archivo |
| **meriyah** 6.1.4 (analizador de JavaScript que usa el solver) | `…/nsigsolver/meriyah-6.1.4.min.js` | ISC, © 2019 and later, KFlash and others | [meriyah-ISC.txt](App/Licenses/meriyah-ISC.txt) |
| **astring** 1.9.0 (generador de JavaScript que usa el solver) | `…/nsigsolver/astring-1.9.0.min.js` | MIT, © 2015 David Bonnet | [astring-MIT.txt](App/Licenses/astring-MIT.txt) |
| **QuickJS** (quickjs-ng 0.17.0): motor de JavaScript del solver fuera de Apple; solo se compila en Windows (y Linux) | `YTKit/Sources/CQuickJS/` | MIT, © 2017-2026 Fabrice Bellard, Charlie Gordon, Ben Noordhuis y otros | [LICENSE](YTKit/Sources/CQuickJS/LICENSE) |
| **WebView2** `WebView2.h` (paquete NuGet Microsoft.Web.WebView2 1.0.4258.31): interfaces COM del WebView del PoToken en Windows | `YTKit/Sources/CWebView2/` | BSD-3-Clause, © Microsoft Corporation | [LICENSE-WebView2.txt](YTKit/Sources/CWebView2/LICENSE-WebView2.txt) |

## Biblioteca que se descarga al compilar (no está en el repositorio)

`PlaybackKit/Scripts/fetch-libmpv.sh` descarga los binarios de **MPVKit** 1.1.0-n9.0.2 (github.com/mpvkit/MPVKit, solo
las variantes LGPL) y `link-libmpv.sh` los enlaza en `Libmpv.framework`, una biblioteca dinámica que la app carga desde
`Contents/Frameworks/` y que se puede reemplazar por otra compilación, como pide la LGPL.

| Componente | Licencia |
|---|---|
| mpv 0.41.0 (compilado con `-Dgpl=false`) | LGPL-2.1-o-posterior |
| FFmpeg n9.0.2 (`--enable-version3`, sin `--enable-gpl` ni `--enable-nonfree`) | LGPL-3.0-o-posterior |
| libplacebo, FriBidi, libbluray, GnuTLS | LGPL-2.1-o-posterior |
| Nettle, GMP | LGPL-3.0-o-posterior / GPL-2.0-o-posterior |
| libass (ISC), FreeType (FTL), HarfBuzz (MIT), libunibreak (zlib), MoltenVK y shaderc (Apache-2.0), Little-CMS (MIT), libdovi (MIT), dav1d (BSD-2-Clause), uavs3d (BSD-3-Clause), uchardet (MPL-1.1 / LGPL-2.1), LuaJIT (MIT), OpenSSL 3.3.5 (Apache-2.0), MPVKit (scripts y parches) | permisivas |

En conjunto, `Libmpv.framework` queda bajo **LGPL-3.0-o-posterior**. El detalle de cada componente, las sumas SHA-256
de cada descarga y cómo reemplazar la biblioteca están en [App/Licenses/THIRD-PARTY-NOTICES.md](App/Licenses/THIRD-PARTY-NOTICES.md),
[App/Licenses/libmpv-sources.txt](App/Licenses/libmpv-sources.txt) y [PlaybackKit/NOTAS.md](PlaybackKit/NOTAS.md).
Textos: [LGPL-2.1](App/Licenses/LGPL-2.1.txt), [LGPL-3.0](App/Licenses/LGPL-3.0.txt) y [GPL-3.0](App/Licenses/GPL-3.0.txt)
(la LGPLv3 se apoya en la GPLv3).

## Fuera de macOS

En Windows (y Linux) SwiftPM descarga **swift-crypto** (github.com/apple/swift-crypto, Apache-2.0, con BoringSSL bajo
licencias ISC/OpenSSL) para el SHA-256 de DeArrow; en macOS no se compila. El PoToken en Windows necesita
`WebView2Loader.dll` (del mismo paquete NuGet, BSD-3-Clause) junto al ejecutable y el entorno de ejecución de WebView2,
que ya trae Windows 10/11.

## Servicios que consulta la app (no se incluye su código ni sus datos)

La app habla directamente con estos servicios mientras la usas. Glasstube no tiene servidor propio.

| Servicio | Para qué | Condiciones |
|---|---|---|
| YouTube (Google) | catálogo, reproducción, cuenta y control remoto | [Términos de YouTube](https://www.youtube.com/t/terms) |
| [SponsorBlock](https://sponsor.ajay.app) | saltar patrocinios y otros tramos | datos bajo CC BY-NC-SA 4.0 |
| [DeArrow](https://dearrow.ajay.app) | títulos y miniaturas de la comunidad | datos bajo CC BY-NC-SA 4.0 |
| [Return YouTube Dislike](https://returnyoutubedislike.com) | número estimado de «no me gusta» | API pública, con sus propias condiciones |

Glasstube no está afiliado a YouTube, Google, Apple ni a ninguno de estos proyectos. «YouTube» es una marca de Google LLC.

## yt-dlp/ejs (Unlicense)

`yt.solver.core.js` lleva `SPDX-License-Identifier: Unlicense` y lo generó https://github.com/yt-dlp/ejs. La Unlicense
dedica la obra al dominio público; no exige aviso, pero se da el crédito.
