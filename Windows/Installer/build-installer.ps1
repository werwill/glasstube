<#
.SYNOPSIS
  Arma el instalador de Glasstube para Windows: dist/Glasstube-<versión>-Windows-x64-Setup.exe y su SHA-256.

.DESCRIPTION
  1. build.ps1 (salvo -SkipBuild): GlasstubeFFI.dll, MPVBridge.dll y Windows/out/native.
  2. dotnet build autocontenido en Windows/out/publish: lleva .NET 8 y el Windows App SDK dentro, así que en la PC
     de quien lo instala no hace falta ningún runtime aparte (solo WebView2, que Windows 11 ya trae).
  3. ISCC (Inno Setup 6) con Glasstube.iss → dist/, igual que el .dmg de la app de Mac (dist/ no va al repositorio).

  Necesita lo mismo que build.ps1 y Inno Setup 6 (winget install JRSoftware.InnoSetup).

.EXAMPLE
  .\Installer\build-installer.ps1 -Version 0.1.0
  .\Installer\build-installer.ps1 -Version 0.1.0 -SkipBuild    # con build.ps1 ya corrido
#>
param(
    [Parameter(Mandatory)] [ValidatePattern('^\d+\.\d+\.\d+$')] [string] $Version,
    [switch] $SkipBuild
)
$ErrorActionPreference = 'Stop'
$windows = Split-Path $PSScriptRoot -Parent
$repo = Split-Path $windows -Parent
$publish = Join-Path $windows 'out\publish'
$dist = Join-Path $repo 'dist'

function Step($text) { Write-Host "`n== $text" -ForegroundColor Cyan }
function Check($what) { if ($LASTEXITCODE -ne 0) { throw "$what falló (código $LASTEXITCODE)" } }
function Native([scriptblock] $command) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $command 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $previous }
}

if (-not $SkipBuild) { & (Join-Path $windows 'build.ps1') }
if (-not (Test-Path (Join-Path $windows 'out\native\GlasstubeFFI.dll'))) { throw 'Falta Windows/out/native: corre build.ps1' }

Step "dotnet build (autocontenido) $Version"
if (Test-Path $publish) { Remove-Item -Recurse -Force $publish }
# Desde cero: con el obj/ de build.ps1 (sin autocontener) el resources.pri sale sin los recursos de WinUI y la app no
# arranca («Cannot locate resource from ms-appx:///Microsoft.UI.Xaml/Themes/themeresources.xaml»).
# Y al terminar, para que el próximo build.ps1 no herede el de aquí.
function Clean-AppBuild {
    foreach ($dir in 'obj', 'bin') {
        $path = Join-Path $windows "Glasstube.App\$dir"
        if (Test-Path $path) { Remove-Item -Recurse -Force $path }
    }
}
Clean-AppBuild
# `dotnet build` y no `publish`: publish de una app WinUI 3 sin empaquetar deja fuera los .xbf de las páginas y la app
# no arranca (XamlParseException en MainWindow.InitializeComponent).
Native { dotnet build "$windows\Glasstube.App\Glasstube.App.csproj" -c Release -p:Platform=x64 -r win-x64 `
    -p:SelfContained=true -p:WindowsAppSDKSelfContained=true -p:Version=$Version -o $publish --nologo -v minimal }
Check 'dotnet build'
Clean-AppBuild
if (-not (Test-Path "$publish\Glasstube.exe")) { throw "No está $publish\Glasstube.exe" }
# Lo que no hace falta para usarla.
Get-ChildItem $publish -Recurse -Include *.pdb | Remove-Item -Force
$size = (Get-ChildItem $publish -Recurse | Measure-Object Length -Sum).Sum / 1MB
Write-Host ("{0:n0} MB en {1}" -f $size, $publish)

Step 'Inno Setup'
$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'No encuentro ISCC.exe. Instala Inno Setup 6: winget install JRSoftware.InnoSetup' }
New-Item -ItemType Directory -Force $dist | Out-Null
Native { & $iscc /Q "/DAppVersion=$Version" "/DSourceDir=$publish" "/DOutputDir=$dist" (Join-Path $PSScriptRoot 'Glasstube.iss') }
Check 'ISCC'

$setup = Join-Path $dist "Glasstube-$Version-Windows-x64-Setup.exe"
$hash = (Get-FileHash $setup -Algorithm SHA256).Hash.ToLower()
"$hash  $(Split-Path $setup -Leaf)" | Set-Content -Encoding ascii -NoNewline "$setup.sha256"
Write-Host ("`nListo: {0} ({1:n0} MB)`nSHA-256 {2}" -f $setup, ((Get-Item $setup).Length / 1MB), $hash) -ForegroundColor Green
