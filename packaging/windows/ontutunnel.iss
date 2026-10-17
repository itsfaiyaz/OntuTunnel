; Inno Setup script — builds OntuTunnel-Setup-<version>-x64.exe
#define AppName "OntuTunnel"
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{6B1B2F2E-8D5A-4C2B-9E0F-0A1B3C3E8BFF}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=itsfaiyaz
AppPublisherURL=https://github.com/itsfaiyaz/OntuTunnel
AppSupportURL=https://github.com/itsfaiyaz/OntuTunnel/issues
DefaultDirName={autopf}\OntuTunnel
DefaultGroupName=OntuTunnel
DisableProgramGroupPage=yes
OutputBaseFilename=OntuTunnel-Setup-{#AppVersion}-x64
OutputDir=..\..\dist
SetupIconFile=ontutunnel.ico
UninstallDisplayIcon={app}\ontutunnel.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"
Name: "startup"; Description: "Start OntuTunnel when I sign in to Windows"; GroupDescription: "Startup:"

[Files]
Source: "..\..\dist\windows-amd64\ontutunnel.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "ontutunnel.ico"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\..\LICENSE"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\OntuTunnel"; Filename: "{app}\ontutunnel.exe"; IconFilename: "{app}\ontutunnel.ico"
Name: "{group}\Uninstall OntuTunnel"; Filename: "{uninstallexe}"
Name: "{autodesktop}\OntuTunnel"; Filename: "{app}\ontutunnel.exe"; IconFilename: "{app}\ontutunnel.ico"; Tasks: desktopicon
Name: "{userstartup}\OntuTunnel"; Filename: "{app}\ontutunnel.exe"; Parameters: "-no-browser"; IconFilename: "{app}\ontutunnel.ico"; Tasks: startup

[Run]
Filename: "{app}\ontutunnel.exe"; Description: "Open OntuTunnel"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{cmd}"; Parameters: "/C taskkill /IM ontutunnel.exe /F"; Flags: runhidden; RunOnceId: "StopOntuTunnel"
