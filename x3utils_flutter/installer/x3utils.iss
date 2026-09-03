; Inno Setup script — x3utils Flutter Windows app.
; PER-USER install (PrivilegesRequired=lowest, no UAC) into %LOCALAPPDATA%\Programs\x3utils
; for the current release line. The installed native bundle is runtime-read-only;
; a future Program Files move remains a separate packaging change.
; Paths are relative to this .iss; build the app first: flutter build windows --release

#define AppName "x3utils"
#define AppVer "2.1.3"

[Setup]
AppId={{8F4B2A1E-3C7D-4E9F-A2B6-1D5C9E7F3A80}
AppName={#AppName}
AppVersion={#AppVer}
AppVerName={#AppName} {#AppVer}
AppPublisher=x3utils
DefaultDirName={localappdata}\Programs\{#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=..\build\installer
OutputBaseFilename=x3utils-setup-{#AppVer}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\x3utils.exe
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
; Flutter release payload (exe + dlls + data\, incl. the app-local MSVC runtime)
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion
; Frozen native bundle (OpenOCD + rdp toolkit) — must sit beside the exe so
; OpenOcdPaths.find() resolves it. Defensively exclude any legacy/dev config.cmd.
Source: "..\native\windows\*"; DestDir: "{app}\native\windows"; Excludes: "special\rdp\config.cmd"; Flags: recursesubdirs createallsubdirs ignoreversion

[InstallDelete]
; GUI v1.2.3 and earlier generated this untracked file at runtime.
Type: files; Name: "{app}\native\windows\special\rdp\config.cmd"

[UninstallDelete]
Type: files; Name: "{app}\native\windows\special\rdp\config.cmd"

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\x3utils.exe"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\x3utils.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\x3utils.exe"; Description: "Launch {#AppName}"; Flags: nowait postinstall skipifsilent
