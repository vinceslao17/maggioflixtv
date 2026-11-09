; MaggioFlix: installer per Windows (x64), compilato da GitHub Actions.
; Uso: ISCC.exe /DVersion=2.25.0 windows\maggioflix-installer.iss

#define Name "MaggioFlix"
#ifndef Version
  #define Version "1.0.0"
#endif
#define Publisher "MaggioFlix"
#define ExeName "maggioflix.exe"

[Setup]
AppId={{9B1C5C0E-3F3A-4D7E-9A61-5D2F7C3E8A41}
AppName={#Name}
AppVersion={#Version}
AppPublisher={#Publisher}
AppComments=MaggioFlix, based on Plezy by edde746 (GPL-3.0)
DefaultDirName={autopf}\{#Name}
DefaultGroupName={#Name}
DisableProgramGroupPage=yes
OutputDir=..\dist
OutputBaseFilename=maggioflix-windows-installer
SetupIconFile=runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#ExeName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
CloseApplications=yes

[Languages]
Name: "italian"; MessagesFile: "compiler:Languages\Italian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#Name}"; Filename: "{app}\{#ExeName}"
Name: "{group}\{cm:UninstallProgram,{#Name}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#Name}"; Filename: "{app}\{#ExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#ExeName}"; Description: "{cm:LaunchProgram,{#Name}}"; Flags: nowait postinstall skipifsilent
