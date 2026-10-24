<#
.SYNOPSIS
  Rehace las capturas públicas de la app de Windows (docs/capturas/windows) con Windows/out/app (build.ps1 antes).

.DESCRIPTION
  Como App/Scripts/capturas.sh en la Mac: solo contenido Creative Commons (Big Buck Bunny, © Blender Foundation,
  CC BY 3.0) y con --capturas, que no muestra la cuenta ni los canales suscritos y pone a quien comenta como @personaN.
  Cada captura abre la app, espera y guarda la ventana (PrintWindow, sin lo que haya alrededor). Revisa las capturas
  antes de subirlas: los sugeridos y los comentarios cambian.

.EXAMPLE
  .\Installer\capturas.ps1              # todas
  .\Installer\capturas.ps1 comentarios  # las que contienen "comentarios"
#>
param([string] $Filter = '')
$ErrorActionPreference = 'Stop'
$windows = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $windows 'out\app\Glasstube.exe'
$out = Join-Path (Split-Path $windows -Parent) 'docs\capturas\windows'
if (-not (Test-Path $exe)) { throw "Falta ${exe}: corre build.ps1" }
New-Item -ItemType Directory -Force $out | Out-Null

Add-Type -ReferencedAssemblies System.Drawing @'
using System; using System.Drawing; using System.Runtime.InteropServices;
public static class WindowShot {
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll")] static extern bool PrintWindow(IntPtr window, IntPtr dc, uint flags);
    struct Rect { public int Left, Top, Right, Bottom; }
    public static void Save(IntPtr window, string path) {
        SetProcessDPIAware(); // si no, GetWindowRect da el tamaño a 100 % y se recorta la ventana
        Rect r; GetWindowRect(window, out r);
        using (var bitmap = new Bitmap(r.Right - r.Left, r.Bottom - r.Top)) {
            using (var g = Graphics.FromImage(bitmap)) { var dc = g.GetHdc(); PrintWindow(window, dc, 2); g.ReleaseHdc(dc); }
            bitmap.Save(path, System.Drawing.Imaging.ImageFormat.Png);
        }
    }
}
'@

# Start-Process junta los argumentos con espacios: uno que lleva espacios va entre comillas.
function Shot([string] $name, [int] $wait, [string[]] $arguments) {
    if ($Filter -and $name -notlike "*$Filter*") { return }
    $app = Start-Process $exe -ArgumentList (@('--capturas') + $arguments) -WorkingDirectory (Split-Path $exe) -PassThru
    try {
        Start-Sleep $wait
        $app.Refresh()
        if ($app.HasExited) { throw "Glasstube se cerró antes de la captura $name" }
        [WindowShot]::Save($app.MainWindowHandle, (Join-Path $out "$name.png"))
        Write-Host "docs/capturas/windows/$name.png"
    } finally {
        if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force }
        Start-Sleep 1
    }
}

$bunny = 'aqz-KE-bpKQ'
Shot 'reproductor' 16 @('--tema', 'oscuro', '--abrir', $bunny, '--desde', '75')
Shot 'comentarios' 20 @('--tema', 'oscuro', '--abrir', $bunny, '--desde', '75', '--panel', 'comentarios')
Shot 'busqueda' 12 @('--tema', 'oscuro', '--buscar', '"big buck bunny blender"')
