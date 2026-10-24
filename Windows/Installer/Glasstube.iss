; Instalador de Glasstube para Windows (Inno Setup 6). Lo compila Windows/Installer/build-installer.ps1, que le pasa
; /DAppVersion, /DSourceDir (la app publicada, autocontenida: .NET 8, Windows App SDK, runtime de Swift, libmpv) y
; /DOutputDir. Instala por usuario en %LOCALAPPDATA%\Programs\Glasstube sin pedir permisos de administrador; el
; diálogo del principio deja instalarlo para todos.

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\out\publish"
#endif
#ifndef OutputDir
  #define OutputDir "..\..\dist"
#endif

[Setup]
; No cambiar AppId: es como Windows reconoce las actualizaciones y la desinstalación.
AppId={{3DFF953D-3A77-466C-9002-3D759D5C9C84}
AppName=Glasstube
AppVersion={#AppVersion}
AppVerName=Glasstube {#AppVersion}
AppPublisher=Glasstube
AppPublisherURL=https://github.com/werwill/glasstube
AppSupportURL=https://github.com/werwill/glasstube/issues
AppUpdatesURL=https://github.com/werwill/glasstube/releases
DefaultDirName={autopf}\Glasstube
DefaultGroupName=Glasstube
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; WinUI 3 con Windows App SDK 1.7: Windows 10 1809 o posterior.
MinVersion=10.0.17763
SetupIconFile=..\Glasstube.App\Assets\Glasstube.ico
UninstallDisplayIcon={app}\Glasstube.exe
UninstallDisplayName=Glasstube
OutputDir={#OutputDir}
OutputBaseFilename=Glasstube-{#AppVersion}-Windows-x64-Setup
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Glasstube"; Filename: "{app}\Glasstube.exe"
Name: "{autodesktop}\Glasstube"; Filename: "{app}\Glasstube.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Glasstube.exe"; Description: "{cm:LaunchProgram,Glasstube}"; Flags: nowait postinstall skipifsilent

[Code]
// YTKit usa WebView2 para el PoToken. Windows 11 lo trae; en Windows 10 puede faltar.
function WebView2Installed: Boolean;
var
  Version: String;
begin
  Result :=
    RegQueryStringValue(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', Version) or
    RegQueryStringValue(HKCU, 'Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'pv', Version);
  Result := Result and (Version <> '') and (Version <> '0.0.0.0');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  Code: Integer;
begin
  if (CurStep = ssPostInstall) and not WizardSilent and not WebView2Installed then
    if MsgBox('Glasstube necesita Microsoft Edge WebView2 Runtime y no está en esta PC. ¿Abrir la página de descarga?',
              mbConfirmation, MB_YESNO) = IDYES then
      ShellExec('open', 'https://go.microsoft.com/fwlink/p/?LinkId=2124703', '', '', SW_SHOWNORMAL, ewNoWait, Code);
end;
