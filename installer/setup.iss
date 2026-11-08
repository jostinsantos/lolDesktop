; LOL Lite - instalador (Inno Setup)
; Non-commercial use only.

#define MyAppName "LOL Lite"
#define MyAppVersion "0.0.2"
#define MyAppPublisher "LOL Lite"
#define MyAppURL "https://www.example.com/"
#define MyAppExeName "lollite.exe"

; Carpeta del portable (ZIP descomprimido o Release de Flutter)
#define MyReleaseDir "C:\proyectos\lolplus-desktop\build\windows\x64\runner\Release"

[Setup]
AppId={{D0047B50-0CE4-4FE0-811D-8C66E518AEF1}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
; Sin admin: instala en el perfil del usuario (mejor para updates en 1 clic)
DefaultDirName={localappdata}\LOLLite
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\{#MyAppExeName}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
OutputBaseFilename=LOL_Lite
OutputDir=output
SetupIconFile=C:\proyectos\lolplus-desktop\windows\runner\resources\app_icon.ico
SolidCompression=yes
WizardStyle=modern
Compression=lzma

[Languages]
Name: "spanish"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: checkedonce

; === TODO de una vez (exe + dll + data\ + subcarpetas) ===
[Files]
Source: "{#MyReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; WorkingDir: "{app}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#MyAppName}}"; Flags: nowait postinstall skipifsilent