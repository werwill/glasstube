# Avisos de terceros de Glasstube

Glasstube es una reimplementación para macOS de **SmartTube** (© 2020-present yuliskov, licencia MIT; texto en
`SmartTube-MIT.txt`). Su lógica se portó con crédito; el código de Glasstube es nuevo.

## mpv y FFmpeg (Libmpv.framework, LGPL)

`Contents/Frameworks/Libmpv.framework` es una biblioteca dinámica que se puede reemplazar. Contiene, enlazados en un
solo binario y exportando solo la API cliente de mpv (`mpv_*`):

| Componente | Versión | Licencia |
|---|---|---|
| mpv (compilado con `-Dgpl=false`) | 0.41.0 (parches de MPVKit) | LGPL-2.1-o-posterior |
| FFmpeg (`--enable-version3`, sin `--enable-gpl` ni `--enable-nonfree`) | n9.0.2 | LGPL-3.0-o-posterior |
| libplacebo | 7.360.1 | LGPL-2.1-o-posterior |
| libass | 0.17.5 | ISC |
| FreeType | — | FTL |
| FriBidi | — | LGPL-2.1-o-posterior |
| HarfBuzz | — | MIT |
| libunibreak | — | zlib |
| MoltenVK | 1.4.2 | Apache-2.0 |
| shaderc | — | Apache-2.0 |
| Little-CMS | — | MIT |
| libdovi | — | MIT |
| dav1d | 1.5.3 | BSD-2-Clause |
| uavs3d | — | BSD-3-Clause |
| uchardet | — | MPL-1.1 / LGPL-2.1-o-posterior |
| LuaJIT | — | MIT |
| libbluray | — | LGPL-2.1-o-posterior |
| GnuTLS (bibliotecas) | 3.8.11 | LGPL-2.1-o-posterior |
| Nettle, GMP | — | LGPL-3.0-o-posterior / GPL-2.0-o-posterior |
| OpenSSL | 3.3.5 | Apache-2.0 |

El conjunto queda, como obra, bajo **LGPL-3.0-o-posterior**. Detalle y verificación de cada licencia en
`PlaybackKit/NOTAS.md` («libmpv: origen, licencia y enlace»).

**Código fuente:** binarios de MPVKit 1.1.0-n9.0.2 (github.com/mpvkit/MPVKit, commit
`98c3453e252922e3136422da3fbb2e341ed9edc8`), variantes LGPL, con sus parches y scripts de compilación públicos;
`PlaybackKit/Scripts/fetch-libmpv.sh` y `link-libmpv.sh` rehacen el framework (SHA-256 de cada entrada en
`libmpv-sources.txt`).

**Reemplazar la biblioteca:** se sustituye `Libmpv.framework` por otra compilación compatible y se vuelve a firmar la
app con `codesign --force --deep --sign - Glasstube.app`. Vale para todas las versiones: las que se firman ad hoc o con
un certificado propio no llevan *hardened runtime*, y en las notarizadas (Developer ID y hardened runtime) la firma ad
hoc nueva reemplaza a la original sin hardened runtime, así que la validación de bibliotecas deja cargar la nueva.

**Código fuente de las versiones para descargar:** las notas de cada versión en GitHub Releases enlazan el código de
Glasstube en esa etiqueta, MPVKit en el commit de arriba y mpv v0.41.0 y FFmpeg n9.0.2.

Textos de licencia incluidos: `LGPL-2.1.txt`, `LGPL-3.0.txt` y `GPL-3.0.txt` (LGPLv3 se apoya en la GPLv3).
`LGPL-3.0.txt` y `GPL-3.0.txt` se descargaron de https://www.gnu.org/licenses/lgpl-3.0.txt y
https://www.gnu.org/licenses/gpl-3.0.txt el 15-oct-2026 (SHA-256 `e3a994d8…5c5f23118` y `3972dc97…9dfb36986`).
`Scripts/package-app.sh` copia todo `App/Licenses/` en `Contents/Resources/Licenses/` y avisa si falta alguno.

## yt-dlp/ejs (solver de `n` y firma)

`YTKit_YTKit.bundle/…/nsigsolver/yt.solver.core.js` sale de github.com/yt-dlp/ejs (Unlicense), con meriyah 6.1.4
(ISC, texto en `meriyah-ISC.txt`) y astring 1.9.0 (MIT, texto en `astring-MIT.txt`). `tcl.solver.js`, `polyfill.js` y
`potoken/po_token2.html` vienen de SmartTube (MediaServiceCore, MIT).
