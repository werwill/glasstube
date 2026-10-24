# Prueba de libmpv en Windows

`mpvwin.cpp` es una ventana Win32 mínima que reproduce una URL con la libmpv LGPL para Windows x64. Sirve para
comprobar, antes de escribir Swift para Windows, que la DLL, el decodificador por hardware (d3d11va) y cada camino de
salida D3D11 funcionan, también con el HLS de un directo de YouTube.

## Armar y compilar

En Git Bash (Windows) o en Linux/macOS con MinGW (`x86_64-w64-mingw32-g++`):

```bash
PlaybackKit/Scripts/fetch-libmpv-windows.sh   # Vendor/windows-x64: libmpv-2.dll, cabeceras, mpv.lib, module.modulemap
PlaybackKit/Prototypes/windows/build.sh       # Prototypes/windows/build/mpvwin.exe + libmpv-2.dll
```

Con MSVC, desde `PlaybackKit/Prototypes/windows`:

```bat
cl /std:c++17 /EHsc /I ..\..\Vendor\windows-x64\include mpvwin.cpp /link /LIBPATH:..\..\Vendor\windows-x64\lib mpv.lib d3d11.lib dxgi.lib dcomp.lib user32.lib gdi32.lib
copy ..\..\Vendor\windows-x64\bin\libmpv-2.dll .
```

## Qué probar

```bat
mpvwin --mode window URL
mpvwin --mode composition URL
mpvwin --mode render URL          :: solo con las cabeceras de mpv 0.42 (API cliente 2.6)
mpvwin --live --mode window HLS   :: el manifiesto de un directo
```

Teclas: espacio pausa, ←/→ ±10 s, V siguiente pista de video (en un HLS, la siguiente calidad), Esc sale. Cada 2 s la
consola muestra la posición, la caché, la pista, el decodificador (`hwdec=d3d11va` es lo esperado), los cuadros
caídos y el tamaño de la salida.

Para conseguir la URL HLS de un directo: `yt-dlp -g <URL del directo>` (caduca en unas horas). La misma prueba con
MPVEngine en el Mac, sin URL a mano: `swift run PlaybackDemo <videoId> --live-engine mpv`.

Lo que hay que anotar:

- `--mode window`: ¿se ve, usa d3d11va, sigue el cambio de tamaño de la ventana?
- `--mode composition`: ¿se ve? Al cambiar el tamaño de la ventana, ¿el tamaño de la swapchain que muestra la consola
  cambia también? En el código de mpv 0.41 no vi que lo haga; si no cambia, este modo necesita un arreglo en mpv o
  recargar la VO.
- `--live`: tiempo hasta el primer cuadro, si V cambia de calidad y cuánto tarda, si la caché se mantiene.
