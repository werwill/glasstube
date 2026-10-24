<#
.SYNOPSIS
  Compila Glasstube para Windows: GlasstubeFFI.dll (Swift), MPVBridge.dll (C + libmpv) y la app WinUI 3 (C#).

.DESCRIPTION
  1. swift build del paquete Windows/GlasstubeFFI (YTKit + GlasstubeCore → GlasstubeFFI.dll).
  2. clang de Windows/MPVBridge/MPVBridge.c contra libmpv (PlaybackKit/Vendor/windows-x64, que deja
     PlaybackKit/Scripts/fetch-libmpv-windows.sh).
  3. Junta en Windows/out/native las DLL nativas: runtime de Swift, GlasstubeFFI, MPVBridge, libmpv-2 y los recursos
     de YTKit (YTKit_YTKit.bundle).
  4. dotnet build de Windows/Glasstube.App, que copia Windows/out/native junto al exe.

  Necesita: Swift 6.4 (con su runtime en %LOCALAPPDATA%\Programs\Swift\Runtimes), VS Build Tools 2022 + Windows SDK,
  SDK de .NET 8 y el runtime de Windows App SDK 1.7.

.EXAMPLE
  .\build.ps1                 # Release y ejecutar después: .\out\app\Glasstube.exe
  .\build.ps1 -Run            # compila y abre la app
  .\build.ps1 -SkipSwift      # solo la app y el puente de video (la DLL de Swift ya compilada)
#>
param(
    [ValidateSet('release', 'debug')] [string] $Configuration = 'release',
    [switch] $SkipSwift,
    [switch] $Run
)
$ErrorActionPreference = 'Stop'
$windows = $PSScriptRoot
$repo = Split-Path $windows -Parent
$out = Join-Path $windows 'out'
$native = Join-Path $out 'native'
$vendor = Join-Path $repo 'PlaybackKit\Vendor\windows-x64'

# Las shells abiertas antes de instalar Swift no tienen su PATH ni SDKROOT.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
foreach ($name in 'SDKROOT', 'DEVELOPER_DIR') {
    $value = [Environment]::GetEnvironmentVariable($name, 'User')
    if (-not $value) { $value = [Environment]::GetEnvironmentVariable($name, 'Machine') }
    if ($value) { Set-Item "env:$name" $value }
}

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Check($what) { if ($LASTEXITCODE -ne 0) { throw "$what falló (código $LASTEXITCODE)" } }

if (-not (Test-Path "$vendor\bin\libmpv-2.dll")) {
    throw "Falta libmpv en $vendor. Bájala con: bash PlaybackKit/Scripts/fetch-libmpv-windows.sh"
}

# 1. GlasstubeFFI (Swift)
$ffi = Join-Path $windows 'GlasstubeFFI'
if (-not $SkipSwift) {
    Step "GlasstubeFFI ($Configuration)"
    Push-Location $ffi
    try { swift build -c $Configuration --product GlasstubeFFI; Check 'swift build' } finally { Pop-Location }
}
$swiftConfig = if ($Configuration -eq 'release') { 'Release' } else { 'Debug' }
$products = Join-Path $ffi ".build\out\Products\$swiftConfig-windows-x86_64"
if (-not (Test-Path "$products\GlasstubeFFI.dll")) { throw "No está $products\GlasstubeFFI.dll" }

# 2. MPVBridge (C)
Step 'MPVBridge'
$bridgeOut = Join-Path $out 'mpvbridge'
New-Item -ItemType Directory -Force $bridgeOut | Out-Null
clang -O2 -shared -D_CRT_SECURE_NO_WARNINGS -o "$bridgeOut\MPVBridge.dll" "$windows\MPVBridge\MPVBridge.c" `
    -I "$vendor\include" -L "$vendor\lib" -lmpv -ld3d11 -ldxgi -ldxguid -luuid
Check 'clang MPVBridge'

# 3. DLL nativas junto al exe
Step 'DLL nativas'
if (Test-Path $native) { Remove-Item -Recurse -Force $native }
New-Item -ItemType Directory -Force $native | Out-Null
$runtime = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes" -Directory | Sort-Object Name -Descending | Select-Object -First 1
if (-not $runtime) { throw 'No encuentro el runtime de Swift en %LOCALAPPDATA%\Programs\Swift\Runtimes' }
# El runtime entero (~70 MB, con el de VC++ que trae): si falta una DLL la app no arranca (0xC0000135).
Copy-Item (Join-Path $runtime.FullName 'usr\bin\*.dll') $native
Copy-Item "$products\GlasstubeFFI.dll", "$bridgeOut\MPVBridge.dll", "$vendor\bin\libmpv-2.dll" $native
Copy-Item -Recurse "$products\YTKit_YTKit.bundle" $native
$size = (Get-ChildItem $native -Recurse | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("{0:n0} MB en {1} (runtime de Swift {2})" -f $size, $native, $runtime.Name)

# 4. App WinUI 3
Step 'Glasstube.App'
$appOut = Join-Path $out 'app'
$dotnetConfig = if ($Configuration -eq 'release') { 'Release' } else { 'Debug' }
dotnet build "$windows\Glasstube.App\Glasstube.App.csproj" -c $dotnetConfig -p:Platform=x64 -o $appOut --nologo -v minimal
Check 'dotnet build'
Write-Host "`nListo: $appOut\Glasstube.exe" -ForegroundColor Green

if ($Run) { Start-Process "$appOut\Glasstube.exe" -WorkingDirectory $appOut }
